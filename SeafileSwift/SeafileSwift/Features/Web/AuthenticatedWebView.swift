import SwiftUI
import UIKit
import WebKit

struct AuthenticatedWebView: UIViewRepresentable {
    let baseURL: URL
    let initialURL: URL
    let token: String?
    let allowUntrusted: Bool
    var preferMobileLogin: Bool = true
    var useEphemeralStore: Bool = false
    var useDesktopUserAgent: Bool = false
    @Binding var progress: Double
    var onPageChanged: ((URL?, String?) -> Void)? = nil
    var onDownload: ((URL, String?, [HTTPCookie]) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if useEphemeralStore {
            configuration.websiteDataStore = .nonPersistent()
        }
        if useDesktopUserAgent {
            configuration.defaultWebpagePreferences.preferredContentMode = .desktop
            // OnlyOffice stays blank in WKWebView when SharedWorker is used
            // (its official iOS webview demo removes it). Seafile also picks
            // the mobile editor from screen.width, so expose a desktop size.
            let desktopHints = """
            delete window.SharedWorker;
            try {
              Object.defineProperty(window.screen, 'width', { configurable: true, get: function () { return 1280; } });
              Object.defineProperty(window.screen, 'height', { configurable: true, get: function () { return 800; } });
              Object.defineProperty(window.screen, 'availWidth', { configurable: true, get: function () { return 1280; } });
              Object.defineProperty(window.screen, 'availHeight', { configurable: true, get: function () { return 800; } });
            } catch (e) {}
            """
            let script = WKUserScript(source: desktopHints,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
            configuration.userContentController.addUserScript(script)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        if useDesktopUserAgent {
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Safari/605.1.15"
        }
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.start(webView: webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: AuthenticatedWebView
        private weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?
        private let serverHost: String?
        private var loginRetryCount = 0

        init(parent: AuthenticatedWebView) {
            self.parent = parent
            serverHost = URLComponents(url: parent.baseURL, resolvingAgainstBaseURL: false)?.host
        }

        func start(webView: WKWebView) {
            self.webView = webView
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.progress = webView.estimatedProgress
                }
            }
            if parent.preferMobileLogin {
                loadViaMobileLogin(parent.initialURL)
            } else {
                loadDirect(parent.initialURL)
            }
        }

        func stop() {
            observation?.invalidate()
            observation = nil
        }

        private func loadDirect(_ next: URL) {
            guard let webView else { return }
            var request = URLRequest(url: next)
            if let token = parent.token, !token.isEmpty {
                request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            }
            webView.load(request)
        }

        private func loadViaMobileLogin(_ next: URL) {
            guard let webView else { return }
            if let token = parent.token, !token.isEmpty,
               var components = URLComponents(url: parent.baseURL, resolvingAgainstBaseURL: false) {
                var basePath = components.path
                while basePath.hasSuffix("/") { basePath.removeLast() }
                components.path = basePath + "/mobile-login/"
                components.queryItems = [URLQueryItem(name: "next", value: next.absoluteString)]
                if let loginURL = components.url {
                    var request = URLRequest(url: loginURL)
                    request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
                    webView.load(request)
                    return
                }
            }
            webView.load(URLRequest(url: next))
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let loweredPath = url.path.lowercased()
            if url.host == serverHost,
               loweredPath.contains("login"),
               !loweredPath.contains("mobile-login") {
                guard loginRetryCount < 2 else {
                    decisionHandler(.allow)
                    return
                }
                loginRetryCount += 1
                // Establish a fresh web session for the original target, not for
                // the login page itself, otherwise the web view loops back to it.
                loadViaMobileLogin(parent.initialURL)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.onPageChanged?(webView.url, webView.title)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onPageChanged?(webView.url, webView.title)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard navigationResponse.isForMainFrame,
                  !navigationResponse.canShowMIMEType,
                  let onDownload = parent.onDownload,
                  let url = navigationResponse.response.url else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            let filename = navigationResponse.response.suggestedFilename
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                DispatchQueue.main.async {
                    onDownload(url, filename, cookies)
                }
            }
        }

        func webView(_ webView: WKWebView,
                     didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if let credential = ClientCertificateStore.credential(for: challenge) {
                completionHandler(.useCredential, credential)
            } else if parent.allowUntrusted,
               challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}
