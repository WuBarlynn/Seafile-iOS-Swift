import MessageUI
import SwiftUI

struct LibrariesView: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var app
    @State private var searchText = ""
    @State private var showCreateLibrary = false
    @State private var showAccountSwitcher = false
    @State private var showSearch = false
    @State private var mailRequest: MailRequest?
    @State private var renameTarget: Repository?
    @State private var renameText = ""
    @State private var showRename = false
    @State private var deleteTarget: Repository?
    @State private var showDelete = false

    private var filteredSections: [RepositorySection] {
        let sections = session.repositorySections
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let items = section.repositories.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                ($0.ownerName ?? "").localizedCaseInsensitiveContains(query) ||
                ($0.groupName ?? "").localizedCaseInsensitiveContains(query)
            }
            return items.isEmpty ? nil : RepositorySection(id: section.id, title: section.title, repositories: items)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    LazyVStack(spacing: 18, pinnedViews: []) {
                        if let error = session.librariesError, session.repositories.isEmpty {
                            errorCard(error)
                        } else if session.isLoadingLibraries && session.repositories.isEmpty {
                            LoadingCard(message: "Loading libraries…")
                        } else if session.repositories.isEmpty {
                            EmptyStateCard(icon: "books.vertical",
                                           title: "No libraries yet",
                                           message: "Create a library to start uploading and organizing files.",
                                           actionTitle: "New Library") {
                                showCreateLibrary = true
                            }
                        } else {
                            ForEach(filteredSections) { section in
                                repositorySection(section)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 28)
                }
                .refreshable {
                    await session.refreshLibraries()
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                OfflineDownloadBanner()
            }
            .navigationTitle("Libraries")
            .searchable(text: $searchText, prompt: "Search libraries")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAccountSwitcher = true
                    } label: {
                        AccountAvatar(initials: session.account.initials,
                                      size: 30,
                                      account: session.account,
                                      token: session.api.token)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 6, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 11, height: 11)
                                    .background(Color.seafileOrange, in: Circle())
                                    .offset(x: 2, y: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch account")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("Search files")

                    Menu {
                        Button {
                            showCreateLibrary = true
                        } label: {
                            Label("New Library", systemImage: "plus.rectangle.on.folder")
                        }
                        Button {
                            Task { await session.refreshLibraries() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(for: FolderRoute.self) { route in
                FolderView(repo: route.repo, path: route.path)
            }
            .sheet(isPresented: $showCreateLibrary) {
                CreateLibraryView()
            }
            .fullScreenCover(isPresented: $showAccountSwitcher) {
                AccountSwitcherView()
            }
            .sheet(isPresented: $showSearch) {
                SearchView()
            }
            .sheet(item: $mailRequest) { request in
                MailComposeView(request: request) {
                    mailRequest = nil
                }
            }
            .alert("Rename Library", isPresented: $showRename) {
                TextField("Library name", text: $renameText)
                Button("Save") { renameLibrary() }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?",
                                isPresented: $showDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { deleteLibrary() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the library and all of its files. This action cannot be undone.")
            }
            .task {
                if session.repositories.isEmpty {
                    await session.refreshLibraries()
                }
            }
        }
    }

    private func repositorySection(_ section: RepositorySection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: section.title, subtitle: "\(section.repositories.count)")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12)], spacing: 12) {
                ForEach(section.repositories) { repo in
                    NavigationLink(value: FolderRoute(repo: repo, path: "/")) {
                        LibraryCard(repo: repo)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            downloadLibrary(repo)
                        } label: {
                            Label("Download for Offline", systemImage: "arrow.down.circle")
                        }
                        Button {
                            Task { await copyLibraryLink(repo) }
                        } label: {
                            Label("Copy Link", systemImage: "link")
                        }
                        Button {
                            shareLibraryByEmail(repo)
                        } label: {
                            Label("Send Share Link via Email", systemImage: "envelope")
                        }
                        if repo.kind == .mine {
                            Button {
                                renameTarget = repo
                                renameText = repo.name
                                showRename = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleteTarget = repo
                                showDelete = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Button {
                            Task { await session.refreshLibraries() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Try Again") {
                Task { await session.refreshLibraries() }
            }
            .buttonStyle(GlassProminentButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 24, padding: 20)
    }

    private func downloadLibrary(_ repo: Repository) {
        if repo.encrypted, !session.isRepoUnlocked(repo.id) {
            app.toastMessage = String(localized: "Open and unlock the library before downloading it for offline use.")
            return
        }
        guard session.offlineDownloads.download(repoID: repo.id,
                                                path: "/",
                                                title: repo.name) else {
            app.toastMessage = String(localized: "An offline download is already in progress.")
            return
        }
    }

    private func renameLibrary() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.name else { return }
        Task {
            do {
                try await session.api.renameLibrary(id: target.id, newName: name)
                await session.refreshLibraries()
                app.toastMessage = String(localized: "Library renamed.")
            } catch {
                app.toastMessage = error.localizedDescription
            }
        }
    }

    private func deleteLibrary() {
        guard let target = deleteTarget else { return }
        Task {
            do {
                try await session.api.deleteLibrary(id: target.id)
                session.forgetRepoPassword(target.id)
                await session.refreshLibraries()
                app.toastMessage = String(localized: "Library deleted.")
            } catch {
                app.toastMessage = error.localizedDescription
            }
        }
    }

    private func shareLibraryByEmail(_ repo: Repository) {
        guard MFMailComposeViewController.canSendMail() else {
            app.toastMessage = String(localized: "The mail account has not been set up.")
            return
        }
        Task {
            do {
                guard let link = try await session.api.shareLink(repoID: repo.id, path: "/") else {
                    app.toastMessage = String(localized: "No share link is available.")
                    return
                }
                mailRequest = MailRequest(
                    subject: String(format: String(localized: "Library “%@” is shared with you using Seafile"),
                                    repo.name),
                    body: String(format: String(localized: "Hi,\n\nHere is a link to the library “%@” in my Seafile:\n\n%@\n"),
                                 repo.name,
                                 link.absoluteString)
                )
            } catch {
                app.toastMessage = error.localizedDescription
            }
        }
    }

    private func copyLibraryLink(_ repo: Repository) async {
        do {
            if let link = try await session.api.shareLink(repoID: repo.id, path: "/") {
                UIPasteboard.general.string = link.absoluteString
                app.toastMessage = "Link copied."
            } else {
                app.toastMessage = "No share link is available."
            }
        } catch {
            app.toastMessage = error.localizedDescription
        }
    }
}

struct LibraryCard: View {
    let repo: Repository

    var body: some View {
        HStack(spacing: 14) {
            FileIconTile(kind: .folder, size: 48)
                .overlay(alignment: .bottomTrailing) {
                    if repo.encrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(repo.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if repo.kind == .shared || repo.kind == .group {
                        Text(repo.ownerName ?? repo.owner ?? repo.groupName ?? "Shared")
                            .lineLimit(1)
                    } else {
                        Text(DisplayFormat.relative(repo.modified))
                    }
                    if repo.isReadOnly {
                        Image(systemName: "lock")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    if repo.size > 0 {
                        Text("· \(DisplayFormat.fileSize(repo.size))")
                    }
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
        .glassCard(cornerRadius: 22, padding: 14)
        .contentShape(Rectangle())
    }
}
