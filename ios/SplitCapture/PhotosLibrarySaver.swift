import Foundation
@preconcurrency import Photos

@MainActor
protocol PhotosSaving {
    func saveVideo(at url: URL) async -> PhotosStatus
}

@MainActor
struct PhotosLibrarySaver: PhotosSaving {
    func saveVideo(at url: URL) async -> PhotosStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .denied
        }

        do {
            // PhotoKit executes this block on its own queue. Marking it Sendable
            // prevents Swift 6 from inheriting MainActor isolation and trapping
            // when PhotoKit invokes it off the main actor.
            try await PHPhotoLibrary.shared().performChanges { @Sendable in
                let options = PHAssetResourceCreationOptions()
                // Keep the app-owned copy available to ShareLink after this save.
                options.shouldMoveFile = false
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: options)
            }
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
