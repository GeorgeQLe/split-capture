import Combine
import Foundation

@MainActor
protocol ScreenCaptureControlling: AnyObject, ObservableObject {
    var state: CaptureState { get }
    var latestRecording: RecordingSummary? { get }
    var recordingStartedAt: Date? { get }

    func start() async
    func stop() async
    func retrySave() async
    func cleanup() async
}
