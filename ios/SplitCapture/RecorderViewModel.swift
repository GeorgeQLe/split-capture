import Combine
import Foundation

@MainActor
final class RecorderViewModel<Controller: ScreenCaptureControlling>: ObservableObject {
    let controller: Controller
    private var observation: AnyCancellable?

    init(controller: Controller) {
        self.controller = controller
        observation = controller.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var state: CaptureState { controller.state }
    var latestRecording: RecordingSummary? { controller.latestRecording }
    var recordingStartedAt: Date? { controller.recordingStartedAt }

    func primaryAction() async {
        switch state {
        case .recording:
            await controller.stop()
        case .idle, .failed:
            await controller.start()
        case .presentingPicker, .starting, .finalizing, .saving:
            break
        }
    }

    func retrySave() async {
        guard latestRecording?.photosStatus.canRetry == true else { return }
        await controller.retrySave()
    }
}
