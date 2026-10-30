import Foundation

final class ServerTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let allowUntrusted: Bool

    init(allowUntrusted: Bool) {
        self.allowUntrusted = allowUntrusted
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = ClientCertificateStore.credential(for: challenge) {
            completionHandler(.useCredential, credential)
            return
        }
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if allowUntrusted {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum NetworkSessionFactory {
    static func make(allowUntrusted: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Seafile-iOS-Swift/\(APIClient.appVersion)"]
        let delegate = ServerTrustDelegate(allowUntrusted: allowUntrusted)
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
}
