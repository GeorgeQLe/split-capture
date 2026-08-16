import Foundation

@MainActor
func makeDirectCaptureBackend(
    delegate: any DirectCaptureBackendDelegate
) -> (any DirectCaptureBackend)? {
    #if IOS27_DIRECT_CAPTURE
        if #available(iOS 27.0, *) {
            return IOS27DirectCaptureBackend(delegate: delegate)
        }
    #endif
    return nil
}

#if IOS27_DIRECT_CAPTURE
    @preconcurrency import AVFoundation
    import CoreMedia
    import OSLog
    @preconcurrency import ScreenCaptureKit

    @available(iOS 27.0, *)
    @MainActor
    private final class IOS27DirectCaptureBackend: NSObject, DirectCaptureBackend {
        private weak var delegate: (any DirectCaptureBackendDelegate)?
        private let picker = SCContentSharingPicker.shared
        private let logger = Logger(
            subsystem: "com.lexcorp.splitcapture",
            category: "DirectCapture"
        )

        private var callbacks: CaptureCallbacks!
        private var stream: SCStream?
        private var recordingOutput: SCRecordingOutput?
        private var pendingURL: URL?
        private var microphoneEnabled = false
        private var startedAt: Date?
        private var finishWaiters: [CheckedContinuation<Void, Never>] = []
        private var isProcessingFinishedOutput = false
        private var interruptionObserver: NSObjectProtocol?

        var isAvailable: Bool { picker.isAvailable }

        init(delegate: any DirectCaptureBackendDelegate) {
            self.delegate = delegate
            super.init()
            callbacks = CaptureCallbacks(owner: self)
            observeAudioInterruptions()
        }

        func start() async {
            guard picker.isAvailable else {
                delegate?.directCaptureDidFail(
                    CaptureFailure(
                        "Full-display recording isn’t available on this device.",
                        recoverySuggestion: "Import a screen recording from Photos instead."
                    )
                )
                return
            }
            var configuration = SCContentSharingPickerConfiguration()
            configuration.showsMicrophoneControl = true
            configuration.showsCameraControl = false
            picker.defaultConfiguration = configuration
            picker.add(callbacks)
            picker.isActive = true
            picker.present()
        }

        func stop() async {
            guard recordingOutput != nil else { return }
            await withCheckedContinuation { continuation in
                finishWaiters.append(continuation)
                guard let stream, let recordingOutput else {
                    Task { @MainActor in
                        await stopStream()
                        delegate?.directCaptureDidFail(
                            CaptureFailure("The active recording output couldn’t be found.")
                        )
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

        func cleanup() async {
            if recordingOutput != nil {
                await stop()
            }
            await stopStream()
        }

        fileprivate func pickerDidSelect(filter: SCContentFilter) async {
            delegate?.directCaptureWillStart()
            microphoneEnabled = filter.isMicrophoneEnabled
            do {
                if microphoneEnabled { try activateAudioSession() }
                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                let stream = SCStream(filter: filter, configuration: configuration, delegate: callbacks)
                try stream.addStreamOutput(callbacks, type: .screen, sampleHandlerQueue: .main)
                if microphoneEnabled {
                    try stream.addStreamOutput(callbacks, type: .microphone, sampleHandlerQueue: .main)
                }
                try await stream.startCapture()
                self.stream = stream

                let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "split-capture-direct-\(UUID().uuidString).mp4"
                )
                let configurationOutput = SCRecordingOutputConfiguration()
                configurationOutput.outputURL = url
                let output = SCRecordingOutput(configuration: configurationOutput, delegate: callbacks)
                try stream.addRecordingOutput(output)
                recordingOutput = output
                pendingURL = url
                let startDate = Date()
                startedAt = startDate
                delegate?.directCaptureDidStart(at: startDate)
            } catch {
                await stopStream()
                delegate?.directCaptureDidFail(
                    CaptureFailure("Recording couldn’t start.", recoverySuggestion: error.localizedDescription)
                )
            }
        }

        fileprivate func pickerDidCancel() {
            deactivatePicker()
            delegate?.directCaptureDidCancel()
        }

        fileprivate func pickerDidFail(error: Error) {
            deactivatePicker()
            delegate?.directCaptureDidFail(
                CaptureFailure("The capture picker couldn’t open.", recoverySuggestion: error.localizedDescription)
            )
        }

        fileprivate func recordingDidFinish(_ output: SCRecordingOutput) {
            guard output === recordingOutput, !isProcessingFinishedOutput else { return }
            isProcessingFinishedOutput = true
            let measured = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            let reported = output.recordedDuration.seconds
            let duration = reported.isFinite && reported > 0 ? reported : measured
            Task { @MainActor in
                await finishRecording(duration: duration, fileSize: Int64(output.recordedFileSize))
            }
        }

        fileprivate func recordingDidFail(_ output: SCRecordingOutput, error: Error) {
            guard output === recordingOutput else { return }
            salvagePendingRecording(error: error)
        }

        fileprivate func streamDidStop(_ stoppedStream: SCStream, error: Error) {
            guard stoppedStream === stream else { return }
            logger.error("Capture stream stopped: \(error)")
            if recordingOutput == nil {
                Task { @MainActor in
                    await stopStream()
                    delegate?.directCaptureDidFail(
                        CaptureFailure("Screen capture stopped.", recoverySuggestion: error.localizedDescription)
                    )
                }
            } else if !isProcessingFinishedOutput {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self, !self.isProcessingFinishedOutput else { return }
                    self.salvagePendingRecording(error: error)
                }
            }
        }

        private func finishRecording(duration: TimeInterval, fileSize: Int64) async {
            defer {
                recordingOutput = nil
                pendingURL = nil
                startedAt = nil
                isProcessingFinishedOutput = false
                resumeFinishWaiters()
            }
            guard let pendingURL else {
                await stopStream()
                delegate?.directCaptureDidFail(CaptureFailure("The completed recording file couldn’t be found."))
                return
            }
            await stopStream()
            await delegate?.directCaptureDidFinish(
                url: pendingURL,
                duration: max(duration, 0),
                fileSize: fileSize
            )
        }

        private func salvagePendingRecording(error: Error) {
            guard
                let pendingURL,
                let size = try? pendingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                size > 0
            else {
                Task { @MainActor in
                    await stopStream()
                    delegate?.directCaptureDidFail(
                        CaptureFailure(
                            "Recording stopped before a valid file was produced.",
                            recoverySuggestion: error.localizedDescription
                        )
                    )
                    finishWithoutRecording()
                }
                return
            }
            isProcessingFinishedOutput = true
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
            Task { @MainActor in
                await finishRecording(duration: elapsed, fileSize: Int64(size))
            }
        }

        private func finishWithoutRecording() {
            recordingOutput = nil
            pendingURL = nil
            startedAt = nil
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
            if let stream { try? await stream.stopCapture() }
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
                Task { @MainActor [weak self] in await self?.stop() }
            }
        }
    }

    @available(iOS 27.0, *)
    private final class CaptureCallbacks: NSObject,
        SCContentSharingPickerObserver,
        SCRecordingOutputDelegate,
        SCStreamDelegate,
        SCStreamOutput,
        @unchecked Sendable
    {
        private weak var owner: IOS27DirectCaptureBackend?

        init(owner: IOS27DirectCaptureBackend) { self.owner = owner }

        nonisolated func contentSharingPicker(
            _ picker: SCContentSharingPicker,
            didUpdateWith filter: SCContentFilter,
            for stream: SCStream?
        ) {
            Task { @MainActor [weak owner] in await owner?.pickerDidSelect(filter: filter) }
        }

        nonisolated func contentSharingPicker(
            _ picker: SCContentSharingPicker,
            didCancelFor stream: SCStream?
        ) {
            Task { @MainActor [weak owner] in owner?.pickerDidCancel() }
        }

        nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
            Task { @MainActor [weak owner] in owner?.pickerDidFail(error: error) }
        }

        nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

        nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
            Task { @MainActor [weak owner] in owner?.recordingDidFinish(recordingOutput) }
        }

        nonisolated func recordingOutput(
            _ recordingOutput: SCRecordingOutput,
            didFailWithError error: Error
        ) {
            Task { @MainActor [weak owner] in owner?.recordingDidFail(recordingOutput, error: error) }
        }

        nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
            Task { @MainActor [weak owner] in owner?.streamDidStop(stream, error: error) }
        }

        nonisolated func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {}
    }
#endif
