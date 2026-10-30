import Photos
import SwiftUI
import UIKit

struct PhotoGalleryRequest: Identifiable {
    let id = UUID()
    let repo: Repository
    let targets: [PreviewTarget]
    let startIndex: Int
}

struct PhotoGalleryScreen: View {
    let request: PhotoGalleryRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(Session.self) private var session
    @State private var index: Int
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var shareItem: ShareItem?
    @State private var isPreparingShare = false
    @State private var isSavingToPhotos = false
    @State private var infoTarget: PreviewTarget?
    @State private var deleteTarget: PreviewTarget?
    @State private var showDeleteConfirm = false
    @State private var exportURL: URL?
    @State private var isPreparingExport = false
    @State private var showDocumentExport = false
    @State private var isImageZoomed = false
    @State private var dragOffset: CGFloat = 0
    @State private var dragScale: CGFloat = 1
    @State private var toast: String?

    init(request: PhotoGalleryRequest) {
        self.request = request
        _index = State(initialValue: min(max(0, request.startIndex), max(0, request.targets.count - 1)))
    }

    private var currentTarget: PreviewTarget? {
        guard request.targets.indices.contains(index) else { return nil }
        return request.targets[index]
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .opacity(max(0.35, 1 - Double(dragOffset) / 900))
                .ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(Array(request.targets.enumerated()), id: \.element.id) { offset, target in
                    GalleryImagePage(target: target,
                                     isActive: abs(offset - index) <= 1,
                                     onTap: toggleChrome,
                                     onInteraction: scheduleHide,
                                     onZoomChanged: { zoomed in
                                         if offset == index {
                                             isImageZoomed = zoomed
                                         }
                                     })
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .offset(y: dragOffset)
            .scaleEffect(dragScale)
            .simultaneousGesture(dismissGesture)
        }
        .overlay(alignment: .top) {
            if chromeVisible {
                topChrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.22), value: chromeVisible)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: index) { _, _ in
            isImageZoomed = false
            dragOffset = 0
            dragScale = 1
            showChrome(autoHide: true)
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(item: $infoTarget) { target in
            FileInfoSheet(target: target)
        }
        .sheet(isPresented: $showDocumentExport) {
            if let exportURL {
                DocumentExportView(urls: [exportURL])
            }
        }
        .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { deletePhoto(target) }
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .seafileToast($toast)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isImageZoomed else { return }
                let vertical = value.translation.height
                let horizontal = value.translation.width
                guard vertical > 0, abs(vertical) > abs(horizontal) * 1.4 else { return }
                dragOffset = vertical
                dragScale = max(0.82, 1 - vertical / 1600)
                chromeVisible = false
            }
            .onEnded { value in
                guard !isImageZoomed else {
                    resetDrag()
                    return
                }
                let shouldDismiss = value.translation.height > 140
                    || value.predictedEndTranslation.height > 360
                if shouldDismiss {
                    dismiss()
                } else {
                    resetDrag()
                    showChrome(autoHide: true)
                }
            }
    }

    private func resetDrag() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            dragOffset = 0
            dragScale = 1
        }
    }

    private var topChrome: some View {
        HStack(spacing: 10) {
            glassButton("xmark", label: "Close") {
                dismiss()
            }

            Spacer(minLength: 8)

            VStack(spacing: 1) {
                Text(currentTarget?.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(index + 1) / \(request.targets.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 180)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)

            Spacer(minLength: 8)

            Menu {
                Button {
                    saveCurrentToPhotos()
                } label: {
                    Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                }
                .disabled(isSavingToPhotos)

                Button {
                    exportCurrentToFiles()
                } label: {
                    Label("Save to Files", systemImage: "folder")
                }
                .disabled(isPreparingExport)

                if let target = currentTarget {
                    Button {
                        infoTarget = target
                    } label: {
                        Label("File Info", systemImage: "info.circle")
                    }

                    let starred = session.isStarred(repoID: target.repo.id, path: target.path)
                    Button {
                        toggleStar(target)
                    } label: {
                        Label(starred ? "Remove Star" : "Star",
                              systemImage: starred ? "star.slash" : "star")
                    }

                    if !request.repo.isReadOnly {
                        Button(role: .destructive) {
                            deleteTarget = target
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } label: {
                Group {
                    if isSavingToPhotos {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(currentTarget == nil)

            glassButton(isPreparingShare ? "ellipsis" : "square.and.arrow.up",
                        label: "Share",
                        disabled: isPreparingShare) {
                shareCurrent()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    private func glassButton(_ systemImage: String,
                             label: String,
                             disabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isPreparingShare, systemImage == "ellipsis" {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(disabled)
        .accessibilityLabel(LocalizedStringKey(label))
    }

    private func shareCurrent() {
        guard let target = currentTarget, !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            do {
                let url = try await localURL(for: target)
                shareItem = ShareItem(url: url)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func saveCurrentToPhotos() {
        guard let target = currentTarget, !isSavingToPhotos else { return }
        isSavingToPhotos = true
        Task {
            defer { isSavingToPhotos = false }
            do {
                let url = try await localURL(for: target)
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    toast = String(localized: "Photos access is required.")
                    return
                }
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo,
                                                                  fileURL: url,
                                                                  options: nil)
                }
                toast = String(localized: "Saved to Photos.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func exportCurrentToFiles() {
        guard let target = currentTarget, !isPreparingExport else { return }
        isPreparingExport = true
        Task {
            defer { isPreparingExport = false }
            do {
                exportURL = try await localURL(for: target)
                showDocumentExport = true
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func toggleStar(_ target: PreviewTarget) {
        Task {
            do {
                try await session.toggleStarred(repoID: target.repo.id, path: target.path)
                toast = session.isStarred(repoID: target.repo.id, path: target.path)
                    ? String(localized: "Added to starred.")
                    : String(localized: "Removed from starred.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func deletePhoto(_ target: PreviewTarget) {
        Task {
            if target.repo.encrypted {
                let unlocked = await session.ensureRepoUnlocked(target.repo.id)
                guard unlocked else {
                    toast = String(localized: "Please unlock the library first.")
                    return
                }
            }
            let parent = (target.path as NSString).deletingLastPathComponent
            let dirPath = parent.isEmpty ? "/" : parent
            do {
                try await session.api.deleteEntries(repoID: target.repo.id,
                                                    dirPath: dirPath,
                                                    names: [target.name])
                dismiss()
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func localURL(for target: PreviewTarget) async throws -> URL {
        if target.repo.encrypted {
            let unlocked = await session.ensureRepoUnlocked(target.repo.id)
            guard unlocked else { throw APIError.repoPasswordRequired }
        }
        return try await session.transfers.download(repoID: target.repo.id,
                                                    path: target.path,
                                                    name: target.name,
                                                    version: target.version)
    }

    private func toggleChrome() {
        if chromeVisible {
            hideTask?.cancel()
            withAnimation(.smooth(duration: 0.22)) { chromeVisible = false }
        } else {
            showChrome(autoHide: true)
        }
    }

    private func showChrome(autoHide: Bool) {
        withAnimation(.smooth(duration: 0.22)) { chromeVisible = true }
        if autoHide {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.22)) { chromeVisible = false }
        }
    }
}

private struct GalleryImagePage: View {
    let target: PreviewTarget
    let isActive: Bool
    let onTap: () -> Void
    let onInteraction: () -> Void
    let onZoomChanged: (Bool) -> Void

    @Environment(Session.self) private var session
    @State private var image: UIImage?
    @State private var errorText: String?

    private var progress: TransferProgress? {
        session.transfers.downloadProgress(repoID: target.repo.id, path: target.path)
    }

    var body: some View {
        ZStack {
            if let image {
                GalleryZoomImage(image: image,
                                 onTap: onTap,
                                 onInteraction: onInteraction,
                                 onZoomChanged: onZoomChanged)
                    .ignoresSafeArea()
            } else if let errorText {
                VStack(spacing: 14) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(errorText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Button("Try Again") {
                        Task { await load(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.seafileOrange)
                }
            } else {
                VStack(spacing: 12) {
                    if let progress, progress.totalBytes > 0 {
                        ProgressView(value: progress.fraction)
                            .progressViewStyle(.linear)
                            .tint(.seafileOrange)
                            .frame(width: 180)
                        Text("\(Int(progress.fraction * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .tint(.seafileOrange)
                    }
                }
            }
        }
        .task(id: "\(target.id)-\(isActive)") {
            guard isActive else { return }
            await load()
        }
    }

    private func load(force: Bool = false) async {
        guard force || image == nil else { return }
        if force {
            errorText = nil
            image = nil
        }

        if target.repo.encrypted {
            let unlocked = await session.ensureRepoUnlocked(target.repo.id)
            guard unlocked else {
                errorText = String(localized: "Please unlock the library first.")
                return
            }
        }

        do {
            let url = try await session.transfers.download(repoID: target.repo.id,
                                                           path: target.path,
                                                           name: target.name,
                                                           version: target.version)
            guard let value = UIImage(contentsOfFile: url.path) else {
                errorText = String(localized: "Unable to load this image.")
                return
            }
            image = value
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct GalleryZoomImage: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    let onInteraction: () -> Void
    let onZoomChanged: (Bool) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .clear
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        scrollView.panGestureRecognizer.isEnabled = false

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
        Coordinator(onTap: onTap, onInteraction: onInteraction, onZoomChanged: onZoomChanged)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var scrollView: UIScrollView?
        weak var imageView: UIImageView?
        private let onTap: () -> Void
        private let onInteraction: () -> Void
        private let onZoomChanged: (Bool) -> Void

        init(onTap: @escaping () -> Void,
             onInteraction: @escaping () -> Void,
             onZoomChanged: @escaping (Bool) -> Void) {
            self.onTap = onTap
            self.onInteraction = onInteraction
            self.onZoomChanged = onZoomChanged
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            onInteraction()
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.panGestureRecognizer.isEnabled = scrollView.zoomScale > 1.01
            onZoomChanged(scrollView.zoomScale > 1.01)
            onInteraction()
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            scrollView.panGestureRecognizer.isEnabled = scale > 1.01
            onZoomChanged(scale > 1.01)
        }

        @objc func handleSingleTap() {
            onTap()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1 {
                scrollView.setZoomScale(1, animated: true)
                scrollView.panGestureRecognizer.isEnabled = false
                return
            }
            let point = gesture.location(in: imageView)
            let size = scrollView.bounds.size
            let side = min(size.width, size.height) / 2.5
            let rect = CGRect(x: point.x - side / 2,
                              y: point.y - side / 2,
                              width: side,
                              height: side)
            scrollView.zoom(to: rect, animated: true)
            scrollView.panGestureRecognizer.isEnabled = true
        }
    }
}
