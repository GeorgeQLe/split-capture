import Foundation

struct RecordingStore {
    enum StoreError: LocalizedError {
        case invalidRecording

        var errorDescription: String? {
            "ScreenCaptureKit did not produce a readable recording."
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let metadataURL: URL

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
        metadataURL = self.rootURL.appendingPathComponent("latest-recording.json")
    }

    func restore() -> RecordingSummary? {
        guard
            let data = try? Data(contentsOf: metadataURL),
            let summary = try? JSONDecoder().decode(RecordingSummary.self, from: data),
            fileManager.fileExists(atPath: summary.localURL.path)
        else {
            return nil
        }
        return summary
    }

    func promote(
        temporaryURL: URL,
        duration: TimeInterval,
        fileSize: Int64,
        previous: RecordingSummary?
    ) throws -> RecordingSummary {
        guard
            fileSize > 0,
            fileManager.fileExists(atPath: temporaryURL.path),
            let values = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]),
            let actualSize = values.fileSize,
            actualSize > 0
        else {
            throw StoreError.invalidRecording
        }

        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let id = UUID()
        let destination = rootURL.appendingPathComponent("\(id.uuidString).mp4")
        try fileManager.moveItem(at: temporaryURL, to: destination)

        let summary = RecordingSummary(
            id: id,
            localURL: destination,
            duration: duration,
            fileSize: max(fileSize, Int64(actualSize)),
            photosStatus: .failed("Not saved yet"),
            creationDate: Date()
        )

        do {
            try persist(summary)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }

        if let previous, previous.localURL != destination {
            try? fileManager.removeItem(at: previous.localURL)
        }
        return summary
    }

    func update(_ summary: RecordingSummary) throws {
        guard fileManager.fileExists(atPath: summary.localURL.path) else {
            throw StoreError.invalidRecording
        }
        try persist(summary)
    }

    func cleanupTemporaryRecordings(except retainedURL: URL?) {
        let temporaryDirectory = fileManager.temporaryDirectory
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil
            )
        else {
            return
        }

        for file in files
        where file.lastPathComponent.hasPrefix("split-capture-")
            && file.pathExtension == "mp4"
            && file != retainedURL
        {
            try? fileManager.removeItem(at: file)
        }
    }

    private func persist(_ summary: RecordingSummary) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: metadataURL, options: .atomic)
    }
}
