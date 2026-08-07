import Combine
import Foundation

#if canImport(ScreenCaptureKit)
    import AVFoundation
    import CoreMedia
    import OSLog
    @preconcurrency import ScreenCaptureKit

    @MainActor
    final class ScreenCaptureController: NSObject, ScreenCaptureControlling {
        @Published private(set) var state: CaptureState = .idle
        @Published private(set) var latestRecording: RecordingSummary?
        @Published private(set) var recordingStartedAt: Date?

        private let picker = SCContentSharingPicker.shared
        private let store: RecordingStore
        private let photosSaver: any PhotosSaving
        private let logger = Logger(
            subsystem: "com.lexcorp.splitcapture",
            category: "Capture"
        )

        private var callbacks: CaptureCallbacks!
        private var stream: SCStream?
        private var recordingOutput: SCRecordingOutput?
        private var pendingURL: URL?
        private var microphoneEnabled = false
        private var finishWaiters: [CheckedContinuation<Void, Never>] = []
        private var isProcessingFinishedOutput = false
        private var interruptionObserver: NSObjectProtocol?

        init(
            store: RecordingStore = RecordingStore(),
            photosSaver: any PhotosSaving = PhotosLibrarySaver()
        ) {
            self.store = store
            self.photosSaver = photosSaver
            super.init()
            callbacks = CaptureCallbacks(owner: self)
            latestRecording = store.restore()
            store.cleanupTemporaryRecordings(except: latestRecording?.localURL)
            observeAudioInterruptions()
        }

        func start() async {
            guard state == .idle || isFailed else { return }
            guard picker.isAvailable else {
                fail(
                    "Full-display recording isn’t available on this device.",
                    suggestion: "Use an iPhone running iOS 27 or later."
                )
                return
            }

            var configuration = SCContentSharingPickerConfiguration()
            configuration.showsMicrophoneControl = true
            configuration.showsCameraControl = false
            picker.defaultConfiguration = configuration
            picker.add(callbacks)
            picker.isActive = true
            state = .presentingPicker
            picker.present()
        }

        func stop() async {
            guard state == .recording else { return }
            state = .finalizing
            recordingStartedAt = nil

            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
                guard let stream, let recordingOutput else {
                    Task { @MainActor in
                        await stopStream()
                        fail("The active recording output couldn’t be found.")
                        finishWithoutRecording()
                    }
                    return
                }
                do {
                    try stream.removeRecordingOutput(recordingOutput)
                } catch {
                    logger.error("Unable to remove recording output: \(error)")
                    salvagePendingRecording(error: error)
                }
            }
        }

        func retrySave() async {
            guard var summary = latestRecording, summary.photosStatus.canRetry else {
                return
            }
            state = .saving
            summary.photosStatus = await photosSaver.saveVideo(at: summary.localURL)
            do {
                try store.update(summary)
                latestRecording = summary
                state = .idle
            } catch {
                fail(
                    "The recording is safe, but its save status couldn’t be updated.",
                    suggestion: error.localizedDescription
                )
            }
        }

        func cleanup() async {
            if state == .recording {
                await stop()
            }
            await stopStream()
            store.cleanupTemporaryRecordings(except: latestRecording?.localURL)
        }

        fileprivate func pickerDidSelect(filter: SCContentFilter) async {
            guard state == .presentingPicker else { return }
            state = .starting
            microphoneEnabled = filter.isMicrophoneEnabled

            do {
                if microphoneEnabled {
                    try activateAudioSession()
                }

                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                let stream = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: callbacks
                )
                try stream.addStreamOutput(
                    callbacks,
                    type: .screen,
                    sampleHandlerQueue: .main
                )
                if microphoneEnabled {
                    try stream.addStreamOutput(
                        callbacks,
                        type: .microphone,
                        sampleHandlerQueue: .main
                    )
                }
                try await stream.startCapture()
                self.stream = stream

                let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "split-capture-\(UUID().uuidString).mp4"
                )
                let recordingConfiguration = SCRecordingOutputConfiguration()
                recordingConfiguration.outputURL = url
                let output = SCRecordingOutput(
                    configuration: recordingConfiguration,
                    delegate: callbacks
                )
                try stream.addRecordingOutput(output)
                recordingOutput = output
                pendingURL = url
                recordingStartedAt = Date()
                state = .recording
            } catch {
                await stopStream()
                fail(
                    "Recording couldn’t start.",
                    suggestion: error.localizedDescription
                )
            }
        }

        fileprivate func pickerDidCancel() {
            guard state == .presentingPicker else { return }
            deactivatePicker()
            state = .idle
        }

        fileprivate func pickerDidFail(error: Error) {
            guard state == .presentingPicker else { return }
            deactivatePicker()
            fail("The capture picker couldn’t open.", suggestion: error.localizedDescription)
        }

        fileprivate func recordingDidFinish(_ output: SCRecordingOutput) {
            guard output === recordingOutput, !isProcessingFinishedOutput else { return }
            isProcessingFinishedOutput = true
            state = .finalizing
            let measuredDuration =
                recordingStartedAt.map {
                    Date().timeIntervalSince($0)
                } ?? 0
            let reportedDuration = output.recordedDuration.seconds
            let duration =
                reportedDuration.isFinite && reportedDuration >= 0
                ? reportedDuration
                : measuredDuration
            recordingStartedAt = nil

            Task { @MainActor in
                await finishRecording(
                    duration: duration,
                    fileSize: Int64(output.recordedFileSize)
                )
            }
        }

        fileprivate func recordingDidFail(_ output: SCRecordingOutput, error: Error) {
            guard output === recordingOutput else { return }
            salvagePendingRecording(error: error)
        }

        fileprivate func streamDidStop(_ stoppedStream: SCStream, error: Error) {
            guard stoppedStream === stream else { return }
            logger.error("Capture stream stopped: \(error)")
            recordingStartedAt = nil

            if recordingOutput == nil {
                Task { @MainActor in
                    await stopStream()
                    fail("Screen capture stopped.", suggestion: error.localizedDescription)
                }
            } else if state == .recording {
                state = .finalizing
                // SCRecordingOutput normally calls its completion delegate after a system stop.
                // If it reports a failure instead, that callback attempts to salvage a valid MP4.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, self.state == .finalizing,
                        !self.isProcessingFinishedOutput
                    else { return }
                    self.salvagePendingRecording(error: error)
                }
            }
        }

        private var isFailed: Bool {
            if case .failed = state { true } else { false }
        }

        private func finishRecording(duration: TimeInterval, fileSize: Int64) async {
            defer {
                recordingOutput = nil
                pendingURL = nil
                isProcessingFinishedOutput = false
                resumeFinishWaiters()
            }

            guard let pendingURL else {
                await stopStream()
                fail("The completed recording file couldn’t be found.")
                return
            }

            do {
                let actualSize =
                    (try? pendingURL.resourceValues(
                        forKeys: [.fileSizeKey]
                    ).fileSize).map(Int64.init) ?? fileSize
                var summary = try store.promote(
                    temporaryURL: pendingURL,
                    duration: max(duration, 0),
                    fileSize: max(actualSize, fileSize),
                    previous: latestRecording
                )
                latestRecording = summary
                await stopStream()

                state = .saving
                summary.photosStatus = await photosSaver.saveVideo(at: summary.localURL)
                try store.update(summary)
                latestRecording = summary
                state = .idle
            } catch {
                await stopStream()
                fail(
                    "The recording couldn’t be finalized.",
                    suggestion: error.localizedDescription
                )
            }
        }

        private func salvagePendingRecording(error: Error) {
            guard
                let pendingURL,
                let values = try? pendingURL.resourceValues(forKeys: [.fileSizeKey]),
                let size = values.fileSize,
                size > 0
            else {
                Task { @MainActor in
                    await stopStream()
                    fail("Recording stopped before a valid file was produced.", suggestion: error.localizedDescription)
                    finishWithoutRecording()
                }
                return
            }

            isProcessingFinishedOutput = true
            Task { @MainActor in
                let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                await finishRecording(duration: elapsed, fileSize: Int64(size))
            }
        }

        private func finishWithoutRecording() {
            recordingOutput = nil
            pendingURL = nil
            recordingStartedAt = nil
            resumeFinishWaiters()
        }

        private func resumeFinishWaiters() {
            let waiters = finishWaiters
            finishWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        private func stopStream() async {
            if let stream {
                try? await stream.stopCapture()
            }
            stream = nil
            deactivatePicker()
            if microphoneEnabled {
                try? AVAudioSession.sharedInstance().setActive(
                    false,
                    options: .notifyOthersOnDeactivation
                )
            }
            microphoneEnabled = false
        }

        private func deactivatePicker() {
            picker.isActive = false
            picker.remove(callbacks)
        }

        private func activateAudioSession() throws {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.mixWithOthers, .allowBluetoothHFP]
            )
            try session.setActive(true)
        }

        private func observeAudioInterruptions() {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.didBecomeInactiveNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.stop()
                }
            }
        }

        private func fail(_ message: String, suggestion: String? = nil) {
            state = .failed(
                CaptureFailure(message, recoverySuggestion: suggestion)
            )
        }
    }

    private final class CaptureCallbacks: NSObject,
        SCContentSharingPickerObserver,
        SCRecordingOutputDelegate,
        SCStreamDelegate,
        SCStreamOutput,
        @unchecked Sendable
    {

        private weak var owner: ScreenCaptureController?

        init(owner: ScreenCaptureController) {
            self.owner = owner
        }

        nonisolated func contentSharingPicker(
            _ picker: SCContentSharingPicker,
            didUpdateWith filter: SCContentFilter,
            for stream: SCStream?
        ) {
            Task { @MainActor [weak owner] in
                await owner?.pickerDidSelect(filter: filter)
            }
        }

        nonisolated func contentSharingPicker(
            _ picker: SCContentSharingPicker,
            didCancelFor stream: SCStream?
        ) {
            Task { @MainActor [weak owner] in
                owner?.pickerDidCancel()
            }
        }

        nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
            Task { @MainActor [weak owner] in
                owner?.pickerDidFail(error: error)
            }
        }

        nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

        nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            Task { @MainActor [weak owner] in
                owner?.recordingDidFinish(recordingOutput)
            }
        }

        nonisolated func recordingOutput(
            _ recordingOutput: SCRecordingOutput,
            didFailWithError error: Error
        ) {
            Task { @MainActor [weak owner] in
                owner?.recordingDidFail(recordingOutput, error: error)
            }
        }

        nonisolated func stream(
            _ stream: SCStream,
            didStopWithError error: Error
        ) {
            Task { @MainActor [weak owner] in
                owner?.streamDidStop(stream, error: error)
            }
        }

        nonisolated func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {}
    }
