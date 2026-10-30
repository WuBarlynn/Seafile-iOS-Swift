import SwiftUI
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct SDocImageItem: Sendable {
    let data: Data
    let fileName: String
    let mimeType: String
}

@MainActor
@Observable
final class SDocWebModel {
    weak var webView: WKWebView?
    var isEditing = false
    var progress: Double = 0
    var toast: String?
    var pageOptions: SDocPageOptions?
    var canUndo = false
    var canRedo = false
    var currentStyle = "paragraph"
    var isUploadingImages = false

    private var didAutoEdit = false

    private static let pageOptionsScript =
        "(function(){try{if(window.app&&window.app.pageOptions){return JSON.stringify(window.app.pageOptions);}return null;}catch(e){return null;}})();"
    private static let outlinesScript =
        "(function(){try{if(window.seadroid&&window.seadroid.outlines){return JSON.stringify(window.seadroid.outlines);}return null;}catch(e){return null;}})();"
    private static let historyScript =
        "(function(){try{if(window.seadroid&&window.seadroid.history){return JSON.stringify(window.seadroid.history);}return null;}catch(e){return null;}})();"

    func reset() {
        progress = 0
        isEditing = false
        pageOptions = nil
        canUndo = false
        canRedo = false
        currentStyle = "paragraph"
        isUploadingImages = false
        didAutoEdit = false
    }

    func pageDidFinish() {
        pageOptions = nil
        isEditing = false
        canUndo = false
        canRedo = false
        currentStyle = "paragraph"
        didAutoEdit = false
    }

