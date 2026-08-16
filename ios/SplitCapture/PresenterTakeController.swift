@preconcurrency import AVFoundation
import AVKit
import Combine
import Foundation
import SwiftUI

private final class CaptureSessionRunner: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.lexcorp.splitcapture.presenter-session")

    func start() async {
        await withCheckedContinuation { continuation in
            queue.async { [session] in
                if !session.isRunning {
                    session.startRunning()
                }
                continuation.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [session] in
                if session.isRunning {
                    session.stopRunning()
                }
                continuation.resume()
            }
        }
    }
}

@MainActor
final class PresenterTakeController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case preparing
        case ready
        case recording
        case finishing
        case exporting
        case complete
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .finishing, .exporting:
                true
            case .ready, .recording, .complete, .failed:
                false
            }
        }
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var recordingStartedAt: Date?

    let player: AVPlayer
    private let sessionRunner = CaptureSessionRunner()
    var captureSession: AVCaptureSession { sessionRunner.session }

    private let screenRecording: RecordingSummary
    private let onFinished: @MainActor (CompositionResult) async throws -> Void
    private let movieOutput = AVCaptureMovieFileOutput()
    private var pendingCameraURL: URL?
    private var playbackEndObserver: NSObjectProtocol?
    private var didConfigure = false

    init(
        screenRecording: RecordingSummary,
        onFinished: @escaping @MainActor (CompositionResult) async throws -> Void
    ) {
        self.screenRecording = screenRecording
        self.onFinished = onFinished
        player = AVPlayer(url: screenRecording.localURL)
        super.init()
        player.actionAtItemEnd = .pause
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stopTake()
            }
        }
    }

    func prepare() async {
        guard !didConfigure else { return }
        phase = .preparing

        let cameraPermission = await AVCaptureDevice.requestAccess(for: .video)
        guard cameraPermission else {
            phase = .failed("Allow camera access in Settings to record the presenter.")
            return
        }

        let microphonePermission = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphonePermission else {
            phase = .failed("Allow microphone access in Settings to record presenter narration.")
            return
        }

        do {
            try activateAudioSession()
            try configureCaptureSession()
            await sessionRunner.start()
            didConfigure = true
            phase = .ready
        } catch {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
            phase = .failed(error.localizedDescription)
        }
    }

    func startTake() {
        guard phase == .ready else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "split-capture-presenter-\(UUID().uuidString).mov"
        )
        pendingCameraURL = url
        player.pause()
        player.seek(to: .zero)
        movieOutput.startRecording(to: url, recordingDelegate: self)
        phase = .recording
    }

    func stopTake() {
        guard phase == .recording else { return }
        phase = .finishing
        recordingStartedAt = nil
        player.pause()
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        } else {
            phase = .failed("The presenter recording stopped unexpectedly.")
        }
    }

    func cancel() {
        player.pause()
        if movieOutput.isRecording {
            movieOutput.stopRecording()
        }
        Task { @MainActor [sessionRunner] in
            await sessionRunner.stop()
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        }
        if let pendingCameraURL {
            try? FileManager.default.removeItem(at: pendingCameraURL)
        }
        pendingCameraURL = nil
    }

    private func configureCaptureSession() throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .high
        captureSession.automaticallyConfiguresApplicationAudioSession = false

        guard
            let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .front
            )
        else {
            throw CaptureFailure("No front-facing camera is available.")
        }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(cameraInput) else {
            throw CaptureFailure("The front-facing camera could not be added.")
        }
        captureSession.addInput(cameraInput)

        guard let microphone = AVCaptureDevice.default(for: .audio) else {
            throw CaptureFailure("No microphone is available.")
        }
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard captureSession.canAddInput(microphoneInput) else {
            throw CaptureFailure("The microphone could not be added.")
        }
        captureSession.addInput(microphoneInput)

        guard captureSession.canAddOutput(movieOutput) else {
            throw CaptureFailure("The presenter recording output could not be added.")
        }
        captureSession.addOutput(movieOutput)

        if let connection = movieOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
    }

    private func presenterRecordingFinished(at url: URL, error: Error?) {
        guard phase == .finishing || phase == .recording else { return }
        if let error {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .exporting
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await LoomCompositor.compose(
                    screenURL: screenRecording.localURL,
                    cameraURL: url
                )
                try await onFinished(result)
                try? FileManager.default.removeItem(at: url)
                pendingCameraURL = nil
                await sessionRunner.stop()
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
                phase = .complete
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

extension PresenterTakeController: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didStartRecordingTo fileURL: URL,
        from connections: [AVCaptureConnection]
    ) {
        Task { @MainActor [weak self] in
            guard let self, phase == .recording else { return }
            recordingStartedAt = Date()
            player.play()
        }
    }

    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.presenterRecordingFinished(at: outputFileURL, error: error)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.previewLayer.session = session
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
