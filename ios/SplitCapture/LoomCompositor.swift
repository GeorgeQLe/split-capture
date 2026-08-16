@preconcurrency import AVFoundation
import Foundation

enum LoomCompositor {
    enum CompositionError: LocalizedError {
        case missingScreenVideo
        case missingCameraVideo
        case cannotCreateCompositionTrack
        case cannotCreateExporter

        var errorDescription: String? {
            switch self {
            case .missingScreenVideo:
                "The screen recording has no readable video track."
            case .missingCameraVideo:
                "The presenter take has no readable video track."
            case .cannotCreateCompositionTrack:
                "The video composition could not be created."
            case .cannotCreateExporter:
                "The finished video could not be encoded."
            }
        }
    }

    static func compose(screenURL: URL, cameraURL: URL) async throws -> CompositionResult {
        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = AVURLAsset(url: cameraURL)
        let screenVideoTracks = try await screenAsset.loadTracks(withMediaType: .video)
        let cameraVideoTracks = try await cameraAsset.loadTracks(withMediaType: .video)

        guard let screenVideo = screenVideoTracks.first else {
            throw CompositionError.missingScreenVideo
        }
        guard let cameraVideo = cameraVideoTracks.first else {
            throw CompositionError.missingCameraVideo
        }

        let screenDuration = try await screenAsset.load(.duration)
        let cameraDuration = try await cameraAsset.load(.duration)
        let duration = CMTimeMinimum(screenDuration, cameraDuration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)
        let composition = AVMutableComposition()

        guard
            let screenCompositionTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ),
            let cameraCompositionTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw CompositionError.cannotCreateCompositionTrack
        }

        try screenCompositionTrack.insertTimeRange(timeRange, of: screenVideo, at: .zero)
        try cameraCompositionTrack.insertTimeRange(timeRange, of: cameraVideo, at: .zero)

        let screenTransform = try await screenVideo.load(.preferredTransform)
        let screenNaturalSize = try await screenVideo.load(.naturalSize)
        let cameraTransform = try await cameraVideo.load(.preferredTransform)
        let cameraNaturalSize = try await cameraVideo.load(.naturalSize)

        let screenGeometry = normalizedGeometry(
            naturalSize: screenNaturalSize,
            preferredTransform: screenTransform
        )
        let cameraGeometry = normalizedGeometry(
            naturalSize: cameraNaturalSize,
            preferredTransform: cameraTransform
        )

        let renderSize = screenGeometry.size
        let pipWidth = renderSize.width * 0.28
        let pipScale = pipWidth / max(cameraGeometry.size.width, 1)
        let pipSize = CGSize(
            width: cameraGeometry.size.width * pipScale,
            height: cameraGeometry.size.height * pipScale
        )
        let margin = renderSize.width * 0.04

        var screenLayerConfiguration = AVVideoCompositionLayerInstruction.Configuration(
            assetTrack: screenCompositionTrack
        )
        screenLayerConfiguration.setTransform(screenGeometry.transform, at: .zero)
        let screenInstruction = AVVideoCompositionLayerInstruction(
            configuration: screenLayerConfiguration
        )

        var cameraLayerConfiguration = AVVideoCompositionLayerInstruction.Configuration(
            assetTrack: cameraCompositionTrack
        )
        let pipTransform = cameraGeometry.transform
            .concatenating(CGAffineTransform(scaleX: pipScale, y: pipScale))
            .concatenating(
                CGAffineTransform(
                    translationX: renderSize.width - pipSize.width - margin,
                    y: renderSize.height - pipSize.height - margin
                )
            )
        cameraLayerConfiguration.setTransform(pipTransform, at: .zero)
        let cameraInstruction = AVVideoCompositionLayerInstruction(
            configuration: cameraLayerConfiguration
        )

        let instruction = AVVideoCompositionInstruction(
            configuration: AVVideoCompositionInstruction.Configuration(
                backgroundColor: nil,
                enablePostProcessing: false,
                layerInstructions: [cameraInstruction, screenInstruction],
                requiredSourceSampleDataTrackIDs: [],
                timeRange: timeRange
            )
        )

        var videoConfiguration = try await AVVideoComposition.Configuration(
            for: composition,
            prototypeInstruction: instruction
        )
        videoConfiguration.instructions = [instruction]
        videoConfiguration.renderSize = renderSize
        let nominalFrameRate = try await screenVideo.load(.nominalFrameRate)
        videoConfiguration.frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(max(nominalFrameRate.rounded(), 30))
        )
        let videoComposition = AVVideoComposition(configuration: videoConfiguration)

        try await addAudio(
            from: screenAsset,
            to: composition,
            timeRange: timeRange
        )
        try await addAudio(
            from: cameraAsset,
            to: composition,
            timeRange: timeRange
        )

        guard
            let exporter = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            )
        else {
            throw CompositionError.cannotCreateExporter
        }
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "split-capture-composite-\(UUID().uuidString).mp4"
        )
        try await exporter.export(to: outputURL, as: .mp4)

        return CompositionResult(
            url: outputURL,
            duration: max(duration.seconds, 0)
        )
    }

    private static func addAudio(
        from asset: AVAsset,
        to composition: AVMutableComposition,
        timeRange: CMTimeRange
    ) async throws {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for source in audioTracks {
            guard
                let destination = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else { continue }

            let sourceDuration = try await source.load(.timeRange).duration
            let audioDuration = CMTimeMinimum(timeRange.duration, sourceDuration)
            guard audioDuration > .zero else { continue }
            try destination.insertTimeRange(
                CMTimeRange(start: .zero, duration: audioDuration),
                of: source,
                at: .zero
            )
        }
    }

    private static func normalizedGeometry(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform
    ) -> (size: CGSize, transform: CGAffineTransform) {
        let transformed = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
        let size = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        let normalization = CGAffineTransform(
            translationX: -transformed.minX,
            y: -transformed.minY
        )
        return (size, preferredTransform.concatenating(normalization))
    }
}