    func enterEditOnLoad() {
        guard !didAutoEdit, !isEditing else { return }
        didAutoEdit = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !isEditing else { return }
            let ok = await invokeBridge(action: "sdoc.editor.data.edit", data: "{\"edit\":true}")
            if ok {
                isEditing = true
                canUndo = false
                canRedo = false
                await refreshHistory()
            }
        }
    }

    func toggleEdit() {
        let next = !isEditing
        Task {
            let ok = await invokeBridge(action: "sdoc.editor.data.edit",
                                        data: next ? "{\"edit\":true}" : "{\"edit\":false}")
            if ok {
                isEditing = next
                if next {
                    canUndo = false
                    canRedo = false
                    await refreshHistory()
                }
            } else {
                toast = String(localized: "Not supported feature")
            }
        }
    }

    func triggerEditorAction(_ type: String) {
        guard !type.isEmpty else { return }
        let payload: [String: Any] = ["type": type]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        Task {
            let ok = await invokeBridge(action: "sdoc.toolbar.menu.trigger", data: text)
            if ok { await refreshHistory() }
        }
    }

    func updateSelection(_ payload: Any?) {
        let object: Any?
        if let text = payload as? String {
            object = Self.jsonObject(from: text)
        } else {
            object = payload
        }
        guard let dict = object as? [String: Any],
              let type = dict["type"] as? String,
              !type.isEmpty else { return }
        currentStyle = type
    }

    func refreshHistory() async {
        guard let webView,
              let result = try? await webView.evaluateJavaScript(Self.historyScript),
              let object = Self.jsonObject(from: result) as? [String: Any] else {
            return
        }
        canUndo = (object["undos"] as? [Any])?.isEmpty == false
        canRedo = (object["redos"] as? [Any])?.isEmpty == false
    }

    func insertImages(_ items: [SDocImageItem], allowUntrusted: Bool) async {
        guard !items.isEmpty, !isUploadingImages else { return }
        guard let options = await loadPageOptions() else {
            toast = String(localized: "Server error, please refresh")
            return
        }
        isUploadingImages = true
        defer { isUploadingImages = false }

        let client = SDocClient(pageOptions: options, allowUntrusted: allowUntrusted)
        var nodes: [[String: String]] = []
        var failures = 0
        for item in items {
            do {
                let paths = try await client.uploadImage(docUUID: options.docUUID,
                                                         data: item.data,
                                                         fileName: item.fileName,
                                                         mimeType: item.mimeType)
                if let path = paths.first(where: { !$0.isEmpty }) {
                    nodes.append(["src": path])
                } else {
                    failures += 1
                }
            } catch {
                failures += 1
            }
        }

        if nodes.isEmpty {
            toast = String(localized: "Upload failed")
            return
        }

        let payload: [String: Any] = ["type": "local-image", "images": nodes]
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let text = String(data: data, encoding: .utf8) {
            _ = await invokeBridge(action: "sdoc.toolbar.menu.trigger", data: text)
            await refreshHistory()
        }
        if failures > 0 {
            toast = String(format: String(localized: "%lld image(s) failed to upload"), failures)
        }
    }

    func loadPageOptions() async -> SDocPageOptions? {
        if let pageOptions { return pageOptions }
        guard let webView,
              let result = try? await webView.evaluateJavaScript(Self.pageOptionsScript),
              let object = Self.jsonObject(from: result),
              let options = SDocPageOptions(json: object) else {
            return nil
        }
        pageOptions = options
        return options
    }

    func loadOutlines() async -> [SDocOutlineItem] {
        guard let webView,
              let result = try? await webView.evaluateJavaScript(Self.outlinesScript),
              let object = Self.jsonObject(from: result) else {
            return []
        }
        return SDocOutlineItem.parse(object)
    }

    func selectOutline(_ item: SDocOutlineItem) {
        guard let data = try? JSONSerialization.data(withJSONObject: item.payloadWithText),
              let payload = String(data: data, encoding: .utf8) else { return }
        Task { _ = await invokeBridge(action: "sdoc.outline.data.select", data: payload) }
    }

    private func invokeBridge(action: String, data: String) async -> Bool {
        guard let webView else { return false }
        let model: [String: Any] = ["action": action, "data": data, "v": 2]
        guard let modelData = try? JSONSerialization.data(withJSONObject: model),
              let modelString = String(data: modelData, encoding: .utf8),
              let literalData = try? JSONSerialization.data(withJSONObject: modelString, options: [.fragmentsAllowed]),
              let literal = String(data: literalData, encoding: .utf8) else { return false }

        let script = """
        (function(){
          var d = \(literal);
          if (window.WebViewJavascriptBridge && typeof WebViewJavascriptBridge._invoke === 'function') {
            WebViewJavascriptBridge._invoke('callJsFunction', d);
            return 'OK';
          }
          return 'NO_BRIDGE';
        })();
        """
        guard let result = try? await webView.evaluateJavaScript(script),
              let value = result as? String else { return false }
        return value == "OK"
    }

    private static func jsonObject(from result: Any?) -> Any? {
        if let string = result as? String {
            guard let data = string.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
        if let result, !(result is NSNull) { return result }
        return nil
    }
}

