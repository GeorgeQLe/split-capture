import Foundation

enum CaptureState: Equatable, Sendable {
    case idle
    case presentingPicker
    case starting
    case recording
    case finalizing
    case saving
    case failed(CaptureFailure)

    var title: String {
        switch self {
        case .idle: "Ready"
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
        case .presentingPicker, .starting, .finalizing, .saving:
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
    case saved
    case denied
    case failed(String)

    var label: String {
        switch self {
        case .saved: "Saved to Photos"
        case .denied: "Photos access denied"
        case .failed: "Photos save failed"
        }
    }

    var canRetry: Bool {
        self != .saved
    }
}

struct RecordingSummary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let localURL: URL
    let duration: TimeInterval
    let fileSize: Int64
    var photosStatus: PhotosStatus
    let creationDate: Date
}
