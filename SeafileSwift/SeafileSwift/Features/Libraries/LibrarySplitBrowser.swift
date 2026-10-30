import SwiftUI
import UIKit

struct LibrarySplitBrowser: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var app

    @State private var selection: FolderRoute?
    @State private var searchText = ""
    @State private var showCreateLibrary = false
    @State private var showAccountSwitcher = false
    @State private var showSearch = false
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
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.seafileOrange)
        .sheet(isPresented: $showCreateLibrary) {
            CreateLibraryView()
        }
        .fullScreenCover(isPresented: $showAccountSwitcher) {
            AccountSwitcherView()
        }
        .sheet(isPresented: $showSearch) {
            SearchView()
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
        .onChange(of: session.repositories) { _, repositories in
            guard let selection else { return }
            guard let match = repositories.first(where: { $0.id == selection.repo.id }) else {
                self.selection = nil
                return
            }
            if match != selection.repo {
                self.selection = FolderRoute(repo: match, path: selection.path)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            if let error = session.librariesError, session.repositories.isEmpty {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Try Again") {
                        Task { await session.refreshLibraries() }
                    }
                }
            }
            ForEach(filteredSections) { section in
                Section {
                    ForEach(section.repositories) { repo in
                        LibrarySidebarRow(repo: repo)
                            .tag(FolderRoute(repo: repo, path: "/"))
                            .contextMenu { contextMenu(for: repo) }
                    }
                } header: {
                    Text(LocalizedStringKey(section.title))
                }
            }
        }
        .listStyle(.sidebar)
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
        .overlay {
            if filteredSections.isEmpty && !session.isLoadingLibraries {
                ContentUnavailableView {
                    Label("No libraries yet", systemImage: "books.vertical")
                } description: {
                    Text("Create a library to start uploading and organizing files.")
                } actions: {
                    Button("New Library") {
                        showCreateLibrary = true
                    }
                    .buttonStyle(GlassProminentButtonStyle())
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 400)
    }

    @ViewBuilder
    private var detail: some View {
        if let selection {
            NavigationStack {
                FolderView(repo: selection.repo, path: selection.path)
            }
            .id(selection.repo.id)
        } else {
            ZStack {
                SeafileBackground()
                ContentUnavailableView("Choose a library", systemImage: "books.vertical")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for repo: Repository) -> some View {
        Button {
            Task { await copyLibraryLink(repo) }
        } label: {
            Label("Copy Link", systemImage: "link")
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

    private func copyLibraryLink(_ repo: Repository) async {
        do {
            if let link = try await session.api.shareLink(repoID: repo.id, path: "/") {
                UIPasteboard.general.string = link.absoluteString
                app.toastMessage = String(localized: "Link copied.")
            } else {
                app.toastMessage = String(localized: "No share link is available.")
            }
        } catch {
            app.toastMessage = error.localizedDescription
        }
    }
}

private struct LibrarySidebarRow: View {
    let repo: Repository

    var body: some View {
        HStack(spacing: 10) {
            FileIconTile(kind: .folder, size: 30)
                .overlay(alignment: .bottomTrailing) {
                    if repo.encrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(2.5)
                            .background(Color.black.opacity(0.55), in: Circle())
                            .offset(x: 2, y: 2)
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String? {
        if repo.kind == .shared || repo.kind == .group {
            return repo.ownerName ?? repo.owner ?? repo.groupName
        }
        return DisplayFormat.relative(repo.modified)
    }
}
