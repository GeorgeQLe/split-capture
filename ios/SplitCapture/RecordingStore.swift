import Foundation

struct RecordingStore {
    enum StoreError: LocalizedError {
        case invalidRecording

        var errorDescription: String? {
            "The selected file did not produce a readable recording."
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let metadataURL: URL
    private let legacyMetadataURL: URL

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.rootURL =
            rootURL
            ?? appSupport.appendingPathComponent(
                "SplitCapture",
                isDirectory: true
            )
        metadataURL = self.rootURL.appendingPathComponent("recording-project.json")
        legacyMetadataURL = self.rootURL.appendingPathComponent("latest-recording.json")
    }

    func restore() -> RecordingProject? {
        if var project = decodeProject(),
            fileManager.fileExists(atPath: project.screenSource.localURL.path)
        {
            if let composite = project.composite,
                !fileManager.fileExists(atPath: composite.localURL.path)
            {
                project.composite = nil
                try? persist(project)
            }
            return project
        }

        guard
            let data = try? Data(contentsOf: legacyMetadataURL),
            let summary = try? JSONDecoder().decode(RecordingAsset.self, from: data),
            fileManager.fileExists(atPath: summary.localURL.path)
        else {
            return nil
        }

        let migrated = RecordingProject(
            id: UUID(),
            screenSource: summary,
            origin: .directCapture,
            composite: nil
        )
        do {
            try persist(migrated)
            try? fileManager.removeItem(at: legacyMetadataURL)
            return migrated
        } catch {
            return nil
        }
    }

    func replaceScreenSource(
        temporaryURL: URL,
        origin: RecordingOrigin,
        duration: TimeInterval,
        fileSize: Int64,
        photosStatus: PhotosStatus,
        previous: RecordingProject?
    ) throws -> RecordingProject {
        let asset = try retain(
            temporaryURL: temporaryURL,
            duration: duration,
            fileSize: fileSize,
            photosStatus: photosStatus
        )
        let project = RecordingProject(
            id: UUID(),
            screenSource: asset,
            origin: origin,
            composite: nil
        )

        do {
            try persist(project)
        } catch {
            try? fileManager.removeItem(at: asset.localURL)
            throw error
        }

        if let previous {
            remove(previous.screenSource, unless: asset.localURL)
            if let composite = previous.composite {
                remove(composite, unless: asset.localURL)
            }
        }
        return project
    }

    func replaceComposite(
        temporaryURL: URL,
        duration: TimeInterval,
        fileSize: Int64,
        in project: RecordingProject
    ) throws -> RecordingProject {
        let composite = try retain(
            temporaryURL: temporaryURL,
            duration: duration,
            fileSize: fileSize,
            photosStatus: .failed("Not saved yet")
        )
        var updated = project
        updated.composite = composite

        do {
            try persist(updated)
        } catch {
            try? fileManager.removeItem(at: composite.localURL)
            throw error
        }

        if let previous = project.composite {
            remove(previous, unless: composite.localURL)
        }
        return updated
    }

    func update(_ project: RecordingProject) throws {
        guard projectFilesExist(project) else {
            throw StoreError.invalidRecording
        }
        try persist(project)
    }

    func cleanupTemporaryRecordings(except retainedURLs: Set<URL>) {
        let temporaryDirectory = fileManager.temporaryDirectory
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil
            )
        else { return }

        for file in files
        where file.lastPathComponent.hasPrefix("split-capture-")
            && ["mp4", "mov"].contains(file.pathExtension.lowercased())
            && !retainedURLs.map(\.standardizedFileURL).contains(file.standardizedFileURL)
        {
            try? fileManager.removeItem(at: file)
        }
    }

    private func decodeProject() -> RecordingProject? {
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        return try? JSONDecoder().decode(RecordingProject.self, from: data)
    }

    private func retain(
        temporaryURL: URL,
        duration: TimeInterval,
        fileSize: Int64,
        photosStatus: PhotosStatus
    ) throws -> RecordingAsset {
        guard
            duration.isFinite,
            duration > 0,
            fileManager.fileExists(atPath: temporaryURL.path),
            let values = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]),
            let actualSize = values.fileSize,
            actualSize > 0
        else {
            throw StoreError.invalidRecording
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let id = UUID()
        let sourceExtension = temporaryURL.pathExtension.lowercased()
        let fileExtension = ["mov", "mp4"].contains(sourceExtension) ? sourceExtension : "mp4"
        let destination = rootURL.appendingPathComponent("\(id.uuidString).\(fileExtension)")
        do {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: destination)
        }

        return RecordingAsset(
            id: id,
            localURL: destination,
            duration: duration,
            fileSize: max(fileSize, Int64(actualSize)),
            photosStatus: photosStatus,
            creationDate: Date()
        )
    }

    private func projectFilesExist(_ project: RecordingProject) -> Bool {
        fileManager.fileExists(atPath: project.screenSource.localURL.path)
            && project.composite.map {
                fileManager.fileExists(atPath: $0.localURL.path)
            } != false
    }

    private func remove(_ asset: RecordingAsset, unless retainedURL: URL) {
        guard asset.localURL != retainedURL else { return }
        try? fileManager.removeItem(at: asset.localURL)
    }

    private func persist(_ project: RecordingProject) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: metadataURL, options: .atomic)
    }
}
