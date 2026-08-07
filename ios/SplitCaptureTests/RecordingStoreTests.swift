import Foundation
import XCTest

@testable import SplitCapture

final class RecordingStoreTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SplitCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func testReplacementDeletesPreviousOnlyAfterPromotion() throws {
        let store = RecordingStore(rootURL: rootURL)
        let firstTemporary = try temporaryRecording(named: "first")
        let first = try store.promote(
            temporaryURL: firstTemporary,
            duration: 15,
            fileSize: 4,
            previous: nil
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localURL.path))

        let invalid = rootURL.appendingPathComponent("missing.mp4")
        XCTAssertThrowsError(
            try store.promote(
                temporaryURL: invalid,
                duration: 0,
                fileSize: 0,
                previous: first
            ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.localURL.path))

        let secondTemporary = try temporaryRecording(named: "second")
        let second = try store.promote(
            temporaryURL: secondTemporary,
            duration: 16,
            fileSize: 4,
            previous: first
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.localURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.localURL.path))
    }

    func testRestoreReadsPersistedLatestRecording() throws {
        let store = RecordingStore(rootURL: rootURL)
        let temporary = try temporaryRecording(named: "restore")
        let expected = try store.promote(
            temporaryURL: temporary,
            duration: 15,
            fileSize: 4,
            previous: nil
        )

        XCTAssertEqual(RecordingStore(rootURL: rootURL).restore(), expected)
    }

    private func temporaryRecording(named name: String) throws -> URL {
        let url = rootURL.appendingPathComponent("\(name)-temporary.mp4")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }
}
