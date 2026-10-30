import Foundation
import UIKit

actor AvatarStore {
    static let shared = AvatarStore()

    private let cache = NSCache<NSString, UIImage>()

    func image(for account: Account, token: String?) async -> UIImage? {
        guard let token, !token.isEmpty else { return nil }
        let key = account.id as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let baseURL = APIClient.serverURL(from: account.serverAddress) else { return nil }
        let client = APIClient(serverURL: baseURL,
                               token: token,
                               allowUntrusted: account.allowUntrustedCertificate)
        guard let data = try? await client.avatarData(username: account.username),
              let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }

    func clear(accountID: String) {
        cache.removeObject(forKey: accountID as NSString)
    }
}
