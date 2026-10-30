import Foundation
import UIKit

actor ThumbnailService {
    private let api: APIClient
    private var useNewAPI = false
    private let cache = NSCache<NSString, UIImage>()

    init(api: APIClient) {
        self.api = api
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
}
