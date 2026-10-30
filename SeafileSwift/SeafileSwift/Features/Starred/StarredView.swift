import SwiftUI
import UIKit

struct StarredView: View {
    @Environment(Session.self) private var session
    @State private var previewTarget: PreviewTarget?
    @State private var shareItem: ShareItem?
    @State private var path = NavigationPath()
    @State private var toast: String?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SeafileBackground()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await session.refreshStarred()
                }
            }
            .navigationTitle("Starred")
            .navigationDestination(for: FolderRoute.self) { route in
                FolderView(repo: route.repo, path: route.path)
            }
            .fullScreenCover(item: $previewTarget) { target in
                PreviewScreen(target: target)
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(items: [item.url])
            }
            .seafileToast($toast)
            .task {
                if session.starredItems.isEmpty {
                    await session.refreshStarred()
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if session.isLoadingStarred && session.starredItems.isEmpty {
            LoadingCard(message: "Loading starred files…")
                .padding(.top, 12)
        } else if let error = session.starredError, session.starredItems.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "star.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(LocalizedStringKey(error))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await session.refreshStarred() }
                }
                .buttonStyle(GlassProminentButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 24, padding: 22)
        } else if session.starredItems.isEmpty {
            EmptyStateCard(icon: "star",
                           title: "No starred files",
                           message: "Star files and folders from a library to find them quickly here.")
                .padding(.top, 12)
        } else {
            SectionHeader(title: String(localized: "\(session.starredItems.count) items"), subtitle: session.account.displayLabel)
            VStack(spacing: 0) {
                ForEach(session.starredItems) { item in
                    row(item)
                    if item.id != session.starredItems.last?.id {
                        Divider().padding(.leading, 66).opacity(0.5)
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder
    private func row(_ item: StarredItem) -> some View {
        let repo = session.repositories.first(where: { $0.id == item.repoID })
            ?? Repository(id: item.repoID, name: item.repoName ?? "Library", encrypted: item.encrypted)
        Button {
            if item.isDirectory {
                path.append(FolderRoute(repo: repo, path: item.path))
            } else {
                previewTarget = PreviewTarget(starred: item)
            }
        } label: {
            HStack(spacing: 12) {
                FileIconTile(kind: FileKind.of(name: item.name, isDirectory: item.isDirectory), size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(item.repoName ?? repo.name)
                        Text("·")
                        Text(item.path)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                unstar(item)
            } label: {
                Label("Remove Star", systemImage: "star.slash")
            }
            Button {
                copyLink(item)
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            if !item.isDirectory {
                Button {
                    saveAndShare(item)
                } label: {
                    Label("Save and Share…", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    private func unstar(_ item: StarredItem) {
        Task {
            do {
                try await session.api.setStarred(false, repoID: item.repoID, path: item.path)
                await session.refreshStarred()
                toast = String(localized: "Removed from starred.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func copyLink(_ item: StarredItem) {
        Task {
            do {
                if let link = try await session.api.shareLink(repoID: item.repoID, path: item.path) {
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

    private func saveAndShare(_ item: StarredItem) {
        Task {
            do {
                let url = try await session.transfers.download(repoID: item.repoID,
                                                               path: item.path,
                                                               name: item.name,
                                                               version: String(item.modified?.timeIntervalSince1970 ?? 0))
                shareItem = ShareItem(url: url)
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}
