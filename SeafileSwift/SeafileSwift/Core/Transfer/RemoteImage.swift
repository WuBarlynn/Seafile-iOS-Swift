import SwiftUI
import UIKit

actor RemoteImageLoader {
    static let shared = RemoteImageLoader()

    private let cache = NSCache<NSString, UIImage>()
    private let trustedSession = NetworkSessionFactory.make(allowUntrusted: false)
    private let untrustedSession = NetworkSessionFactory.make(allowUntrusted: true)

    func image(url: URL, token: String?, allowUntrusted: Bool) async -> UIImage? {
        let key = "\(url.absoluteString)|\(allowUntrusted)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var request = URLRequest(url: url)
        request.setValue("image/*,*/*", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        let session = allowUntrusted ? untrustedSession : trustedSession
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var token: String?
    var allowUntrusted = false
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            image = await RemoteImageLoader.shared.image(url: url,
                                                         token: token,
                                                         allowUntrusted: allowUntrusted)
        }
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: URL?, token: String?, allowUntrusted: Bool = false, contentMode: ContentMode = .fill) {
        self.init(url: url,
                  token: token,
                  allowUntrusted: allowUntrusted,
                  contentMode: contentMode,
                  placeholder: { Color(.secondarySystemBackground) })
    }
}