#else
    @MainActor
    final class ScreenCaptureController: NSObject, ScreenCaptureControlling {
        @Published private(set) var state: CaptureState = .idle
        @Published private(set) var latestRecording: RecordingSummary?
        @Published private(set) var recordingStartedAt: Date?

        private let store: RecordingStore
        private let photosSaver: any PhotosSaving

        init(
            store: RecordingStore = RecordingStore(),
            photosSaver: any PhotosSaving = PhotosLibrarySaver()
        ) {
            self.store = store
            self.photosSaver = photosSaver
            super.init()
            latestRecording = store.restore()
        }

        func start() async {
            state = .failed(
                CaptureFailure(
                    "Full-display recording requires a physical iPhone.",
                    recoverySuggestion: "Run Split Capture on an iPhone with iOS 27 or later."
                )
            )
        }

        func stop() async {}

        func retrySave() async {
            guard var summary = latestRecording, summary.photosStatus.canRetry else {
                return
            }
            state = .saving
            summary.photosStatus = await photosSaver.saveVideo(at: summary.localURL)
            do {
                try store.update(summary)
                latestRecording = summary
                state = .idle
            } catch {
                state = .failed(
                    CaptureFailure(
                        "The recording is safe, but its save status couldn’t be updated.",
                        recoverySuggestion: error.localizedDescription
                    )
                )
            }
        }

        func cleanup() async {
            store.cleanupTemporaryRecordings(except: latestRecording?.localURL)
        }
    }
#endif
