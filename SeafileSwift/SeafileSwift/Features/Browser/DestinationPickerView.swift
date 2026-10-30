import SwiftUI

private struct StoredDestination: Codable, Identifiable {
    let repoID: String
    let repoName: String
    let path: String

    var id: String { "\(repoID)|\(path)" }
}

private struct RecentDestination: Identifiable {
    let repo: Repository
    let path: String

    var id: String { "\(repo.id)|\(path)" }
}

enum BatchFileOperation {
    case copy
    case move

    var title: String {
        switch self {
        case .copy: return String(localized: "Copy")
        case .move: return String(localized: "Move")
        }
    }

    var confirmTitle: String {
        switch self {
        case .copy: return String(localized: "Copy Here")
        case .move: return String(localized: "Move Here")
        }
    }

    var symbol: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        }
    }
}

struct DestinationPickerView: View {
    let operation: BatchFileOperation
    let sourceRepoID: String
    let sourcePath: String
    let onSelect: (Repository, String) -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var selectedRepo: Repository?
    @State private var currentPath = "/"
    @State private var items: [Dirent] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var recents: [StoredDestination] = []
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var isCreatingFolder = false

    private var sourceRepo: Repository? {
        session.repositories.first(where: { $0.id == sourceRepoID })
    }

    private var recentDestinations: [RecentDestination] {
        recents.compactMap { item in
            guard let repo = session.repositories.first(where: { $0.id == item.repoID }) else {
                return nil
            }
            return RecentDestination(repo: repo, path: item.path)
        }
    }

    private var recentsKey: String {
        "destination.recents.\(session.account.id)"
    }

