import AVFoundation
import Foundation
import ImageIO
import Photos

enum MotionPhotoSaver {
    /// Saves the file as an iOS Live Photo when it contains a motion-photo
    /// trailer. Returns false when the file is not a Motion Photo or the save
    /// was unsuccessful, so callers can fall back to saving a still image.
    static func saveLivePhotoIfPossible(from url: URL) async -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let still = MotionPhoto.stillImageData(from: data),
              let video = MotionPhoto.videoData(in: data) else {
            return false
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-livephoto-save-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: directory,
                                                        withIntermediateDirectories: true)) != nil else {
            return false
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let identifier = UUID().uuidString
        let imageURL = directory.appendingPathComponent(MotionPhoto.isHEIC(still) ? "image.heic" : "image.jpg")
        let rawVideoURL = directory.appendingPathComponent("raw.mov")
        let videoURL = directory.appendingPathComponent("video.mov")

        guard writeImage(still, to: imageURL, identifier: identifier),
              (try? video.write(to: rawVideoURL, options: .atomic)) != nil,
              let exportedVideo = await exportVideo(rawVideoURL,
                                                    to: videoURL,
                                                    identifier: identifier) else {
            return false
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: imageURL, options: nil)
                request.addResource(with: .pairedVideo, fileURL: exportedVideo, options: nil)
            }
            return true
        } catch {
            return false
        }
    }

    private static func writeImage(_ data: Data, to url: URL, identifier: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            return false
        }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var makerApple = (properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any]) ?? [:]
        makerApple["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary] = makerApple
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func exportVideo(_ sourceURL: URL,
                                    to outputURL: URL,
                                    identifier: String) async -> URL? {
        let asset = AVURLAsset(url: sourceURL)
        let preferred = [AVAssetExportPresetPassthrough,
                         AVAssetExportPresetHEVCHighestQuality,
                         AVAssetExportPresetHEVC1920x1080,
                         AVAssetExportPresetHighestQuality]
        guard let session = preferred.lazy.compactMap({
            AVAssetExportSession(asset: asset, presetName: $0)
        }).first else {
            return nil
        }

        try? FileManager.default.removeItem(at: outputURL)
        session.shouldOptimizeForNetworkUse = false

        let identifierItem = AVMutableMetadataItem()
        identifierItem.key = "com.apple.quicktime.content.identifier" as NSString
        identifierItem.keySpace = .quickTimeMetadata
        identifierItem.value = identifier as NSString
        identifierItem.dataType = kCMMetadataBaseDataType_UTF8 as String

        let stillImageTimeItem = AVMutableMetadataItem()
        stillImageTimeItem.key = "com.apple.quicktime.still-image-time" as NSString
        stillImageTimeItem.keySpace = .quickTimeMetadata
        stillImageTimeItem.value = 0 as NSNumber
        stillImageTimeItem.dataType = kCMMetadataBaseDataType_SInt8 as String

        session.metadata = [identifierItem, stillImageTimeItem]

        do {
            try await session.export(to: outputURL, as: .mov)
            return outputURL
        } catch {
            return nil
        }
    }
}
