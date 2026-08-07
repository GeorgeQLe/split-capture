import Combine
import XCTest

@testable import SplitCapture

@MainActor
final class RecorderViewModelTests: XCTestCase {
    func testPickerCancellationReturnsToIdleWithoutRecording() async {
        let fake = FakeCaptureController()
        let viewModel = RecorderViewModel(controller: fake)

        await viewModel.primaryAction()
        XCTAssertEqual(fake.state, .presentingPicker)

        fake.cancelPicker()
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.latestRecording)
    }

    func testNormalRecordingCanStartAndStop() async {
        let fake = FakeCaptureController()
        let viewModel = RecorderViewModel(controller: fake)

        await viewModel.primaryAction()
        fake.acceptPicker()
        XCTAssertEqual(viewModel.state, .recording)

        await viewModel.primaryAction()
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNotNil(viewModel.latestRecording)
    }

    func testDuplicateStartAndStopActionsAreRejected() async {
        let fake = FakeCaptureController()
        await fake.start()
        await fake.start()
        XCTAssertEqual(fake.startCount, 1)

        fake.acceptPicker()
        await fake.stop()
        await fake.stop()
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testAppAndSystemStopsBothFinalize() async {
        let appStop = FakeCaptureController()
        let appViewModel = RecorderViewModel(controller: appStop)
        await appViewModel.primaryAction()
        appStop.acceptPicker()
        await appViewModel.primaryAction()
        XCTAssertNotNil(appStop.latestRecording)

        let systemStop = FakeCaptureController()
        await systemStop.start()
        systemStop.acceptPicker()
        systemStop.systemStop()
        XCTAssertEqual(systemStop.state, .idle)
        XCTAssertNotNil(systemStop.latestRecording)
    }

    func testStreamFailureDoesNotLeaveRecordingStateStuck() async {
        let fake = FakeCaptureController()
        await fake.start()
        fake.acceptPicker()

        fake.streamFailure()

        guard case .failed = fake.state else {
            return XCTFail("Expected a recoverable failure")
        }
        XCTAssertNil(fake.recordingStartedAt)
    }

    func testPhotosDenialCanBeRetried() async {
        let fake = FakeCaptureController()
        fake.nextPhotosStatus = .denied
        await fake.start()
        fake.acceptPicker()
        await fake.stop()
        XCTAssertEqual(fake.latestRecording?.photosStatus, .denied)

        fake.nextPhotosStatus = .saved
        let viewModel = RecorderViewModel(controller: fake)
        await viewModel.retrySave()
        XCTAssertEqual(fake.latestRecording?.photosStatus, .saved)
        XCTAssertEqual(fake.retryCount, 1)
    }

    func testNewRecordingReplacesPreviousSummary() async {
        let fake = FakeCaptureController()
        await fake.start()
        fake.acceptPicker()
        await fake.stop()
        let firstID = fake.latestRecording?.id

        await fake.start()
        fake.acceptPicker()
        await fake.stop()

        XCTAssertNotEqual(fake.latestRecording?.id, firstID)
    }

    func testLatestRecordingIsAvailableAfterRelaunch() {
        let restored = FakeCaptureController(restored: .fixture())
        let viewModel = RecorderViewModel(controller: restored)

        XCTAssertEqual(viewModel.latestRecording?.duration, 15)
        XCTAssertEqual(viewModel.latestRecording?.photosStatus, .saved)
    }
}

@MainActor
private final class FakeCaptureController: ScreenCaptureControlling {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var latestRecording: RecordingSummary?
    @Published private(set) var recordingStartedAt: Date?

    var startCount = 0
    var stopCount = 0
    var retryCount = 0
    var nextPhotosStatus: PhotosStatus = .saved

    init(restored: RecordingSummary? = nil) {
        latestRecording = restored
    }

    func start() async {
        guard state == .idle || isFailed else { return }
        startCount += 1
        state = .presentingPicker
    }

    func stop() async {
        guard state == .recording else { return }
        stopCount += 1
        finalize()
    }

    func retrySave() async {
        guard var latestRecording, latestRecording.photosStatus.canRetry else { return }
        retryCount += 1
        state = .saving
        latestRecording.photosStatus = nextPhotosStatus
        self.latestRecording = latestRecording
        state = .idle
    }

    func cleanup() async {}

    func cancelPicker() {
        guard state == .presentingPicker else { return }
        state = .idle
    }

    func acceptPicker() {
        guard state == .presentingPicker else { return }
        recordingStartedAt = Date()
        state = .recording
    }

    func systemStop() {
        guard state == .recording else { return }
        finalize()
    }

    func streamFailure() {
        guard state == .recording else { return }
        recordingStartedAt = nil
        state = .failed(CaptureFailure("Stream stopped"))
    }

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    private func finalize() {
        state = .finalizing
        recordingStartedAt = nil
        var summary = RecordingSummary.fixture()
        summary.photosStatus = nextPhotosStatus
        latestRecording = summary
        state = .idle
    }
}

extension RecordingSummary {
    fileprivate static func fixture() -> RecordingSummary {
        RecordingSummary(
            id: UUID(),
            localURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).mp4"),
            duration: 15,
            fileSize: 1_024,
            photosStatus: .saved,
            creationDate: Date()
        )
    }
}
