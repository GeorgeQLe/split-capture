import Combine
import XCTest

@testable import SplitCapture

@MainActor
final class RecorderViewModelTests: XCTestCase {
    func testImportBecomesRetainedSourceAndActiveShareAsset() async {
        let fake = FakeCaptureController()
        let viewModel = RecorderViewModel(controller: fake)
        let url = temporaryURL("import.mov")

        await viewModel.importScreenRecording(from: url)

        XCTAssertEqual(viewModel.project?.origin, .photosImport)
        XCTAssertEqual(viewModel.screenSource?.localURL, url)
        XCTAssertEqual(viewModel.activeShareAsset, viewModel.screenSource)
        XCTAssertEqual(viewModel.activeShareAsset?.photosStatus, .alreadyInPhotos)
    }

    func testDirectCaptureAvailabilityIsExposed() {
        let unavailable = RecorderViewModel(controller: FakeCaptureController(directCapture: false))
        let available = RecorderViewModel(controller: FakeCaptureController(directCapture: true))
        XCTAssertFalse(unavailable.isDirectCaptureAvailable)
        XCTAssertTrue(available.isDirectCaptureAvailable)
    }

    func testDirectCaptureCanStartAndStop() async {
        let fake = FakeCaptureController(directCapture: true)
        let viewModel = RecorderViewModel(controller: fake)

        await viewModel.directCaptureAction()
        XCTAssertEqual(viewModel.state, .recording)
        await viewModel.directCaptureAction()

        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertEqual(viewModel.project?.origin, .directCapture)
        XCTAssertEqual(fake.startCount, 1)
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testPresenterResultReplacesCompositeWithoutReplacingSource() async throws {
        let source = RecordingAsset.fixture(url: temporaryURL("source.mp4"))
        let fake = FakeCaptureController(restored: .fixture(screenSource: source))
        let viewModel = RecorderViewModel(controller: fake)
        let compositeURL = temporaryURL("composite.mp4")

        try await viewModel.adoptComposedRecording(
            CompositionResult(url: compositeURL, duration: 12)
        )

        XCTAssertEqual(viewModel.screenSource, source)
        XCTAssertEqual(viewModel.activeShareAsset?.localURL, compositeURL)
        XCTAssertEqual(viewModel.activeShareAsset?.duration, 12)
    }

    func testRetryTargetsCompositeWhenPresent() async {
        var project = RecordingProject.fixture()
        var composite = RecordingAsset.fixture(url: temporaryURL("retry.mp4"))
        composite.photosStatus = .denied
        project.composite = composite
        let fake = FakeCaptureController(restored: project)
        let viewModel = RecorderViewModel(controller: fake)

        await viewModel.retrySave()

        XCTAssertEqual(viewModel.activeShareAsset?.photosStatus, .saved)
        XCTAssertEqual(fake.retryCount, 1)
        XCTAssertEqual(viewModel.screenSource, project.screenSource)
    }

    func testImportFailureUsesCaptureFailureStateAndKeepsProject() {
        let project = RecordingProject.fixture()
        let fake = FakeCaptureController(restored: project)
        let viewModel = RecorderViewModel(controller: fake)

        viewModel.reportImportFailure(CaptureFailure("copy interrupted"))

        guard case .failed(let failure) = viewModel.state else {
            return XCTFail("Expected import failure state")
        }
        XCTAssertEqual(failure.message, "Import failed")
        XCTAssertEqual(viewModel.project, project)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}

@MainActor
private final class FakeCaptureController: ScreenCaptureControlling {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var project: RecordingProject?
    @Published private(set) var recordingStartedAt: Date?
    let isDirectCaptureAvailable: Bool

    var startCount = 0
    var stopCount = 0
    var retryCount = 0

    init(restored: RecordingProject? = nil, directCapture: Bool = false) {
        project = restored
        isDirectCaptureAvailable = directCapture
    }

    func importScreenRecording(from url: URL) async {
        project = .fixture(
            screenSource: RecordingAsset.fixture(
                url: url,
                photosStatus: .alreadyInPhotos
            ),
            origin: .photosImport
        )
        state = .idle
    }

    func reportImportFailure(_ error: Error) {
        state = .failed(
            CaptureFailure("Import failed", recoverySuggestion: error.localizedDescription)
        )
    }

    func start() async {
        guard isDirectCaptureAvailable, state == .idle else { return }
        startCount += 1
        recordingStartedAt = Date()
        state = .recording
    }

    func stop() async {
        guard state == .recording else { return }
        stopCount += 1
        recordingStartedAt = nil
        project = .fixture(origin: .directCapture)
        state = .idle
    }

    func retrySave() async {
        guard var project else { return }
        retryCount += 1
        if var composite = project.composite {
            composite.photosStatus = .saved
            project.composite = composite
        } else {
            project.screenSource.photosStatus = .saved
        }
        self.project = project
    }

    func adoptComposedRecording(at url: URL, duration: TimeInterval) async throws {
        guard var project else { throw CaptureFailure("Missing source") }
        project.composite = RecordingAsset.fixture(url: url, duration: duration)
        self.project = project
    }

    func cleanup() async {}
}

extension RecordingAsset {
    fileprivate static func fixture(
        url: URL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4"),
        duration: TimeInterval = 15,
        photosStatus: PhotosStatus = .saved
    ) -> RecordingAsset {
        RecordingAsset(
            id: UUID(),
            localURL: url,
            duration: duration,
            fileSize: 1_024,
            photosStatus: photosStatus,
            creationDate: Date()
        )
    }
}

extension RecordingProject {
    fileprivate static func fixture(
        screenSource: RecordingAsset = .fixture(),
        origin: RecordingOrigin = .photosImport
    ) -> RecordingProject {
        RecordingProject(
            id: UUID(),
            screenSource: screenSource,
            origin: origin,
            composite: nil
        )
    }
}
