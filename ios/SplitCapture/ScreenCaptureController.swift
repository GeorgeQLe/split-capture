@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
protocol DirectCaptureBackendDelegate: AnyObject {
    func directCaptureWillStart()
    func directCaptureDidStart(at date: Date)
    func directCaptureDidCancel()
    func directCaptureDidFinish(url: URL, duration: TimeInterval, fileSize: Int64) async
    func directCaptureDidFail(_ failure: CaptureFailure)
}

@MainActor
protocol DirectCaptureBackend: AnyObject {
    var isAvailable: Bool { get }
    func start() async
    func stop() async
    func cleanup() async
}

@MainActor
final class ScreenCaptureController: NSObject, ScreenCaptureControlling {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var project: RecordingProject?
    @Published private(set) var recordingStartedAt: Date?

    private let store: RecordingStore
    private let photosSaver: any PhotosSaving
    private var directCaptureBackend: (any DirectCaptureBackend)?

    var isDirectCaptureAvailable: Bool {
        directCaptureBackend?.isAvailable == true
    }

    init(
        store: RecordingStore = RecordingStore(),
        photosSaver: any PhotosSaving = PhotosLibrarySaver()
    ) {
        self.store = store
        self.photosSaver = photosSaver
        super.init()
        project = store.restore()
        directCaptureBackend = makeDirectCaptureBackend(delegate: self)
        store.cleanupTemporaryRecordings(except: retainedURLs)
    }

    func importScreenRecording(from url: URL) async {
        guard state == .idle || isFailed else { return }
        state = .importing
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let metadata = try await validateMovie(at: url)
            project = try store.replaceScreenSource(
                temporaryURL: url,
                origin: .photosImport,
                duration: metadata.duration,
                fileSize: metadata.fileSize,
                photosStatus: .alreadyInPhotos,
                previous: project
            )
            state = .idle
        } catch {
            fail(
                "That video couldn’t be imported.",
                suggestion: error.localizedDescription
            )
        }
    }

    func reportImportFailure(_ error: Error) {
        guard state == .idle || isFailed else { return }
        fail("That video couldn’t be imported.", suggestion: error.localizedDescription)
    }

    func start() async {
        guard state == .idle || isFailed else { return }
        guard let directCaptureBackend, directCaptureBackend.isAvailable else {
            fail(
                "Direct full-display recording isn’t available in this build.",
                suggestion: "Import an existing screen recording from Photos instead."
            )
            return
        }
        state = .presentingPicker
        await directCaptureBackend.start()
    }

    func stop() async {
        guard state == .recording else { return }
        state = .finalizing
        recordingStartedAt = nil
        await directCaptureBackend?.stop()
    }

    func retrySave() async {
        guard var project else { return }
        let targetIsComposite = project.composite != nil
        var asset = project.activeShareAsset
        guard asset.photosStatus.canRetry else { return }

        state = .saving
        asset.photosStatus = await photosSaver.saveVideo(at: asset.localURL)
        if targetIsComposite {
            project.composite = asset
        } else {
            project.screenSource = asset
        }

        do {
            try store.update(project)
            self.project = project
            state = .idle
        } catch {
            fail(
                "The video is safe, but its save status couldn’t be updated.",
                suggestion: error.localizedDescription
            )
        }
    }

    func adoptComposedRecording(at url: URL, duration: TimeInterval) async throws {
        guard state == .idle || isFailed, let project else {
            throw CaptureFailure("The retained screen recording could not be found.")
        }
        state = .saving
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            var updated = try store.replaceComposite(
                temporaryURL: url,
                duration: duration,
                fileSize: Int64(values.fileSize ?? 0),
                in: project
            )
            self.project = updated

            guard var composite = updated.composite else {
                throw CaptureFailure("The finished picture-in-picture video could not be found.")
            }
            composite.photosStatus = await photosSaver.saveVideo(at: composite.localURL)
            updated.composite = composite
            try store.update(updated)
            self.project = updated
            state = .idle
        } catch {
            state = .idle
            throw error
        }
    }

    func cleanup() async {
        if state == .recording {
            await stop()
        }
        await directCaptureBackend?.cleanup()
        store.cleanupTemporaryRecordings(except: retainedURLs)
    }

    private var isFailed: Bool {
        if case .failed = state { true } else { false }
    }

    private var retainedURLs: Set<URL> {
        guard let project else { return [] }
        return Set([project.screenSource.localURL, project.composite?.localURL].compactMap { $0 })
    }

    private func validateMovie(at url: URL) async throws -> (duration: TimeInterval, fileSize: Int64) {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard !tracks.isEmpty, playable, duration.isFinite, duration > 0, size > 0 else {
            throw CaptureFailure(
                "The selected item is not a playable movie with a video track."
            )
        }
        return (duration, Int64(size))
    }

    private func finishDirectCapture(url: URL, duration _: TimeInterval, fileSize: Int64) async {
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let metadata = try await validateMovie(at: url)
            var updated = try store.replaceScreenSource(
                temporaryURL: url,
                origin: .directCapture,
                duration: metadata.duration,
                fileSize: max(fileSize, metadata.fileSize),
                photosStatus: .failed("Not saved yet"),
                previous: project
            )
            project = updated

            state = .saving
            var screenSource = updated.screenSource
            screenSource.photosStatus = await photosSaver.saveVideo(at: screenSource.localURL)
            updated.screenSource = screenSource
            try store.update(updated)
            project = updated
            state = .idle
        } catch {
            fail("The screen recording couldn’t be finalized.", suggestion: error.localizedDescription)
        }
    }

    private func fail(_ message: String, suggestion: String? = nil) {
        recordingStartedAt = nil
        state = .failed(CaptureFailure(message, recoverySuggestion: suggestion))
    }
}

extension ScreenCaptureController: DirectCaptureBackendDelegate {
    func directCaptureWillStart() {
        guard state == .presentingPicker else { return }
        state = .starting
    }

    func directCaptureDidStart(at date: Date) {
        recordingStartedAt = date
        state = .recording
    }

    func directCaptureDidCancel() {
        guard state == .presentingPicker else { return }
        state = .idle
    }

    func directCaptureDidFinish(url: URL, duration: TimeInterval, fileSize: Int64) async {
        recordingStartedAt = nil
        state = .finalizing
        await finishDirectCapture(url: url, duration: duration, fileSize: fileSize)
    }

    func directCaptureDidFail(_ failure: CaptureFailure) {
        fail(failure.message, suggestion: failure.recoverySuggestion)
    }
}
