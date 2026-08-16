import Foundation

enum CaptureState: Equatable, Sendable {
    case idle
    case importing
    case presentingPicker
    case starting
    case recording
    case finalizing
    case saving
    case failed(CaptureFailure)

    var title: String {
        switch self {
        case .idle: "Ready"
        case .importing: "Importing recording"
        case .presentingPicker: "Choose what to share"
        case .starting: "Starting recording"
        case .recording: "Recording"
        case .finalizing: "Finishing recording"
        case .saving: "Saving to Photos"
        case .failed: "Needs attention"
        }
    }

    var isBusy: Bool {
        switch self {
        case .importing, .presentingPicker, .starting, .finalizing, .saving:
            true
        case .idle, .recording, .failed:
            false
        }
    }
}

struct CaptureFailure: Error, Equatable, Sendable {
    let message: String
    let recoverySuggestion: String?

    init(_ message: String, recoverySuggestion: String? = nil) {
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }
}

enum PhotosStatus: Codable, Equatable, Sendable {
    case alreadyInPhotos
    case saved
    case denied
    case failed(String)

    var label: String {
        switch self {
        case .alreadyInPhotos: "Imported from Photos"
        case .saved: "Saved to Photos"
        case .denied: "Photos access denied"
        case .failed: "Photos save failed"
        }
    }

    var canRetry: Bool {
        switch self {
        case .denied, .failed: true
        case .alreadyInPhotos, .saved: false
        }
    }
}

enum RecordingOrigin: String, Codable, Equatable, Sendable {
    case photosImport
    case directCapture

    var label: String {
        switch self {
        case .photosImport: "Imported from Photos"
        case .directCapture: "Screen recording"
        }
    }
}

struct RecordingAsset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let localURL: URL
    let duration: TimeInterval
    let fileSize: Int64
    var photosStatus: PhotosStatus
    let creationDate: Date
}

typealias RecordingSummary = RecordingAsset

struct RecordingProject: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var screenSource: RecordingAsset
    let origin: RecordingOrigin
    var composite: RecordingAsset?

    var activeShareAsset: RecordingAsset {
        composite ?? screenSource
    }
}

struct CompositionResult: Sendable {
    let url: URL
    let duration: TimeInterval
}
