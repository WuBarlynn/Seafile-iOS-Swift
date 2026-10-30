import SafariServices
import SwiftUI
import UIKit
import WebKit

struct SSOLoginView: View {
    let onSuccess: (Account, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var serverAddress: String
    @State private var allowUntrusted: Bool
    @State private var stage: Stage
    @State private var api: APIClient?
    @State private var serverURL: URL?
    @State private var browserLink: URL?
    @State private var showSafari = false
    @State private var shibbolethURL: URL?
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?
    @FocusState private var serverFieldFocused: Bool

    private enum Stage {
        case enterServer
        case connecting
        case waitingForBrowser
        case web
        case failed
    }

    init(serverAddress: String = "",
         allowUntrusted: Bool = false,
         onSuccess: @escaping (Account, String) -> Void) {
        self.onSuccess = onSuccess
        _serverAddress = State(initialValue: serverAddress)
        _allowUntrusted = State(initialValue: allowUntrusted)
        _stage = State(initialValue: serverAddress.trimmingCharacters(in: .whitespaces).isEmpty ? .enterServer : .connecting)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                content
            }
            .navigationTitle("Single Sign-On")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        pollTask?.cancel()
                        dismiss()
                    }
                }
            }
            .task {
                if stage == .connecting { await prepare() }
            }
            .onChange(of: scenePhase) { _, newValue in
                if newValue == .active { resumePollingIfNeeded() }
            }
            .sheet(isPresented: $showSafari) {
                if let browserLink {
                    SafariSheet(url: browserLink) {
                        showSafari = false
                    }
                    .ignoresSafeArea()
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .enterServer:
            serverEntry
        case .connecting:
            VStack(spacing: 16) {
                ProgressView().tint(.seafileOrange)
                Text("Contacting \(displayServer)…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 26, padding: 26)
            .padding(.horizontal, 24)
        case .waitingForBrowser:
            browserWaiting
        case .web:
            if let shibbolethURL {
                ShibbolethWebView(url: shibbolethURL,
                                  allowUntrusted: allowUntrusted) { username, token in
                    complete(username: username, token: token)
                }
                .ignoresSafeArea(edges: .bottom)
            } else {
                failure("Could not build the SSO request.")
            }
        case .failed:
            failure(errorMessage ?? "Single sign-on failed.")
        }
    }

    private var serverEntry: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(systemName: "person.badge.key.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.seafileOrange)
                        .frame(width: 68, height: 68)
                        .glassEffect(.regular.tint(Color.seafileOrange.opacity(0.12)), in: .circle)
                    Text("Sign in with your organization account")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Enter your Seafile server address. You will be redirected to your identity provider.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 20)

                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(Color.seafileOrange)
                        TextField("https://seafile.example.com", text: $serverAddress)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($serverFieldFocused)
                            .submitLabel(.continue)
                            .onSubmit { startFromEntry() }
                    }
                    .padding(16)
                }
                .glassCard(cornerRadius: 22, padding: 0)

                Toggle(isOn: $allowUntrusted) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow untrusted certificates")
                            .font(.subheadline.weight(.medium))
                        Text("Only for servers with self-signed certificates you trust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.seafileOrange)
                .glassCard(cornerRadius: 20, padding: 16)

                Button {
                    startFromEntry()
                } label: {
                    Label("Continue with Single Sign-On", systemImage: "arrow.right")
                }
                .buttonStyle(GlassProminentButtonStyle())
                .disabled(serverAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(serverAddress.trimmingCharacters(in: .whitespaces).isEmpty ? 0.6 : 1)
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear { serverFieldFocused = true }
    }

    private var browserWaiting: some View {
        VStack(spacing: 18) {
            Image(systemName: "safari.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.seafileOrange)
                .frame(width: 68, height: 68)
                .glassEffect(.regular.tint(Color.seafileOrange.opacity(0.12)), in: .circle)
            Text("Continue in the browser")
                .font(.headline)
            Text("Complete the sign-in on the page that opens, then return to Seafile. This screen will update automatically.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ProgressView().tint(.seafileOrange)
                Text("Waiting for sign-in…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Button {
                    showSafari = true
                } label: {
                    Label("Open Sign-In Page", systemImage: "safari")
                }
                .buttonStyle(GlassProminentButtonStyle())

                Button {
                    if let browserLink {
                        UIApplication.shared.open(browserLink)
                    }
                } label: {
                    Label("Open in Safari", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .padding(24)
        .glassCard(cornerRadius: 28, padding: 0)
        .padding(.horizontal, 24)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Single sign-on failed")
                .font(.headline)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                errorMessage = nil
                stage = .connecting
                Task { await prepare() }
            }
            .buttonStyle(GlassProminentButtonStyle())
        }
        .padding(26)
        .glassCard(cornerRadius: 26, padding: 0)
        .padding(.horizontal, 24)
    }

    private var displayServer: String {
        APIClient.serverURL(from: serverAddress)?.absoluteString ?? serverAddress
    }

    private func startFromEntry() {
        guard APIClient.serverURL(from: serverAddress) != nil else {
            errorMessage = String(localized: "Enter a valid server address.")
            stage = .failed
            return
        }
        serverFieldFocused = false
        stage = .connecting
        Task { await prepare() }
    }

    private func prepare() async {
        guard let url = APIClient.serverURL(from: serverAddress) else {
            errorMessage = String(localized: "Enter a valid server address.")
            stage = .failed
            return
        }
        serverURL = url
        let client = APIClient(serverURL: url, token: nil, allowUntrusted: allowUntrusted)
        api = client
        do {
            let info = try await client.serverInfo()
            if info.has("client-sso-via-local-browser") {
                let link = try await client.clientSSOLink()
                browserLink = link
                stage = .waitingForBrowser
                showSafari = true
                startPolling(client: client, link: link)
            } else {
                shibbolethURL = Self.makeShibbolethURL(base: url)
                stage = .web
            }
        } catch {
            errorMessage = error.localizedDescription
            stage = .failed
        }
    }

    private func startPolling(client: APIClient, link: URL) {
        pollTask?.cancel()
        pollTask = Task {
            for _ in 0..<160 {
                if Task.isCancelled { return }
                do {
                    if let session = try await client.clientSSOStatus(link: link) {
                        await MainActor.run {
                            complete(username: session.username, token: session.token)
                        }
                        return
                    }
                } catch let error as APIError {
                    if case .message = error {
                        await MainActor.run {
                            errorMessage = error.localizedDescription
                            stage = .failed
                        }
                        return
                    }
                } catch {
                    // Transient network failure while the user is in the browser.
                }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            await MainActor.run {
                errorMessage = String(localized: "Timed out waiting for the browser sign-in.")
                stage = .failed
            }
        }
    }

    private func resumePollingIfNeeded() {
        guard stage == .waitingForBrowser,
              let api,
              let browserLink,
              pollTask?.isCancelled != false else { return }
        startPolling(client: api, link: browserLink)
    }

    private func complete(username: String, token: String) {
        guard let serverURL else { return }
        pollTask?.cancel()
        showSafari = false
        Task {
            let client = APIClient(serverURL: serverURL, token: token, allowUntrusted: allowUntrusted)
            let info = try? await client.accountInfo()
            await MainActor.run {
                let account = Account(serverURL: serverURL,
                                      username: username,
                                      displayName: info?.name,
                                      email: info?.email,
                                      allowUntrustedCertificate: allowUntrusted,
                                      isSSO: true)
                onSuccess(account, token)
                dismiss()
            }
        }
    }

    private static func makeShibbolethURL(base: URL) -> URL {
        var components = URLComponents(string: base.absoluteString + "/shib-login/")
        components?.queryItems = [
            URLQueryItem(name: "shib_platform_version", value: APIClient.platformVersion),
            URLQueryItem(name: "shib_device_name", value: APIClient.deviceName),
            URLQueryItem(name: "shib_platform", value: "ios"),
            URLQueryItem(name: "shib_device_id", value: APIClient.deviceID),
            URLQueryItem(name: "shib_client_version", value: APIClient.appVersion)
        ]
        return components?.url ?? base.appendingPathComponent("shib-login/")
    }
}

private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    var onFinish: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onFinish()
        }
    }
}

private struct ShibbolethWebView: UIViewRepresentable {
    let url: URL
    let allowUntrusted: Bool
    let onAuthenticated: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear

        context.coordinator.webView = webView
        context.coordinator.clearAuthCookies()
        context.coordinator.startPolling()
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: ShibbolethWebView
        weak var webView: WKWebView?
        private var timer: Timer?
        private var completed = false

        init(parent: ShibbolethWebView) {
            self.parent = parent
        }

        func startPolling() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                self?.checkCookies()
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        func clearAuthCookies() {
            let store = WKWebsiteDataStore.default().httpCookieStore
            store.getAllCookies { cookies in
                for cookie in cookies where cookie.name == "seahub_auth" {
                    store.delete(cookie)
                }
            }
        }

        func checkCookies() {
            guard !completed, let webView else { return }
            webView.evaluateJavaScript("document.cookie") { [weak self] value, _ in
                guard let self,
                      let cookieString = value as? String,
                      let result = Self.parseSeahubAuth(cookieString) else { return }
                self.completed = true
                self.stop()
                DispatchQueue.main.async {
                    self.parent.onAuthenticated(result.username, result.token)
                }
            }
        }

        private static func parseSeahubAuth(_ cookies: String) -> (username: String, token: String)? {
            for part in cookies.split(separator: ";") {
                let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard item.hasPrefix("seahub_auth=") else { continue }
                var value = String(item.dropFirst("seahub_auth=".count))
                if let decoded = value.removingPercentEncoding { value = decoded }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard let at = value.lastIndex(of: "@") else { continue }
                let username = String(value[..<at])
                let token = String(value[value.index(after: at)...])
                if !username.isEmpty, !token.isEmpty {
                    return (username, token)
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            checkCookies()
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
