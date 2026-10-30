import MessageUI
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private enum BatchExportAction {
    case share
    case saveToPhotos
}

private struct BatchShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct FolderView: View {
    let repo: Repository
    let path: String

    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings

    @State private var items: [Dirent] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?

    @State private var previewTarget: PreviewTarget?
    @State private var galleryRequest: PhotoGalleryRequest?
    @State private var shareItem: ShareItem?
    @Namespace private var photoZoom
    @State private var webRequest: WebScreenRequest?

    @State private var unlockPassword = ""
    @State private var rememberRepoPassword = true
    @State private var isUnlocking = false
    @State private var unlockError: String?
    @State private var isCheckingEncrypted = false

    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showNewFile = false
    @State private var newFileName = ""

    @State private var renameTarget: Dirent?
    @State private var renameText = ""
    @State private var showRename = false

    @State private var deleteTarget: Dirent?
    @State private var showDelete = false

    @State private var showFileImporter = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var pendingUploadURLs: [URL] = []
    @State private var uploadConflictNames: [String] = []
    @State private var showUploadConflict = false
    @State private var showSearch = false
    @State private var batchShareItem: BatchShareItem?
    @State private var isPreparingBatch = false
    @State private var mailRequest: MailRequest?
    @State private var profileTarget: Dirent?

    @State private var isSelecting = false
    @State private var selectedPaths: Set<String> = []
    @State private var pendingOperation: BatchFileOperation?
    @State private var showDestinationPicker = false
    @State private var showDeleteSelectionConfirm = false

    private var sortedItems: [Dirent] {
        items.sorted(by: settings.sortKey, ascending: settings.sortAscending)
    }

    private var canEdit: Bool { !repo.isReadOnly }
    private var selectedItems: [Dirent] {
        items.filter { selectedPaths.contains($0.path) }
    }
    private var allSelected: Bool {
        !sortedItems.isEmpty && sortedItems.allSatisfy { selectedPaths.contains($0.path) }
    }
    private var canSaveSelectionToPhotos: Bool {
        selectedItems.contains {
            guard !$0.isDirectory else { return false }
            let kind = FileKind.of(name: $0.name)
            return kind == .image || kind == .video
        }
    }
    private var allSelectionStarred: Bool {
        !selectedItems.isEmpty && selectedItems.allSatisfy {
            session.isStarred(repoID: repo.id, path: $0.path)
        }
    }
    private var displayTitle: String { path == "/" ? repo.name : (path as NSString).lastPathComponent }
    private var displayPath: String { path == "/" ? repo.name : path }
    private var uploadConflictMessage: String {
        String(format: String(localized: "These files already exist in %@: %@"),
               displayPath,
               uploadConflictNames.joined(separator: ", "))
    }

    var body: some View {
        withPresentations(withInteractionHandlers(folderScaffold))
    }

