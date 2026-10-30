import AVKit
import PDFKit
import QuickLook
import SwiftUI
import UIKit

private struct TextEditorPayload: Identifiable {
    let id = UUID()
    let text: String
}

private enum OfficeFileAction: Equatable {
    case quickLook
    case share
}

struct PreviewScreen: View {
    let target: PreviewTarget
    var onFileChanged: (() -> Void)? = nil

    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var localURL: URL?
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var shareItem: ShareItem?
    @State private var quickLookURL: URL?
    @State private var webRequest: WebScreenRequest?
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var textEditorPayload: TextEditorPayload?
    @State private var textReloadID = UUID()
    @State private var officePendingAction: OfficeFileAction?
    @State private var showFileInfo = false

    @State private var unlockPassword = ""
    @State private var rememberRepoPassword = true
    @State private var isUnlocking = false
    @State private var unlockError: String?

    private var kind: FileKind { FileKind.of(name: target.name) }
    private var isSdoc: Bool { target.name.lowercased().hasSuffix(".sdoc") }
    private var isExdraw: Bool { target.name.lowercased().hasSuffix(".exdraw") }

    private var progress: TransferProgress? {
        session.transfers.downloadProgress(repoID: target.repo.id, path: target.path)
    }

    private var usesQuickLook: Bool {
        guard !isSdoc else { return false }
        switch kind {
        case .officeDocument, .archive, .other: return true
        default: return false
        }
    }

    private var needsOfficeMenu: Bool {
        (kind == .officeDocument && !isSdoc) || isExdraw
    }

    private var needsUnlock: Bool {
        target.repo.encrypted && !session.isRepoUnlocked(target.repo.id)
    }

    private var keepsChromeVisible: Bool {
        needsUnlock || needsOfficeMenu || kind == .video || kind == .audio || localURL == nil
    }

    private var canOpenOnlineOffice: Bool {
        guard !target.repo.encrypted else { return false }
        if isExdraw { return true }
        return isSdoc || (kind == .officeDocument && session.onlineOfficeAvailable)
    }

