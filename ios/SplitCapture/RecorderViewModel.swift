import Combine
import Foundation

@MainActor
final class RecorderViewModel<Controller: ScreenCaptureControlling>: ObservableObject {
    let controller: Controller
    private var cancellable: AnyCancellable?

    init(controller: Controller) {
        self.controller = controller
        cancellable = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var state: CaptureState { controller.state }
    var project: RecordingProject? { controller.project }
    var screenSource: RecordingAsset? { project?.screenSource }
    var activeShareAsset: RecordingAsset? { project?.activeShareAsset }
    var recordingStartedAt: Date? { controller.recordingStartedAt }
    var isDirectCaptureAvailable: Bool { controller.isDirectCaptureAvailable }

    func importScreenRecording(from url: URL) async {
        await controller.importScreenRecording(from: url)
    }

    func reportImportFailure(_ error: Error) {
        controller.reportImportFailure(error)
    }

    func directCaptureAction() async {
        if state == .recording {
            await controller.stop()
        } else {
            await controller.start()
        }
    }

    func retrySave() async {
        guard activeShareAsset?.photosStatus.canRetry == true else { return }
        await controller.retrySave()
    }

    func adoptComposedRecording(_ result: CompositionResult) async throws {
        try await controller.adoptComposedRecording(
            at: result.url,
            duration: result.duration
        )
    }
}
