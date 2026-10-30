import Foundation
import ImageIO
import UIKit

actor ThumbnailService {
    private let api: APIClient
    private let fileCache: FileCache
    private let offlineFiles: FileCache
    private var useNewAPI = false
    private let cache = NSCache<NSString, UIImage>()

    init(api: APIClient, fileCache: FileCache, offlineFiles: FileCache) {
        self.api = api
        self.fileCache = fileCache
        self.offlineFiles = offlineFiles
        cache.countLimit = 400
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func update(serverInfo: ServerInfo?) {
        useNewAPI = serverInfo?.supportsNewThumbnailAPI ?? false
    }

    func image(repoID: String, path: String, size: Int = 256) async -> UIImage? {
        guard !path.isEmpty else { return nil }
        let key = "\(repoID)|\(path)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let data = try? await api.thumbnailData(repoID: repoID, path: path, newAPI: useNewAPI, size: size),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    func localImage(repoID: String,
                    path: String,
                    name: String,
                    version: String,
                    size: Int = 256) async -> UIImage? {
        let key = "local|\(repoID)|\(path)|\(version)|\(size)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = offlineFiles.existingURL(repoID: repoID, path: path, name: name, version: version)
                ?? fileCache.existingURL(repoID: repoID, path: path, name: name, version: version) else {
            return nil
        }
        guard let image = await Task.detached(priority: .utility, operation: {
            Self.downsample(url: url, maxPixelSize: size)
        }).value else { return nil }
        cache.setObject(image, forKey: key, cost: size * size * 4)
        return image
    }

    private static func downsample(url: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