    private var folderScaffold: some View {
        ZStack {
            SeafileBackground()
            ScrollView {
                LazyVStack(spacing: 16) {
                    if repo.encrypted && !session.isRepoUnlocked(repo.id) {
                        if isCheckingEncrypted {
                            LoadingCard(message: "Checking encrypted library…")
                                .padding(.top, 12)
                        } else {
                            encryptedUnlockCard
                        }
                    } else {
                        content
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .refreshable {
                await load(force: true)
            }
        }
        .navigationTitle(isSelecting ? String(localized: "\(selectedItems.count) selected") : displayTitle)
        .navigationBarTitleDisplayMode(path == "/" ? .large : .inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                OfflineDownloadBanner()
                if isSelecting {
                    selectionBar
                } else {
                    uploadBanner
                }
            }
        }
        .animation(.smooth, value: session.transfers.activeUploads.map(\.id))
        .animation(.smooth, value: isSelecting)
    }

    private func withInteractionHandlers<V: View>(_ view: V) -> some View {
        view
        .task {
            session.currentFolder = FolderLocation(repoID: repo.id, repoName: repo.name, path: path)
            rememberRepoPassword = settings.rememberRepoPasswords
            if repo.encrypted {
                isCheckingEncrypted = true
                let unlocked = await session.ensureRepoUnlocked(repo.id)
                isCheckingEncrypted = false
                if unlocked { await load() }
            } else if items.isEmpty {
                await load()
            }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                uploadFiles(urls)
            } else if case let .failure(error) = result {
                toast = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $showPhotoPicker,
                      selection: $photoItems,
                      maxSelectionCount: nil,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, newValue in
            uploadPhotos(newValue)
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        } message: {
            Text("Create a folder in \(displayPath).")
        }
        .alert("New File", isPresented: $showNewFile) {
            TextField("File name", text: $newFileName)
            Button("Create") { createFile() }
            Button("Cancel", role: .cancel) { newFileName = "" }
        } message: {
            Text("Create a file in \(displayPath).")
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("New name", text: $renameText)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a new name for “\(renameTarget?.name ?? "")”.")
        }
        .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?",
                            isPresented: $showDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { performDelete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .confirmationDialog("Replace existing files?",
                            isPresented: $showUploadConflict,
                            titleVisibility: .visible) {
            Button("Replace", role: .destructive) {
                let urls = pendingUploadURLs
                pendingUploadURLs = []
                uploadConflictNames = []
                Task { await performUploads(urls, replace: true) }
            }
            Button("Cancel", role: .cancel) {
                pendingUploadURLs = []
                uploadConflictNames = []
            }
        } message: {
            Text(uploadConflictMessage)
        }
    }

    private func withPresentations<V: View>(_ view: V) -> some View {
        view
        .fullScreenCover(item: $previewTarget) { target in
            PreviewScreen(target: target) {
                Task { await load(force: true) }
            }
        }
        .fullScreenCover(item: $galleryRequest) { request in
            PhotoGalleryScreen(request: request)
                .navigationTransition(.zoom(sourceID: request.targets[request.startIndex].path,
                                             in: photoZoom))
        }
        .fullScreenCover(item: $webRequest) { request in
            if request.isSDoc, let repoID = request.repoID, let path = request.path {
                SDocWebScreen(title: request.title,
                              repoID: repoID,
                              path: path,
                              canEdit: !repo.isReadOnly)
            } else {
                SeafileWebScreen(title: request.title,
                                 initialURL: request.url,
                                 useDesktopUserAgent: request.useDesktopUserAgent)
            }
        }
        .fullScreenCover(isPresented: $showDestinationPicker, onDismiss: { pendingOperation = nil }) {
            DestinationPickerView(operation: pendingOperation ?? .copy,
                                  sourceRepoID: repo.id,
                                  sourcePath: path) { destinationRepo, destinationPath in
                applyOperation(to: destinationRepo, path: destinationPath)
            }
        }
        .fullScreenCover(isPresented: $showDeleteSelectionConfirm) {
            FullScreenConfirmationView(
                icon: "trash",
                title: String(format: String(localized: "Delete %lld items?"), selectedItems.count),
                message: String(localized: "This action cannot be undone."),
                confirmTitle: String(localized: "Delete")
            ) {
                deleteSelectedItems()
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureSheet { image in
                uploadCapturedImage(image)
            }
        }
        .sheet(isPresented: $showSearch) {
            SearchView(repoID: repo.id, repoName: repo.name)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(item: $batchShareItem) { item in
            ShareSheet(items: item.urls)
        }
        .sheet(item: $mailRequest) { request in
            MailComposeView(request: request) {
                mailRequest = nil
            }
        }
        .sheet(item: $profileTarget) { dirent in
            SDocPropertiesSheet(repoID: repo.id, path: dirent.path, api: session.api)
        }
        .seafileToast($toast)
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            if isPreparingBatch {
                ProgressView()
                    .controlSize(.small)
                    .tint(.seafileOrange)
            }
            Text(String(localized: "\(selectedItems.count) selected"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                beginOperation(.copy)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(selectedItems.isEmpty)
            .accessibilityLabel("Copy")

            if canEdit {
                Button {
                    beginOperation(.move)
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(selectedItems.isEmpty)
                .accessibilityLabel("Move")

                Button {
                    showDeleteSelectionConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(selectedItems.isEmpty)
                .accessibilityLabel("Delete")
            }

            Menu {
                Button {
                    exportSelection(.share)
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                if canSaveSelectionToPhotos {
                    Button {
                        exportSelection(.saveToPhotos)
                    } label: {
                        Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                    }
                }
                Button {
                    starSelection()
                } label: {
                    Label(allSelectionStarred ? "Remove Star" : "Star",
                          systemImage: allSelectionStarred ? "star.slash" : "star")
                }
                Button {
                    downloadSelection()
                } label: {
                    Label("Download for Offline", systemImage: "arrow.down.circle")
                }
                .disabled(session.offlineDownloads.isDownloading)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(selectedItems.isEmpty || isPreparingBatch)
            .accessibilityLabel("Export")
        }
        .disabled(isPreparingBatch)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && items.isEmpty {
            LoadingCard(message: "Loading folder…")
                .padding(.top, 8)
        } else if let errorMessage, items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await load(force: true) }
                }
                .buttonStyle(GlassProminentButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 24, padding: 22)
        } else if items.isEmpty {
            EmptyStateCard(icon: "folder",
                           title: "This folder is empty",
                           message: canEdit
                           ? "Upload files or create a folder to get started."
                           : "There is nothing in this folder.",
                           actionTitle: canEdit ? "Upload Files" : nil,
                           action: canEdit ? { showFileImporter = true } : nil)
        } else {
            SectionHeader(title: String(localized: "\(items.count) items"), subtitle: displayPath)
            if settings.useGrid {
                grid
            } else {
                list
            }
        }
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(sortedItems) { dirent in
                row(for: dirent)
                if dirent.id != sortedItems.last?.id {
                    Divider()
                        .padding(.leading, 70)
                        .opacity(0.5)
                }
            }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 148), spacing: 12)], spacing: 12) {
            ForEach(sortedItems) { dirent in
                if isSelecting {
                    Button {
                        toggleSelection(dirent)
                    } label: {
                        DirentGridCell(dirent: dirent, repo: repo)
                            .overlay(alignment: .topTrailing) {
                                selectionCircle(for: dirent)
                                    .padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                } else if dirent.isDirectory {
                    NavigationLink(value: FolderRoute(repo: repo, path: dirent.path)) {
                        DirentGridCell(dirent: dirent, repo: repo)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(for: dirent) }
                } else {
                    Button {
                        openFile(dirent)
                    } label: {
                        DirentGridCell(dirent: dirent, repo: repo)
                    }
                    .buttonStyle(.plain)
                    .matchedTransitionSource(id: dirent.path, in: photoZoom)
                    .contextMenu { contextMenu(for: dirent) }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for dirent: Dirent) -> some View {
        if isSelecting {
            Button {
                toggleSelection(dirent)
            } label: {
                HStack(spacing: 6) {
                    selectionCircle(for: dirent)
                        .frame(width: 26)
                    DirentRow(dirent: dirent, repo: repo)
                }
                .padding(.leading, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if dirent.isDirectory {
            NavigationLink(value: FolderRoute(repo: repo, path: dirent.path)) {
                DirentRow(dirent: dirent, repo: repo)
            }
            .buttonStyle(.plain)
            .contextMenu { contextMenu(for: dirent) }
        } else {
            Button {
                openFile(dirent)
            } label: {
                DirentRow(dirent: dirent, repo: repo)
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: dirent.path, in: photoZoom)
            .contextMenu { contextMenu(for: dirent) }
        }
    }

    private func selectionCircle(for dirent: Dirent) -> some View {
        let selected = selectedPaths.contains(dirent.path)
        return Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 21, weight: .semibold))
            .foregroundStyle(selected ? Color.seafileOrange : Color.secondary)
            .background(Color(.systemBackground).clipShape(Circle()))
    }

    private var encryptedUnlockCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.seafileOrange)
                .frame(width: 68, height: 68)
                .glassEffect(.regular.tint(Color.seafileOrange.opacity(0.12)), in: .circle)
            Text("Encrypted Library")
                .font(.headline)
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
                .font(.subheadline)
                .tint(.seafileOrange)
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
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 28, padding: 24)
        .padding(.top, 12)
    }

    @ViewBuilder
    private func contextMenu(for dirent: Dirent) -> some View {
        if !dirent.isDirectory {
            Button {
                openFile(dirent)
            } label: {
                Label("Open", systemImage: "eye")
            }
            if canOpenOnline(dirent) {
                Button {
                    openInOnlineOffice(dirent)
                } label: {
                    Label(LocalizedStringKey(dirent.name.lowercased().hasSuffix(".sdoc")
                                             ? "Open in SeaDoc"
                                             : (dirent.name.pathExtensionLowercased == "exdraw"
                                                ? "Open Online"
                                                : "Open in Online Office")),
                          systemImage: "globe")
                }
            }
            Button {
                downloadAndShare(dirent)
            } label: {
                Label("Save and Share…", systemImage: "square.and.arrow.down")
            }
            Button {
                profileTarget = dirent
            } label: {
                Label("Properties", systemImage: "list.bullet.rectangle")
            }
        } else {
            Button {
                downloadFolderForOffline(dirent.path, title: dirent.name)
            } label: {
                Label("Download for Offline", systemImage: "arrow.down.circle")
            }
        }
        Button {
            copyLink(dirent)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        Button {
            shareLinkByEmail(dirent)
        } label: {
            Label("Send Share Link via Email", systemImage: "envelope")
        }
        Button {
            toggleStar(dirent)
        } label: {
            let starred = session.isStarred(repoID: repo.id, path: dirent.path)
            Label(starred ? "Remove Star" : "Star", systemImage: starred ? "star.slash" : "star")
        }
        if canEdit {
            Button {
                renameTarget = dirent
                renameText = dirent.name
                showRename = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleteTarget = dirent
                showDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { endSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(LocalizedStringKey(allSelected ? "Deselect All" : "Select All")) {
                    toggleSelectAll()
                }
                .fontWeight(.medium)
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityLabel("Search this library")
            }

            if !items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        beginSelection()
                    } label: {
                        Image(systemName: "checklist")
                    }
                    .accessibilityLabel("Select")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: Binding(get: { settings.sortKey },
                                                         set: { settings.sortKey = $0 })) {
                        ForEach(DirentSortKey.allCases) { key in
                            Label(LocalizedStringKey(key.title), systemImage: key.symbol).tag(key)
                        }
                    }
                    Picker("Order", selection: Binding(get: { settings.sortAscending },
                                                       set: { settings.sortAscending = $0 })) {
                        Label("Ascending", systemImage: "arrow.up").tag(true)
                        Label("Descending", systemImage: "arrow.down").tag(false)
                    }
                    Divider()
                    Button {
                        settings.useGrid.toggle()
                    } label: {
                        Label(settings.useGrid ? "Show as List" : "Show as Grid",
                              systemImage: settings.useGrid ? "list.bullet" : "square.grid.2x2")
                    }
                    Divider()
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    Button {
                        downloadFolderForOffline(path, title: displayTitle)
                    } label: {
                        Label("Download for Offline", systemImage: "arrow.down.circle")
                    }
                    if repo.encrypted, session.isRepoUnlocked(repo.id) {
                        Divider()
                        Button(role: .destructive) {
                            lockLibrary()
                        } label: {
                            Label("Lock Library", systemImage: "lock.fill")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }

            if canEdit {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }
                        Button {
                            newFileName = ""
                            showNewFile = true
                        } label: {
                            Label("New File", systemImage: "doc.text")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Upload Files", systemImage: "doc.badge.plus")
                        }
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Upload Photos", systemImage: "photo.badge.plus")
                        }
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var uploadBanner: some View {
        let active = session.transfers.activeUploads
        if !active.isEmpty {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(active) { job in
                        UploadProgressCard(job: job)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Actions

    private func openFile(_ dirent: Dirent) {
        if !dirent.isDirectory,
           dirent.name.lowercased().hasSuffix(".sdoc"),
           canOpenOnline(dirent) {
            openInOnlineOffice(dirent)
            return
        }
        if !dirent.isDirectory, FileKind.of(name: dirent.name) == .image {
            let images = items.filter { !$0.isDirectory && FileKind.of(name: $0.name) == .image }
            if let index = images.firstIndex(where: { $0.path == dirent.path }), !images.isEmpty {
                galleryRequest = PhotoGalleryRequest(repo: repo,
                                                     targets: images.map { PreviewTarget(repo: repo, dirent: $0) },
                                                     startIndex: index)
                return
            }
        }
        previewTarget = PreviewTarget(repo: repo, dirent: dirent)
    }

    private func canOpenOnline(_ dirent: Dirent) -> Bool {
        guard !repo.encrypted, !dirent.isDirectory else { return false }
        if dirent.name.lowercased().hasSuffix(".sdoc") { return true }
        if dirent.name.pathExtensionLowercased == "exdraw" { return true }
        return FileKind.of(name: dirent.name) == .officeDocument && session.onlineOfficeAvailable
    }

    private func openInOnlineOffice(_ dirent: Dirent?) {
        guard let dirent else { return }
        guard let url = SeafileWebURL.file(baseURL: session.account.serverURL,
                                           repoID: repo.id,
                                           path: dirent.path) else {
            toast = String(localized: "Could not build the web address.")
            return
        }
        let isSDoc = dirent.name.lowercased().hasSuffix(".sdoc")
        let isExdraw = dirent.name.pathExtensionLowercased == "exdraw"
        webRequest = WebScreenRequest(title: dirent.name,
                                      url: url,
                                      isSDoc: isSDoc,
                                      repoID: repo.id,
                                      path: dirent.path,
                                      useDesktopUserAgent: !isSDoc && !isExdraw)
    }

    private func beginSelection() {
        isSelecting = true
        selectedPaths.removeAll()
    }

    private func endSelection() {
        isSelecting = false
        selectedPaths.removeAll()
        pendingOperation = nil
    }

    private func toggleSelection(_ dirent: Dirent) {
        if selectedPaths.contains(dirent.path) {
            selectedPaths.remove(dirent.path)
        } else {
            selectedPaths.insert(dirent.path)
        }
    }

    private func toggleSelectAll() {
        if allSelected {
            selectedPaths.removeAll()
        } else {
            selectedPaths = Set(sortedItems.map(\.path))
        }
    }

    private func beginOperation(_ operation: BatchFileOperation) {
        guard !selectedItems.isEmpty else { return }
        pendingOperation = operation
        showDestinationPicker = true
    }

    private func applyOperation(to destinationRepo: Repository, path destinationPath: String) {
        guard let operation = pendingOperation else { return }
        let names = selectedItems.map(\.name)
        guard !names.isEmpty else { return }
        guard !(destinationRepo.id == repo.id && destinationPath == path) else {
            toast = String(localized: "The destination is the current folder.")
            return
        }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                switch operation {
                case .copy:
                    try await session.api.copyEntries(repoID: repo.id,
                                                      dirPath: path,
                                                      names: names,
                                                      destinationRepoID: destinationRepo.id,
                                                      destinationPath: destinationPath)
                case .move:
                    try await session.api.moveEntries(repoID: repo.id,
                                                      dirPath: path,
                                                      names: names,
                                                      destinationRepoID: destinationRepo.id,
                                                      destinationPath: destinationPath)
                }
                endSelection()
                await load(force: true)
                toast = operation == .copy
                    ? String(format: String(localized: "Copied %lld items."), names.count)
                    : String(format: String(localized: "Moved %lld items."), names.count)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func deleteSelectedItems() {
        let names = selectedItems.map(\.name)
        guard !names.isEmpty else { return }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                try await session.api.deleteEntries(repoID: repo.id, dirPath: path, names: names)
                endSelection()
                await load(force: true)
                toast = String(format: String(localized: "Deleted %lld items."), names.count)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func ensureUnlockedForOperation() async -> Bool {
        guard repo.encrypted else { return true }
        let unlocked = await session.ensureRepoUnlocked(repo.id)
        if !unlocked {
            toast = String(localized: "Please unlock the library first.")
        }
        return unlocked
    }

    private func lockLibrary() {
        session.forgetRepoPassword(repo.id)
        unlockPassword = ""
        toast = String(localized: "Library locked.")
    }

    private func unlock() {
        let password = unlockPassword
        guard !password.isEmpty, !isUnlocking else { return }
        unlockError = nil
        isUnlocking = true
        Task {
            do {
                try await session.unlockRepo(repo.id, password: password, remember: rememberRepoPassword)
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

    private func load(force: Bool = false) async {
        if repo.encrypted {
            let unlocked = await session.ensureRepoUnlocked(repo.id)
            guard unlocked else { return }
        }
        guard !isLoading else { return }
        if items.isEmpty,
           let cached = await session.offline.loadDirents(repoID: repo.id, path: path) {
            items = cached
        }
        isLoading = true
        do {
            let fresh = try await session.api.dirents(repoID: repo.id, path: path)
            items = fresh
            errorMessage = nil
            await session.offline.saveDirents(fresh, repoID: repo.id, path: path)
        } catch {
            if items.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                toast = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFolderName = ""
        guard !name.isEmpty else { return }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                try await session.api.createDirectory(repoID: repo.id, parentPath: path, name: name)
                await load(force: true)
                toast = String(localized: "Folder created.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func createFile() {
        let name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        newFileName = ""
        guard !name.isEmpty else {
            toast = String(localized: "File name must not be empty.")
            return
        }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                try await session.api.createFile(repoID: repo.id, dirPath: path, name: name)
                await load(force: true)
                toast = String(localized: "Created file")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func performRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.name else { return }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                try await session.api.renameEntry(repoID: repo.id, path: target.path, newName: name)
                await load(force: true)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                try await session.api.deleteEntries(repoID: repo.id, dirPath: path, names: [target.name])
                await load(force: true)
                toast = String(localized: "Deleted.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func toggleStar(_ dirent: Dirent) {
        Task {
            do {
                try await session.toggleStarred(repoID: repo.id, path: dirent.path)
                toast = session.isStarred(repoID: repo.id, path: dirent.path) ? String(localized: "Added to starred.") : String(localized: "Removed from starred.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func downloadSelection() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        if repo.encrypted && !session.isRepoUnlocked(repo.id) {
            toast = String(localized: "Unlock the library before downloading it for offline use.")
            return
        }
        Task {
            for item in targets {
                while session.offlineDownloads.isDownloading {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
                guard session.offlineDownloads.download(repoID: repo.id,
                                                        path: item.path,
                                                        title: item.name) else { break }
            }
            isSelecting = false
        }
    }

    private func starSelection() {
        let targets = selectedItems
        let star = !allSelectionStarred
        Task {
            for item in targets {
                if session.isStarred(repoID: repo.id, path: item.path) != star {
                    try? await session.toggleStarred(repoID: repo.id, path: item.path)
                }
            }
            toast = star ? String(localized: "Added to starred.") : String(localized: "Removed from starred.")
        }
    }

    private func copyLink(_ dirent: Dirent) {
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                if let link = try await session.api.shareLink(repoID: repo.id, path: dirent.path) {
                    UIPasteboard.general.string = link.absoluteString
                    toast = String(localized: "Link copied.")
                } else {
                    toast = String(localized: "No share link is available.")
                }
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func shareLinkByEmail(_ dirent: Dirent) {
        guard MFMailComposeViewController.canSendMail() else {
            toast = String(localized: "The mail account has not been set up.")
            return
        }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                guard let link = try await session.api.shareLink(repoID: repo.id,
                                                                 path: dirent.path) else {
                    toast = String(localized: "No share link is available.")
                    return
                }
                let subjectFormat = dirent.isDirectory
                    ? String(localized: "Directory “%@” is shared with you using Seafile")
                    : String(localized: "File “%@” is shared with you using Seafile")
                let bodyFormat = dirent.isDirectory
                    ? String(localized: "Hi,\n\nHere is a link to the directory “%@” in my Seafile:\n\n%@\n")
                    : String(localized: "Hi,\n\nHere is a link to the file “%@” in my Seafile:\n\n%@\n")
                mailRequest = MailRequest(
                    subject: String(format: subjectFormat, dirent.name),
                    body: String(format: bodyFormat, dirent.name, link.absoluteString)
                )
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func downloadAndShare(_ dirent: Dirent) {
        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                let url = try await session.transfers.download(repoID: repo.id,
                                                               path: dirent.path,
                                                               name: dirent.name,
                                                               version: dirent.version)
                shareItem = ShareItem(url: url)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func exportSelection(_ action: BatchExportAction) {
        guard !isPreparingBatch else { return }
        let files = selectedItems.filter { !$0.isDirectory }
        guard !files.isEmpty else {
            toast = String(localized: "Select files to export.")
            return
        }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            isPreparingBatch = true
            defer { isPreparingBatch = false }

            var urls: [URL] = []
            var failures = 0
            for file in files {
                do {
                    let url = try await session.transfers.download(repoID: repo.id,
                                                                   path: file.path,
                                                                   name: file.name,
                                                                   version: file.version)
                    urls.append(url)
                } catch {
                    failures += 1
                }
            }

            guard !urls.isEmpty else {
                toast = String(localized: "Some files could not be downloaded.")
                return
            }

            switch action {
            case .share:
                if failures > 0 {
                    toast = String(localized: "Some files could not be downloaded.")
                }
                batchShareItem = BatchShareItem(urls: urls)
            case .saveToPhotos:
                await saveSelectionToPhotos(urls)
            }
        }
    }

    private func saveSelectionToPhotos(_ urls: [URL]) async {
        let media = urls.filter {
            let kind = FileKind.of(name: $0.lastPathComponent)
            return kind == .image || kind == .video
        }
        guard !media.isEmpty else {
            toast = String(localized: "No photos or videos were selected.")
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            toast = String(localized: "Photos access is required.")
            return
        }

        do {
            var stillURLs: [URL] = []
            for url in media {
                if await MotionPhotoSaver.saveLivePhotoIfPossible(from: url) { continue }
                stillURLs.append(url)
            }
            if !stillURLs.isEmpty {
                try await PHPhotoLibrary.shared().performChanges {
                    for url in stillURLs {
                        let request = PHAssetCreationRequest.forAsset()
                        let type: PHAssetResourceType = FileKind.of(name: url.lastPathComponent) == .video
                            ? .video
                            : .photo
                        request.addResource(with: type, fileURL: url, options: nil)
                    }
                }
            }
            toast = String(format: String(localized: "Saved %lld items to Photos."), media.count)
        } catch {
            toast = String(format: String(localized: "Could not save to Photos: %@"),
                           error.localizedDescription)
        }
    }

    private func downloadFolderForOffline(_ folderPath: String, title: String) {
        if repo.encrypted, !session.isRepoUnlocked(repo.id) {
            toast = String(localized: "Unlock the library before downloading it for offline use.")
            return
        }
        guard session.offlineDownloads.download(repoID: repo.id,
                                                path: folderPath,
                                                title: title) else {
            toast = String(localized: "An offline download is already in progress.")
            return
        }
    }

    private func uploadFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            let existingNames = Set(items.map { $0.name.lowercased() })
            let conflicts = urls.filter {
                existingNames.contains($0.lastPathComponent.lowercased())
            }
            guard conflicts.isEmpty else {
                pendingUploadURLs = urls
                uploadConflictNames = conflicts.map(\.lastPathComponent)
                showUploadConflict = true
                return
            }
            await performUploads(urls, replace: false)
        }
    }

    private func performUploads(_ urls: [URL], replace: Bool) async {
        guard !urls.isEmpty else { return }
        var failures = 0
        for url in urls {
            do {
                _ = try await session.transfers.upload(fileURL: url,
                                                       fileName: url.lastPathComponent,
                                                       repoID: repo.id,
                                                       dirPath: path,
                                                       replace: replace)
            } catch {
                failures += 1
                toast = String(localized: "Upload failed: \(error.localizedDescription)")
            }
        }
        await load(force: true)
        if failures == 0 {
            toast = urls.count == 1
                ? String(localized: "Uploaded \(urls[0].lastPathComponent).")
                : String(localized: "Uploaded \(urls.count) files.")
        }
    }

    private func uploadCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            toast = String(localized: "Could not read the captured photo.")
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = "IMG_\(formatter.string(from: Date())).jpg"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-camera-\(UUID().uuidString)")
            .appendingPathComponent(name)

        Task {
            guard await ensureUnlockedForOperation() else { return }
            do {
                try FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: tempURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent()) }
                _ = try await session.transfers.upload(fileURL: tempURL,
                                                       fileName: name,
                                                       repoID: repo.id,
                                                       dirPath: path)
                await load(force: true)
                toast = String(format: String(localized: "Uploaded %@."), name)
            } catch {
                toast = String(localized: "Upload failed: \(error.localizedDescription)")
            }
        }
    }

    private func uploadPhotos(_ photos: [PhotosPickerItem]) {
        guard !photos.isEmpty else { return }
        Task {
            guard await ensureUnlockedForOperation() else { return }
            if settings.uploadLivePhotos,
               PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            var urls: [URL] = []
            for (index, item) in photos.enumerated() {
                if settings.uploadLivePhotos,
                   let identifier = item.itemIdentifier,
                   let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject,
                   LivePhotoExport.isLivePhoto(asset),
                   let ext = LivePhotoExport.outputExtension(for: asset),
                   LivePhotoExport.hasPairedVideo(asset),
                   let data = try? await LivePhotoExport.motionPhotoData(for: asset) {
                    let name = "Photo-\(Int(Date().timeIntervalSince1970))-\(index).\(ext)"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                    if (try? data.write(to: url)) != nil {
                        urls.append(url)
                        continue
                    }
                }
                guard let originalData = try? await item.loadTransferable(type: Data.self) else { continue }
                let type = item.supportedContentTypes.first
                if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                    if let url = await exportVideo(item: item, index: index) {
                        urls.append(url)
                    }
                    continue
                }
                var data = originalData
                var ext = type?.preferredFilenameExtension ?? "jpg"
                if settings.convertPhotosToJPEG,
                   Self.isHEIF(type) || ext == "heic" || ext == "heif",
                   let jpeg = ImageTranscoder.jpegDataPreservingMetadata(from: originalData) {
                    data = jpeg
                    ext = "jpg"
                }
                let name = "Photo-\(Int(Date().timeIntervalSince1970))-\(index).\(ext)"
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                do {
                    try data.write(to: url)
                    urls.append(url)
                } catch {
                    continue
                }
            }
            photoItems = []
            guard !urls.isEmpty else {
                toast = String(localized: "Could not read the selected photos.")
                return
            }
            var failures = 0
            for url in urls {
                do {
                    _ = try await session.transfers.upload(fileURL: url,
                                                           fileName: url.lastPathComponent,
                                                           repoID: repo.id,
                                                           dirPath: path)
                } catch {
                    failures += 1
                    toast = String(localized: "Upload failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: url)
            }
            await load(force: true)
            if failures == 0 {
                toast = urls.count == 1
                    ? String(localized: "Uploaded \(urls.count) photo.")
                    : String(localized: "Uploaded \(urls.count) photos.")
            }
        }
    }

    private func exportVideo(item: PhotosPickerItem, index: Int) async -> URL? {
        guard let identifier = item.itemIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            return nil
        }
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) ?? resources.first else {
            return nil
        }
        let ext = UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? "mov"
        let name = "Video-\(Int(Date().timeIntervalSince1970))-\(index).\(ext)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let error: Error? = await withCheckedContinuation { continuation in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: nil) { error in
                continuation.resume(returning: error)
            }
        }
        return error == nil ? url : nil
    }

    private static func isHEIF(_ type: UTType?) -> Bool {
        let identifier = type?.identifier.lowercased() ?? ""
        return identifier.contains("heic") || identifier.contains("heif")
    }
}
