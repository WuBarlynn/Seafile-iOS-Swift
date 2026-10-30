import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum LivePhotoExportError: LocalizedError {
    case missingPairedVideo
    case compositionFailed

    var errorDescription: String? {
        switch self {
        case .missingPairedVideo:
            return String(localized: "The Live Photo video is not available yet. Please try again later.")
        case .compositionFailed:
            return String(localized: "Could not convert this Live Photo for upload.")
        }
    }
}

enum LivePhotoExport {
    static func isLivePhoto(_ asset: PHAsset) -> Bool {
        asset.mediaSubtypes.contains(.photoLive)
    }

    static func hasPairedVideo(_ asset: PHAsset) -> Bool {
        pairedResources(for: asset) != nil
    }

    /// Always returns HEIC data (JPEG sources are transcoded) with the paired
    /// video appended as a Motion Photo trailer.
    static func motionPhotoData(for asset: PHAsset) async throws -> Data {
        guard let resources = pairedResources(for: asset) else {
            throw LivePhotoExportError.missingPairedVideo
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-livephoto-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageURL = directory.appendingPathComponent("image")
        let videoURL = directory.appendingPathComponent("video")
        async let imageWrite: Void = write(resources.photo, to: imageURL)
        async let videoWrite: Void = write(resources.video, to: videoURL)
        try await imageWrite
        try await videoWrite

        let imageData = try Data(contentsOf: imageURL, options: .mappedIfSafe)
        let videoData = try Data(contentsOf: videoURL, options: .mappedIfSafe)
        let heicData = MotionPhoto.isHEIC(imageData) ? imageData : heicData(from: imageData)
        guard let heicData,
              let composed = MotionPhoto.compose(imageData: heicData, videoData: videoData) else {
            throw LivePhotoExportError.compositionFailed
        }
        return composed
    }

    private static func pairedResources(for asset: PHAsset) -> (photo: PHAssetResource, video: PHAssetResource)? {
        let resources = PHAssetResource.assetResources(for: asset)
        let photo = resources.first(where: { $0.type == .fullSizePhoto })
            ?? resources.first(where: { $0.type == .photo })
        let video = resources.first(where: { $0.type == .fullSizePairedVideo })
            ?? resources.first(where: { $0.type == .pairedVideo })
        guard let photo, let video else { return nil }
        return (photo, video)
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func heicData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output,
                                                                 UTType.heic.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
