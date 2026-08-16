import Foundation
import XCTest

@testable import SplitCapture

final class RecordingStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testScreenReplacementDeletesOldAssetsOnlyAfterSuccessfulPromotion() throws {
        let store = RecordingStore(rootURL: rootURL)
        let first = try store.replaceScreenSource(
            temporaryURL: temporaryRecording(named: "first"),
            origin: .photosImport,
            duration: 15,
            fileSize: 4,
            photosStatus: .alreadyInPhotos,
            previous: nil
        )
        let firstURL = first.screenSource.localURL

        XCTAssertThrowsError(
            try store.replaceScreenSource(
                temporaryURL: rootURL.appendingPathComponent("missing.mp4"),
                origin: .photosImport,
                duration: 0,
                fileSize: 0,
                photosStatus: .alreadyInPhotos,
                previous: first
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertEqual(store.restore(), first)

        let second = try store.replaceScreenSource(
            temporaryURL: temporaryRecording(named: "second"),
            origin: .directCapture,
            duration: 16,
            fileSize: 4,
            photosStatus: .saved,
            previous: first
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.screenSource.localURL.path))
    }

    func testCompositeReplacementRetainsSourceAndDeletesOnlyOldComposite() throws {
        let store = RecordingStore(rootURL: rootURL)
        let sourceProject = try store.replaceScreenSource(
            temporaryURL: temporaryRecording(named: "source"),
            origin: .photosImport,
            duration: 20,
            fileSize: 4,
            photosStatus: .alreadyInPhotos,
            previous: nil
        )
        let first = try store.replaceComposite(
            temporaryURL: temporaryRecording(named: "composite-one"),
            duration: 18,
            fileSize: 4,
            in: sourceProject
        )
        let firstCompositeURL = try XCTUnwrap(first.composite?.localURL)

        let second = try store.replaceComposite(
            temporaryURL: temporaryRecording(named: "composite-two"),
            duration: 17,
            fileSize: 4,
            in: first
        )

        XCTAssertEqual(second.screenSource, sourceProject.screenSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.screenSource.localURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCompositeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(second.composite).localURL.path))
    }

    func testRestoreMigratesLegacyLatestRecording() throws {
        let mediaURL = rootURL.appendingPathComponent("legacy.mp4")
        try Data([0, 1, 2, 3]).write(to: mediaURL)
        let legacy = RecordingAsset(
            id: UUID(),
            localURL: mediaURL,
            duration: 15,
            fileSize: 4,
            photosStatus: .saved,
            creationDate: Date()
        )
        try JSONEncoder().encode(legacy).write(
            to: rootURL.appendingPathComponent("latest-recording.json")
        )

        let migrated = try XCTUnwrap(RecordingStore(rootURL: rootURL).restore())
        XCTAssertEqual(migrated.screenSource, legacy)
        XCTAssertEqual(migrated.origin, .directCapture)
        XCTAssertNil(migrated.composite)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: rootURL.appendingPathComponent("latest-recording.json").path
            )
        )
        XCTAssertEqual(RecordingStore(rootURL: rootURL).restore(), migrated)
    }

    func testRestoreKeepsSourceWhenCompositeFileIsMissing() throws {
        let store = RecordingStore(rootURL: rootURL)
        let source = try store.replaceScreenSource(
            temporaryURL: temporaryRecording(named: "recover-source"),
            origin: .photosImport,
            duration: 12,
            fileSize: 4,
            photosStatus: .alreadyInPhotos,
            previous: nil
        )
        let composed = try store.replaceComposite(
            temporaryURL: temporaryRecording(named: "recover-composite"),
            duration: 10,
            fileSize: 4,
            in: source
        )
        try FileManager.default.removeItem(at: try XCTUnwrap(composed.composite).localURL)

        let restored = try XCTUnwrap(store.restore())

        XCTAssertEqual(restored.screenSource, source.screenSource)
        XCTAssertNil(restored.composite)
    }

    func testCleanupRemovesAbandonedTemporaryMovies() throws {
        let retained = FileManager.default.temporaryDirectory.appendingPathComponent(
            "split-capture-retained-\(UUID().uuidString).mp4"
        )
        let abandoned = FileManager.default.temporaryDirectory.appendingPathComponent(
            "split-capture-presenter-\(UUID().uuidString).mov"
        )
        try Data([0]).write(to: retained)
        try Data([0]).write(to: abandoned)
        defer { try? FileManager.default.removeItem(at: retained) }

        RecordingStore(rootURL: rootURL).cleanupTemporaryRecordings(except: [retained])

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
    }

    private func temporaryRecording(named name: String) throws -> URL {
        let url = rootURL.appendingPathComponent("\(name)-temporary.mp4")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }
}