struct SDocWebScreen: View {
    let title: String
    let repoID: String
    let path: String
    var canEdit: Bool = true

    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var model = SDocWebModel()
    @State private var reloadID = UUID()
    @State private var outlineItems: [SDocOutlineItem] = []
    @State private var showOutline = false
    @State private var showProperties = false
    @State private var commentsPageOptions: SDocPageOptions?
    @State private var isLoadingMetadata = false
    @State private var showImageMenu = false
    @State private var pendingInsertSource: SDocInsertImageSource?
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showImageImporter = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ZStack(alignment: .top) {
                SDocWebView(baseURL: session.account.serverURL,
                            repoID: repoID,
                            path: path,
                            token: session.api.token,
                            allowUntrusted: session.account.allowUntrustedCertificate,
                            canEdit: canEdit,
                            model: model)
                    .id(reloadID)

                if model.progress > 0, model.progress < 1 {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .tint(.seafileOrange)
                }
            }
            .background(Color(.systemBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.isEditing {
                    editorToolbar
                } else {
                    viewerToolbar
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canEdit {
                        Button {
                            model.toggleEdit()
                        } label: {
                            Label(model.isEditing ? "Done" : "Edit",
                                  systemImage: model.isEditing ? "checkmark" : "pencil")
                        }
                        .labelStyle(.iconOnly)
                        .fontWeight(.semibold)
                    }
                    Button {
                        reloadID = UUID()
                        model.reset()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
            .seafileToast($model.toast)
            .sheet(isPresented: $showOutline) {
                SDocOutlineSheet(items: outlineItems) { item in
                    model.selectOutline(item)
                }
            }
            .sheet(isPresented: $showProperties) {
                SDocPropertiesSheet(repoID: repoID, path: path, api: session.api, canEdit: canEdit)
            }
            .fullScreenCover(item: $commentsPageOptions) { options in
                SDocCommentsView(pageOptions: options,
                                 documentTitle: title,
                                 repoID: repoID,
                                 account: session.account,
                                 api: session.api)
            }
            .sheet(isPresented: $showImageMenu, onDismiss: openPendingImageSource) {
                SDocInsertImageSheet(canTakePhoto: UIImagePickerController.isSourceTypeAvailable(.camera)) { source in
                    pendingInsertSource = source
                }
            }
            .photosPicker(isPresented: $showPhotoPicker,
                          selection: $photoItems,
                          maxSelectionCount: 10,
                          matching: .images)
            .onChange(of: photoItems) { _, items in
                processPickedPhotos(items)
            }
            .sheet(isPresented: $showCamera) {
                SDocCameraPickerSheet { item in
                    Task {
                        await model.insertImages([item],
                                                 allowUntrusted: session.account.allowUntrustedCertificate)
                    }
                }
            }
            .fileImporter(isPresented: $showImageImporter,
                          allowedContentTypes: [.image],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    processImageURLs(urls)
                case .failure(let error):
                    model.toast = error.localizedDescription
                }
            }
        }
    }

    private var viewerToolbar: some View {
        HStack(spacing: 0) {
            viewerButton("list.bullet.indent", label: "Outline", disabled: isLoadingMetadata) {
                Task { await openOutline() }
            }
            Spacer()
            viewerButton("info.circle", label: "Properties") {
                showProperties = true
            }
            Spacer()
            viewerButton("bubble.left.and.bubble.right", label: "Comments", disabled: isLoadingMetadata) {
                Task { await openComments() }
            }
        }
        .padding(.horizontal, 48)
        .frame(height: 46)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func viewerButton(_ systemImage: String,
                              label: String,
                              disabled: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(LocalizedStringKey(label))
    }

    private var editorToolbar: some View {
        let checklist = model.currentStyle == "check_list_item"
        return HStack(spacing: 3) {
            editorButton("arrow.uturn.backward", label: "Undo", disabled: !model.canUndo) {
                model.triggerEditorAction("undo")
            }
            editorButton("arrow.uturn.forward", label: "Redo", disabled: !model.canRedo) {
                model.triggerEditorAction("redo")
            }
            editorDivider

            Menu {
                ForEach(Self.styleOptions, id: \.key) { option in
                    Button {
                        model.triggerEditorAction(option.key)
                    } label: {
                        Text(LocalizedStringKey(option.title))
                    }
                }
            } label: {
                HStack(spacing: 1) {
                    Image(systemName: styleSymbol)
                        .font(.system(size: 17, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(.primary)
                .frame(width: 42, height: 34)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .disabled(checklist)
            .opacity(checklist ? 0.35 : 1)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Paragraph style")

            editorDivider

            editorButton("list.bullet", label: "Bulleted list",
                         disabled: checklist,
                         selected: model.currentStyle == "unordered_list") {
                model.triggerEditorAction("unordered_list")
            }
            editorButton("list.number", label: "Numbered list",
                         disabled: checklist,
                         selected: model.currentStyle == "ordered_list") {
                model.triggerEditorAction("ordered_list")
            }
            editorButton("checklist", label: "Checklist",
                         selected: checklist) {
                model.triggerEditorAction("check_list_item")
            }

            editorDivider

            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil,
                                                from: nil,
                                                for: nil)
                showImageMenu = true
            } label: {
                Group {
                    if model.isUploadingImages {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                }
                .frame(width: 34, height: 34)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isUploadingImages)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Insert Image")

            editorButton("keyboard.chevron.compact.down", label: "Hide keyboard") {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                to: nil,
                                                from: nil,
                                                for: nil)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .frame(height: 46)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var editorDivider: some View {
        Divider()
            .frame(height: 20)
            .padding(.horizontal, 1)
    }

    private var styleSymbol: String {
        switch model.currentStyle {
        case "unordered_list": return "list.bullet"
        case "ordered_list": return "list.number"
        case "check_list_item": return "checklist"
        case "title", "header1", "header2", "header3", "header4", "header5", "header6":
            return "textformat.size"
        case "subtitle": return "textformat.size.smaller"
        default: return "textformat"
        }
    }

    private func editorButton(_ systemImage: String,
                              label: String,
                              disabled: Bool = false,
                              selected: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(selected ? Color.seafileOrange : .primary)
                .frame(width: 34, height: 34)
                .background(selected ? Color.seafileOrange.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(LocalizedStringKey(label))
    }

    private static let styleOptions: [(key: String, title: String)] = [
        ("paragraph", "Paragraph"),
        ("title", "Title"),
        ("subtitle", "Subtitle"),
        ("header1", "Heading 1"),
        ("header2", "Heading 2"),
        ("header3", "Heading 3"),
        ("header4", "Heading 4"),
        ("header5", "Heading 5"),
        ("header6", "Heading 6")
    ]

    private func processPickedPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var uploads: [SDocImageItem] = []
            for item in items {
                guard let originalData = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                var data = originalData
                var ext = type?.preferredFilenameExtension ?? "jpg"
                var mime = type?.preferredMIMEType ?? "image/jpeg"
                if settings.convertPhotosToJPEG,
                   mime.contains("heic") || mime.contains("heif") || ext == "heic" || ext == "heif",
                   let jpeg = ImageTranscoder.jpegDataPreservingMetadata(from: originalData) {
                    data = jpeg
                    ext = "jpg"
                    mime = "image/jpeg"
                }
                uploads.append(SDocImageItem(data: data,
                                             fileName: "IMG_\(UUID().uuidString).\(ext)",
                                             mimeType: mime))
            }
            photoItems = []
            guard !uploads.isEmpty else {
                model.toast = String(localized: "Failed to read image")
                return
            }
            await model.insertImages(uploads,
                                     allowUntrusted: session.account.allowUntrustedCertificate)
        }
    }

    private func processImageURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            let uploads = await Task.detached(priority: .userInitiated) { () -> [SDocImageItem] in
                var result: [SDocImageItem] = []
                for url in urls {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    guard let data = try? Data(contentsOf: url) else { continue }
                    let type = UTType(filenameExtension: url.pathExtension.lowercased())
                    result.append(SDocImageItem(data: data,
                                                fileName: url.lastPathComponent,
                                                mimeType: type?.preferredMIMEType ?? "image/jpeg"))
                }
                return result
            }.value
            guard !uploads.isEmpty else {
                model.toast = String(localized: "Failed to read image")
                return
            }
            await model.insertImages(uploads,
                                     allowUntrusted: session.account.allowUntrustedCertificate)
        }
    }

    private func openPendingImageSource() {
        guard let source = pendingInsertSource else { return }
        pendingInsertSource = nil
        switch source {
        case .camera: showCamera = true
        case .library: showPhotoPicker = true
        case .files: showImageImporter = true
        }
    }

    @MainActor
    private func openOutline() async {
        guard !isLoadingMetadata else { return }
        isLoadingMetadata = true
        defer { isLoadingMetadata = false }
        let items = await model.loadOutlines()
        guard !items.isEmpty else {
            model.toast = String(localized: "No data")
            return
        }
        outlineItems = items
        showOutline = true
    }

    @MainActor
    private func openComments() async {
        guard !isLoadingMetadata else { return }
        isLoadingMetadata = true
        defer { isLoadingMetadata = false }
        guard let options = await model.loadPageOptions() else {
            model.toast = String(localized: "Not supported feature")
            return
        }
        commentsPageOptions = options
    }
}

private struct SDocWebView: UIViewRepresentable {
    let baseURL: URL
    let repoID: String
    let path: String
    let token: String?
    let allowUntrusted: Bool
    let canEdit: Bool
    let model: SDocWebModel

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(source: Self.bridgeShim,
                                                         injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: true))
        userContentController.addUserScript(WKUserScript(source: Self.bridgeHelper,
                                                         injectionTime: .atDocumentStart,
                                                         forMainFrameOnly: true))
        let weakHandler = WeakScriptMessageHandler(target: context.coordinator)
        userContentController.add(weakHandler, name: "callAndroidFunction")
        context.coordinator.messageHandler = weakHandler

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.websiteDataStore = .nonPersistent()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        model.webView = webView
        context.coordinator.observe(webView)
        webView.evaluateJavaScript("navigator.userAgent") { result, _ in
            let base = (result as? String) ?? ""
            let suffix = " Seafile iOS/4.0.7"
            webView.customUserAgent = base.contains("Seafile iOS/") ? base : base + suffix
            context.coordinator.loadInitialPage()
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        model.webView = uiView
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "callAndroidFunction")
        coordinator.stop()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let parent: SDocWebView
        var messageHandler: WeakScriptMessageHandler?
        private weak var webView: WKWebView?
        private var observation: NSKeyValueObservation?
        private let serverHost: String?
        private var loginRetryCount = 0

        init(parent: SDocWebView) {
            self.parent = parent
            serverHost = URLComponents(url: parent.baseURL, resolvingAgainstBaseURL: false)?.host
        }

        func observe(_ webView: WKWebView) {
            self.webView = webView
            observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.model.progress = webView.estimatedProgress
                }
            }
        }

        func stop() {
            observation?.invalidate()
            observation = nil
        }

        func loadInitialPage() {
            guard let url = SeafileWebURL.file(baseURL: parent.baseURL, repoID: parent.repoID, path: parent.path) else {
                return
            }
            loadViaMobileLogin(url)
        }

        private func loadViaMobileLogin(_ next: URL) {
            guard let webView else { return }
            guard let token = parent.token, !token.isEmpty,
                  var components = URLComponents(url: parent.baseURL, resolvingAgainstBaseURL: false) else {
                webView.load(URLRequest(url: next))
                return
            }
            var basePath = components.path
            while basePath.hasSuffix("/") { basePath.removeLast() }
            components.path = basePath + "/mobile-login/"
            components.queryItems = [URLQueryItem(name: "next", value: next.absoluteString)]
            guard let loginURL = components.url else {
                webView.load(URLRequest(url: next))
                return
            }
            var request = URLRequest(url: loginURL)
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            webView.load(request)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.model.pageDidFinish()
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
                loadInitialPage()
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
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

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "callAndroidFunction",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            let action = object["action"] as? String
            let callbackId = object["__cbId"]

            if action == "N_N_N_N_Callback" { return }

            switch action {
            case "app.version.get":
                respond(callbackId, value: "4.0.7-1")
            case "page.status.height.get":
                respond(callbackId, value: "\(UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.statusBarManager?.statusBarFrame.height }.max() ?? 20)")
            case "app.toast.show":
                if let text = object["data"] as? String {
                    parent.model.toast = text
                }
            case "page.finish":
                parent.model.pageDidFinish()
                if parent.canEdit {
                    parent.model.enterEditOnLoad()
                }
            case "sdoc.editor.content.select":
                parent.model.updateSelection(object["data"])
            case "sdoc.editor.operation.execute":
                Task { await parent.model.refreshHistory() }
            case "sdoc.editor.system.event":
                handleSystemEvent(object["data"])
            default:
                if callbackId != nil {
                    respond(callbackId, value: "")
                }
            }
        }

        private func handleSystemEvent(_ payload: Any?) {
            var object = payload
            if let text = payload as? String,
               let data = text.data(using: .utf8) {
                object = try? JSONSerialization.jsonObject(with: data)
            }
            guard let dict = object as? [String: Any],
                  let type = dict["type"] as? String else { return }
            switch type {
            case "token_expired_Please_refresh_the_page",
                 "internal_server_exec_operations_error",
                 "failed_to_sync_with_server_operations",
                 "failed_to_execute_operation_on_server":
                parent.model.toast = String(localized: "Server error, please refresh")
            default:
                break
            }
        }

        private func respond(_ callbackId: Any?, value: String) {
            guard let webView, let callbackId,
                  let valueData = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                  let valueLiteral = String(data: valueData, encoding: .utf8),
                  let idLiteral = String(data: (try? JSONSerialization.data(withJSONObject: "\(callbackId)", options: [.fragmentsAllowed])) ?? Data(), encoding: .utf8) else { return }
            let script = "try{WebViewJavascriptBridge._handleResponse(\(idLiteral), \(valueLiteral));}catch(e){}"
            webView.evaluateJavaScript(script)
        }
    }