    private var isSameLocation: Bool {
        guard let selectedRepo else { return true }
        return selectedRepo.id == sourceRepoID && currentPath == sourcePath
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                content
            }
            .navigationTitle(selectedRepo?.name ?? String(localized: "Choose a library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if selectedRepo != nil {
                        Button {
                            newFolderName = ""
                            showNewFolder = true
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .disabled(isCreatingFolder)
                        .accessibilityLabel("New Folder")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(operation.confirmTitle) {
                        guard let selectedRepo else { return }
                        saveRecent(repo: selectedRepo, path: currentPath)
                        onSelect(selectedRepo, currentPath)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(selectedRepo == nil || isLoading || isSameLocation)
                }
            }
            .alert("New Folder", isPresented: $showNewFolder) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") { createFolder() }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) { newFolderName = "" }
            } message: {
                Text("Create a folder in \(currentPath).")
            }
            .task {
                loadRecents()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let selectedRepo {
            folderBrowser(repo: selectedRepo)
        } else {
            libraryPicker
        }
    }

    private var libraryPicker: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if sourceRepo != nil || !recentDestinations.isEmpty {
                    quickAccess
                }
                ForEach(session.repositorySections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(title: section.title, subtitle: "\(section.repositories.count)")
                        VStack(spacing: 8) {
                            ForEach(section.repositories) { repository in
                                Button {
                                    Task { await openLibrary(repository) }
                                } label: {
                                    HStack(spacing: 12) {
                                        FileIconTile(kind: .folder, size: 40)
                                            .overlay(alignment: .bottomTrailing) {
                                                if repository.encrypted {
                                                    Image(systemName: "lock.fill")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(.white)
                                                        .padding(3)
                                                        .background(Color.black.opacity(0.55), in: Circle())
                                                }
                                            }
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(repository.name)
                                                .font(.body.weight(.medium))
                                                .lineLimit(1)
                                            Text(repository.ownerName ?? repository.serverDetail)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.footnote.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .glassCard(cornerRadius: 20, padding: 14)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    private var quickAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Quick Access")
            VStack(spacing: 8) {
                if let sourceRepo {
                    Button {
                        Task { await openLibrary(sourceRepo) }
                    } label: {
                        quickAccessRow(title: String(localized: "Current Library"),
                                       subtitle: sourceRepo.name,
                                       icon: "bookmark.fill")
                    }
                    .buttonStyle(.plain)
                }

                ForEach(recentDestinations.filter {
                    !($0.repo.id == sourceRepoID && $0.path == "/")
                }) { destination in
                    Button {
                        Task { await openDestination(destination) }
                    } label: {
                        quickAccessRow(title: destination.repo.name,
                                       subtitle: destination.path == "/"
                                           ? String(localized: "Root folder")
                                           : destination.path,
                                       icon: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func quickAccessRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.seafileOrange)
                .frame(width: 34, height: 34)
                .background(Color.seafileOrange.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .glassCard(cornerRadius: 20, padding: 14)
        .contentShape(Rectangle())
    }

    private func folderBrowser(repo: Repository) -> some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                header(repo: repo)

                if isLoading {
                    LoadingCard(message: "Loading folders…")
                } else if let errorMessage {
                    VStack(spacing: 12) {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await load() }
                        }
                        .buttonStyle(GlassProminentButtonStyle())
                    }
                    .glassCard(cornerRadius: 22, padding: 18)
                } else if directoryItems.isEmpty {
                    EmptyStateCard(icon: "folder",
                                   title: "No subfolders",
                                   message: String(localized: "This folder has no subfolders. You can choose it as the destination."))
                } else {
                    VStack(spacing: 0) {
                        ForEach(directoryItems) { item in
                            Button {
                                Task { await openFolder(item.path) }
                            } label: {
                                HStack(spacing: 12) {
                                    FileIconTile(kind: .folder, size: 40)
                                    Text(item.name)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if item.id != directoryItems.last?.id {
                                Divider().padding(.leading, 66).opacity(0.5)
                            }
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
            .padding(16)
        }
        .refreshable { await load() }
    }

    private func header(repo: Repository) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    selectedRepo = nil
                    currentPath = "/"
                    items = []
                    errorMessage = nil
                } label: {
                    Label("Change Library", systemImage: "arrow.left")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.plain)
                Spacer()
                if let version = session.serverInfo?.version {
                    Text("v\(version)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                if currentPath != "/" {
                    Button {
                        Task { await goToParent() }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(repo.name)
                        .font(.headline)
                    Text(currentPath == "/" ? String(localized: "Root folder") : currentPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if isSameLocation {
                    Text("Current folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .glassCard(cornerRadius: 22, padding: 14)
    }

    private var directoryItems: [Dirent] {
        items.filter(\.isDirectory).sorted { NaturalSort.lessThan($0.name, $1.name) }
    }

    private func openLibrary(_ repository: Repository) async {
        selectedRepo = repository
        currentPath = "/"
        items = []
        await load()
    }

    private func openDestination(_ destination: RecentDestination) async {
        selectedRepo = destination.repo
        currentPath = destination.path
        items = []
        await load()
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let decoded = try? JSONDecoder().decode([StoredDestination].self, from: data) else {
            recents = []
            return
        }
        recents = decoded
    }

    private func saveRecent(repo: Repository, path: String) {
        let entry = StoredDestination(repoID: repo.id, repoName: repo.name, path: path)
        var values = recents.filter { $0.id != entry.id }
        values.insert(entry, at: 0)
        recents = Array(values.prefix(5))
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: recentsKey)
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard let repo = selectedRepo, !name.isEmpty, !isCreatingFolder else { return }
        isCreatingFolder = true
        let parent = currentPath
        Task {
            do {
                try await session.api.createDirectory(repoID: repo.id,
                                                      parentPath: parent,
                                                      name: name)
                newFolderName = ""
                currentPath = parent == "/" ? "/\(name)" : "\(parent)/\(name)"
                items = []
                await load()
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreatingFolder = false
        }
    }

    private func openFolder(_ path: String) async {
        currentPath = path
        await load()
    }

    private func goToParent() async {
        let parent = (currentPath as NSString).deletingLastPathComponent
        currentPath = parent.isEmpty ? "/" : parent
        await load()
    }

    private func load() async {
        guard let selectedRepo, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            items = try await session.api.dirents(repoID: selectedRepo.id, path: currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private extension Repository {
    var serverDetail: String {
        if let groupName, !groupName.isEmpty { return groupName }
        if let ownerName, !ownerName.isEmpty { return ownerName }
        return ""
    }
}