    private var canEditText: Bool {
        kind == .text && !target.repo.isReadOnly && localURL != nil && !needsUnlock
    }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            if needsUnlock {
                encryptedUnlockView
            } else if needsOfficeMenu {
                officeMenuView
            } else if let localURL {
                if usesQuickLook || isSdoc {
                    quickLookPlaceholder
                } else {
                    previewContent(url: localURL)
                }
            } else if let errorMessage {
                errorView(errorMessage)
            } else {
                loadingView
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if chromeVisible {
                bottomChrome
                    .padding(.horizontal, 16)
                    .padding(.bottom, kind == .video ? 58 : 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                hiddenChromeGrabber
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: chromeVisible)
        .task {
            if isSdoc && canOpenOnlineOffice {
                openOnlineOffice()
            } else if !needsUnlock && !needsOfficeMenu {
                await load()
            }
        }
        .onAppear {
            rememberRepoPassword = settings.rememberRepoPasswords
            if keepsChromeVisible {
                showChrome(autoHide: false)
            } else {
                scheduleHide()
            }
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        }
        .onDisappear {
            hideTask?.cancel()
        }
        .onChange(of: quickLookURL) { _, newValue in
            if newValue == nil {
                showChrome(autoHide: false)
            }
        }
        .quickLookPreview($quickLookURL)
        .fullScreenCover(item: $webRequest, onDismiss: {
            if isSdoc { dismiss() }
        }) { request in
            if request.isSDoc, let repoID = request.repoID, let path = request.path {
                SDocWebScreen(title: request.title,
                              repoID: repoID,
                              path: path,
                              canEdit: !target.repo.isReadOnly)
            } else {
                SeafileWebScreen(title: request.title,
                                 initialURL: request.url,
                                 useDesktopUserAgent: request.useDesktopUserAgent)
            }
        }
        .fullScreenCover(item: $textEditorPayload) { payload in
            TextFileEditorView(title: target.name, initialText: payload.text) { text in
                try await saveText(text)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showFileInfo) {
            FileInfoSheet(target: target)
        }
        .seafileToast($toast)
    }

    // MARK: - Chrome

    private var bottomChrome: some View {
        HStack(spacing: 8) {
            Button {
                dismissPreview()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            VStack(alignment: .leading, spacing: 1) {
                Text(target.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Button {
                showFileInfo = true
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("File Info")

            if canEditText {
                Button {
                    openTextEditor()
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit")
            }

            if canOpenOnlineOffice && !needsOfficeMenu {
                Menu {
                    Button {
                        openOnlineOffice()
                    } label: {
                        Label(LocalizedStringKey(isSdoc ? "Open in SeaDoc" : "Open in Online Office"), systemImage: "globe")
                    }
                    if let localURL, usesQuickLook {
                        Button {
                            quickLookURL = localURL
                        } label: {
                            Label("Open with Quick Look", systemImage: "doc.viewfinder")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More actions")
            }

            if let localURL, !needsOfficeMenu {
                Button {
                    shareItem = ShareItem(url: localURL)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Share")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                .blendMode(.plusLighter)
        }
    }

    private var hiddenChromeGrabber: some View {
        Button {
            showChrome()
        } label: {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.5))
                .frame(width: 42, height: 5)
                .frame(width: 72, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .accessibilityLabel("Show controls")
    }

    private var subtitle: String {
        var parts: [String] = [target.repo.name]
        if target.size > 0 { parts.append(DisplayFormat.fileSize(target.size)) }
        if let modified = target.modified { parts.append(DisplayFormat.date(modified)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 16) {
            FileIconTile(kind: kind, size: 72)
            Text(target.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let progress, progress.totalBytes > 0 {
                VStack(spacing: 6) {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .tint(.seafileOrange)
                        .frame(width: 220)
                    Text("\(Int(progress.fraction * 100))%  ·  \(DisplayFormat.fileSize(progress.completedBytes)) / \(DisplayFormat.fileSize(progress.totalBytes))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView()
                    .tint(.seafileOrange)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .glassCard(cornerRadius: 28, padding: 0)
        .padding(.horizontal, 40)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text("Could not open file")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                Task { await load(force: true) }
            }
            .buttonStyle(GlassProminentButtonStyle())
        }
        .padding(26)
        .glassCard(cornerRadius: 28, padding: 0)
        .padding(.horizontal, 40)
    }

    private var encryptedUnlockView: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.seafileOrange)
            Text("Encrypted Library")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Enter the password to unlock this library. It is used only on this device and is never sent to the server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("Password", text: $unlockPassword)
                .textContentType(.password)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .submitLabel(.go)
                .onSubmit { unlock() }

            Toggle("Remember on this device", isOn: $rememberRepoPassword)
                .font(.caption)
                .tint(.seafileOrange)
                .foregroundStyle(.secondary)
                .disabled(!settings.rememberRepoPasswords)

            Text("If not saved, this library locks after 30 minutes of inactivity.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            if let unlockError {
                Text(unlockError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                unlock()
            } label: {
                HStack(spacing: 8) {
                    if isUnlocking { ProgressView().tint(.white) }
                    Text(isUnlocking ? "Unlocking…" : "Unlock")
                }
            }
            .buttonStyle(GlassProminentButtonStyle())
            .disabled(unlockPassword.isEmpty || isUnlocking)
            .opacity(unlockPassword.isEmpty ? 0.6 : 1)
        }
        .padding(26)
        .glassCard(cornerRadius: 28, padding: 0)
        .padding(.horizontal, 40)
    }

    private var officeMenuView: some View {
        VStack(spacing: 22) {
            FileIconTile(kind: kind, size: 76)

            VStack(spacing: 4) {
                Text(target.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(spacing: 0) {
                if canOpenOnlineOffice {
                    officeMenuRow(title: isExdraw ? "Open Online" : "Open in Online Office",
                                  subtitle: isExdraw
                                      ? "View this drawing in your browser"
                                      : "Edit this file in your browser",
                                  icon: "globe",
                                  prominent: true) {
                        openOnlineOffice()
                    }
                    Divider().padding(.leading, 64)
                }

                if !isExdraw {
                    officeMenuRow(title: "Open with Quick Look",
                                  subtitle: nil,
                                  icon: "doc.viewfinder",
                                  prominent: false,
                                  loading: officePendingAction == .quickLook) {
                        prepareOfficeFile(.quickLook)
                    }

                    Divider().padding(.leading, 64)
                }

                officeMenuRow(title: "Share",
                              subtitle: nil,
                              icon: "square.and.arrow.up",
                              prominent: false,
                              loading: officePendingAction == .share) {
                    prepareOfficeFile(.share)
                }
            }
            .glassCard(cornerRadius: 24, padding: 0)
            .frame(maxWidth: 460)
            .disabled(officePendingAction != nil)

            if !canOpenOnlineOffice {
                Text(target.repo.encrypted
                     ? "Online preview is unavailable for encrypted libraries."
                     : "Online preview is not available on this server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .padding(24)
    }

    private func officeMenuRow(title: String,
                               subtitle: String?,
                               icon: String,
                               prominent: Bool,
                               loading: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : Color.seafileOrange)
                    .frame(width: 38, height: 38)
                    .background(prominent ? Color.seafileOrange : Color.seafileOrange.opacity(0.12),
                                in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(title))
                        .font(.body.weight(prominent ? .semibold : .regular))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if loading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func prepareOfficeFile(_ action: OfficeFileAction) {
        guard officePendingAction == nil else { return }
        officePendingAction = action
        Task {
            defer { officePendingAction = nil }
            if target.repo.encrypted {
                let unlocked = await session.ensureRepoUnlocked(target.repo.id)
                guard unlocked else {
                    toast = String(localized: "Please unlock the library first.")
                    return
                }
            }
            do {
                let url: URL
                if let localURL {
                    url = localURL
                } else {
                    url = try await session.transfers.download(repoID: target.repo.id,
                                                               path: target.path,
                                                               name: target.name,
                                                               version: target.version)
                    localURL = url
                }
                switch action {
                case .quickLook:
                    quickLookURL = url
                case .share:
                    shareItem = ShareItem(url: url)
                }
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private var quickLookPlaceholder: some View {
        VStack(spacing: 16) {
            FileIconTile(kind: kind, size: 72)
            Text(target.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let localURL, usesQuickLook {
                Button {
                    quickLookURL = localURL
                } label: {
                    Label("Open with Quick Look", systemImage: "doc.viewfinder")
                }
                .buttonStyle(GlassProminentButtonStyle())
                .padding(.horizontal, 40)
            }
            if canOpenOnlineOffice {
                Button {
                    openOnlineOffice()
                } label: {
                    Label(LocalizedStringKey(isSdoc ? "Open in SeaDoc" : (isExdraw ? "Open Online" : "Open in Online Office")),
                          systemImage: "globe")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.horizontal, 40)
            }
        }
        .padding(24)
    }

    @ViewBuilder
    private func previewContent(url: URL) -> some View {
        switch kind {
        case .image:
            if let image = UIImage(contentsOfFile: url.path) {
                ZoomableImageView(image: image,
                                  onTap: toggleChrome,
                                  onInteraction: hideChrome)
            } else {
                quickLookPlaceholder
            }
        case .video:
            VideoPreviewView(url: url)
        case .pdf:
            PDFPreviewView(url: url,
                           onTap: toggleChrome,
                           onScroll: hideChrome)
        case .audio:
            AudioPreviewView(url: url, name: target.name)
        case .text:
            TextPreviewView(url: url,
                            onTap: toggleChrome,
                            onScroll: hideChrome)
                .id(textReloadID)
        case .officeDocument, .archive, .other:
            quickLookPlaceholder
        case .folder:
            quickLookPlaceholder
        }
    }

    // MARK: - Actions

    private func load(force: Bool = false) async {
        if target.repo.encrypted {
            let unlocked = await session.ensureRepoUnlocked(target.repo.id)
            guard unlocked else { return }
        }
        guard force || localURL == nil else { return }
        errorMessage = nil
        localURL = nil
        do {
            let url = try await session.transfers.download(repoID: target.repo.id,
                                                           path: target.path,
                                                           name: target.name,
                                                           version: target.version)
            localURL = url
            if usesQuickLook && !needsOfficeMenu {
                try? await Task.sleep(nanoseconds: 200_000_000)
                quickLookURL = url
            } else if !keepsChromeVisible {
                scheduleHide()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openOnlineOffice() {
        if let url = SeafileWebURL.file(baseURL: session.account.serverURL,
                                       repoID: target.repo.id,
                                       path: target.path) {
            webRequest = WebScreenRequest(title: target.name,
                                          url: url,
                                          isSDoc: isSdoc,
                                          repoID: target.repo.id,
                                          path: target.path,
                                          useDesktopUserAgent: !isSdoc && !isExdraw)
        } else {
            toast = String(localized: "Could not build the web address.")
        }
    }

    private func openTextEditor() {
        guard let localURL else { return }
        if target.size > 10 * 1024 * 1024 {
            toast = String(format: String(localized: "File “%@” is too large to edit."), target.name)
            return
        }
        guard let text = Self.readTextFile(localURL, limit: 10 * 1024 * 1024) else {
            toast = String(format: String(localized: "Failed to identify the encoding of “%@”."), target.name)
            return
        }
        textEditorPayload = TextEditorPayload(text: text)
    }

    private func saveText(_ text: String) async throws {
        guard let localURL else { throw APIError.invalidResponse }
        if target.repo.encrypted {
            let unlocked = await session.ensureRepoUnlocked(target.repo.id)
            guard unlocked else { throw APIError.repoPasswordRequired }
        }
        let data = Data(text.utf8)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-edit-\(UUID().uuidString)")
            .appendingPathComponent(FileNames.sanitized(target.name))
        try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
        try data.write(to: tempURL, options: .atomic)

        let parent = (target.path as NSString).deletingLastPathComponent
        let dirPath = parent.isEmpty ? "/" : parent
        try await session.transfers.upload(fileURL: tempURL,
                                           fileName: target.name,
                                           repoID: target.repo.id,
                                           dirPath: dirPath,
                                           replace: true)
        try data.write(to: localURL, options: .atomic)
        textReloadID = UUID()
        onFileChanged?()
        toast = String(localized: "Saved.")
    }

    private static func readTextFile(_ url: URL, limit: Int) -> String? {
        TextFileDecoder.read(url: url, limit: limit)
    }

    private func unlock() {
        let password = unlockPassword
        guard !password.isEmpty, !isUnlocking else { return }
        unlockError = nil
        isUnlocking = true
        Task {
            do {
                try await session.unlockRepo(target.repo.id,
                                             password: password,
                                             remember: rememberRepoPassword)
                unlockPassword = ""
                await load()
            } catch {
                if let apiError = error as? APIError,
                   case let .http(_, message) = apiError,
                   let message,
                   message.lowercased().contains("incorrect") {
                    unlockError = String(localized: "Incorrect password. Try again.")
                } else {
                    unlockError = error.localizedDescription
                }
            }
            isUnlocking = false
        }
    }

    private func dismissPreview() {
        hideTask?.cancel()
        dismiss()
    }

    private func showChrome(autoHide: Bool = true) {
        hideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) { chromeVisible = true }
        if autoHide { scheduleHide() }
    }

    private func hideChrome() {
        guard !keepsChromeVisible else { return }
        hideTask?.cancel()
        withAnimation(.smooth(duration: 0.25)) { chromeVisible = false }
    }

    private func toggleChrome() {
        if chromeVisible {
            hideChrome()
        } else {
            showChrome()
        }
    }

    private func scheduleHide(delay: TimeInterval = 3.5) {
        guard !keepsChromeVisible else { return }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if !Task.isCancelled {
                withAnimation(.smooth(duration: 0.25)) { chromeVisible = false }
            }
        }
    }
}

// MARK: - Preview content

private struct VideoPreviewView: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player.play() }
            .onDisappear { player.pause() }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    let onInteraction: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap))
        singleTap.cancelsTouchesInView = false
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onInteraction: onInteraction)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private let onTap: () -> Void
        private let onInteraction: () -> Void

        init(onTap: @escaping () -> Void, onInteraction: @escaping () -> Void) {
            self.onTap = onTap
            self.onInteraction = onInteraction
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onInteraction()
        }

        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
            onInteraction()
        }

        @objc func handleSingleTap() {
            onTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let point = gesture.location(in: imageView)
            let size = scrollView.bounds.size
            let width = size.width / 2.5
            let height = size.height / 2.5
            let rect = CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

private struct PDFPreviewView: UIViewRepresentable {
    let url: URL
    let onTap: () -> Void
    let onScroll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onScroll: onScroll)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = .clear
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.document = PDFDocument(url: url)

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onTap: () -> Void
        private let onScroll: () -> Void

        init(onTap: @escaping () -> Void, onScroll: @escaping () -> Void) {
            self.onTap = onTap
            self.onScroll = onScroll
        }

        @objc func handleTap() {
            onTap()
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                onScroll()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

private struct TextPreviewView: View {
    let url: URL
    let onTap: () -> Void
    let onScroll: () -> Void

    @State private var text: String?
    @State private var failed = false

    private var isMarkdown: Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private var isPython: Bool {
        ["py", "pyw", "pyi"].contains(url.pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if let text {
                ScrollView {
                    Group {
                        if isPython {
                            Text(PythonHighlighter.attributedString(text))
                        } else {
                            Group {
                                if isMarkdown, let attributed = try? AttributedString(markdown: text) {
                                    Text(attributed)
                                } else {
                                    Text(text)
                                        .font(.system(.body, design: .monospaced))
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
                .onScrollPhaseChange { _, newPhase in
                    if newPhase.isScrolling { onScroll() }
                }
                .simultaneousGesture(TapGesture().onEnded { onTap() })
                .scrollIndicators(.hidden)
            } else if failed {
                Text("Unable to read this text file.")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().tint(.seafileOrange)
            }
        }
        .task {
            text = Self.read(url: url)
            failed = text == nil
        }
    }

    private static func read(url: URL) -> String? {
        TextFileDecoder.read(url: url, limit: 4_000_000)
    }
}

private struct AudioPreviewView: View {
    let url: URL
    let name: String

    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var observer: Any?

    var body: some View {
        VStack(spacing: 26) {
            FileIconTile(kind: .audio, size: 96)
            Text(name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Slider(value: Binding(get: { currentTime },
                                      set: { value in
                                          currentTime = value
                                          player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                                      }),
                       in: 0...max(duration, 0.1))
                    .tint(.seafileOrange)
                HStack {
                    Text(timeText(currentTime))
                    Spacer()
                    Text(timeText(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Button {
                if isPlaying {
                    player.pause()
                } else {
                    player.play()
                }
                isPlaying.toggle()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(Color.seafileOrange.opacity(0.4)).interactive(), in: .circle)
        }
        .padding(28)
        .glassCard(cornerRadius: 32, padding: 0)
        .padding(.horizontal, 32)
        .task {
            let item = AVPlayerItem(url: url)
            player.replaceCurrentItem(with: item)
            if let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite {
                duration = seconds
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                      queue: .main) { time in
                currentTime = time.seconds
            }
        }
        .onDisappear {
            if let observer {
                player.removeTimeObserver(observer)
                self.observer = nil
            }
            player.pause()
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