    private static let bridgeShim = """
    (function(){
      var w=window;
      if(!w.WebViewJavascriptBridge){
        var _handlers={};
        var _callbacks={};
        var _cbId=0;
        w.WebViewJavascriptBridge={
          registerHandler:function(name,handler){try{_handlers[name]=handler;}catch(e){}},
          callHandler:function(name,data,resp){
            try{
              if(w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers[name]){
                var payload=(typeof data==='string')?data:JSON.stringify(data||{});
                var registered=false;
                if(typeof resp==='function'){
                  var obj=null; try{obj=JSON.parse(payload);}catch(e){}
                  if(obj && typeof obj==='object'){_cbId++;_callbacks[_cbId]=resp;obj.__cbId=_cbId;payload=JSON.stringify(obj);registered=true;}
                }
                w.webkit.messageHandlers[name].postMessage(payload);
                if(typeof resp==='function' && !registered){resp('');}
              }
            }catch(e){}
          },
          _handleResponse:function(id,data){try{var cb=_callbacks[id];delete _callbacks[id];if(typeof cb==='function'){cb(data);}}catch(e){}},
          _invoke:function(name,data){
            try{
              var h=_handlers[name];
              if(typeof h==='function'){
                h(data,function(res){
                  try{ w.webkit.messageHandlers.callAndroidFunction.postMessage(JSON.stringify({action:'N_N_N_N_Callback',data:res||''})); }catch(e){}
                });
              }
            }catch(e){}
          }
        };
      }
    })();
    """

