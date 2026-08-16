import Combine
import Foundation

@MainActor
protocol ScreenCaptureControlling: AnyObject, ObservableObject {
    var state: CaptureState { get }
    var project: RecordingProject? { get }
    var recordingStartedAt: Date? { get }
    var isDirectCaptureAvailable: Bool { get }

    func importScreenRecording(from url: URL) async
    func reportImportFailure(_ error: Error)
    func start() async
    func stop() async
    func retrySave() async
    func adoptComposedRecording(at url: URL, duration: TimeInterval) async throws
    func cleanup() async
}