    private static let bridgeHelper = """
    window.callAndroidFunction = window.callAndroidFunction || function(payload){
      if(window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.callAndroidFunction){
        window.webkit.messageHandlers.callAndroidFunction.postMessage(payload);
      }
    };
    """
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

private enum SDocInsertImageSource {
    case camera
    case library
    case files
}

private struct SDocInsertImageSheet: View {
    let canTakePhoto: Bool
    let onSelect: (SDocInsertImageSource) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Insert Image")
                .font(.headline)
                .padding(.top, 24)
                .padding(.bottom, 12)

            if canTakePhoto {
                sourceRow("Take Photo", icon: "camera", source: .camera)
                Divider().padding(.leading, 52)
            }
            sourceRow("Photo Library", icon: "photo.on.rectangle", source: .library)
            Divider().padding(.leading, 52)
            sourceRow("From Files", icon: "folder", source: .files)

            Button("Cancel") {
                dismiss()
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .padding(.top, 4)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .presentationDetents([.height(canTakePhoto ? 296 : 244)])
        .presentationDragIndicator(.visible)
    }

    private func sourceRow(_ title: String, icon: String, source: SDocInsertImageSource) -> some View {
        Button {
            onSelect(source)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.seafileOrange)
                    .frame(width: 28)
                Text(LocalizedStringKey(title))
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SDocCameraPickerSheet: View {
    let onCapture: (SDocImageItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SDocCameraPicker(onCapture: { image in
            if let data = image.jpegData(compressionQuality: 0.92) {
                onCapture(SDocImageItem(data: data,
                                        fileName: "IMG_\(UUID().uuidString).jpg",
                                        mimeType: "image/jpeg"))
            }
            dismiss()
        }, onCancel: {
            dismiss()
        })
        .ignoresSafeArea()
    }
}

private struct SDocCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: SDocCameraPicker

        init(parent: SDocCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancel()
                return
            }
            parent.onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
