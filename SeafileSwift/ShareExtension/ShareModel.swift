import Foundation
import Observation

@MainActor
@Observable
final class ShareModel {
    private struct StoredDestination: Codable {
        let repoID: String
        let repoName: String
        let path: String
    }

    struct RecentDestination: Identifiable, Hashable {
        let repoID: String
        let repoName: String
        let path: String

        var id: String { repoID + "|" + path }

        var displayName: String {
            path == "/" ? repoName : (path as NSString).lastPathComponent
        }
    }

    private(set) var accounts: [SharedAccount] = []
    var selectedAccountID: String?
    var items: [SharedItem] = []
    var isLoadingItems = true
    var isLoadingRepos = false
    var isLoadingFolder = false
    var repos: [ShareRepo] = []
    var currentRepo: ShareRepo?
    var currentPath = "/"
    var directories: [ShareDirent] = []
    var starredDirs: [ShareStarredDir] = []
    var recentDirs: [RecentDestination] = []
    var isUploading = false
    var uploadProgress: Double = 0
    var errorText: String?
    var uploadedCount: Int?

    let onCancel: () -> Void
    let onFinish: () -> Void

    init(onCancel: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.onCancel = onCancel
        self.onFinish = onFinish
        let file = ShareSessionStore.load()
        accounts = file.accounts.sorted { $0.lastUsed > $1.lastUsed }
        if let last = file.lastAccountID,
           accounts.contains(where: { $0.id == last }) {
            selectedAccountID = last
        } else {
            selectedAccountID = accounts.first?.id
        }
    }

    var account: SharedAccount? {
        guard let selectedAccountID else { return nil }
        return accounts.first(where: { $0.id == selectedAccountID })
    }

    var writableRepos: [ShareRepo] {
        repos.filter { !$0.isEncrypted && $0.isWritable }
    }

    var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    func setItems(_ items: [SharedItem]) {
        self.items = items
        isLoadingItems = false
        guard !items.isEmpty else {
            errorText = String(localized: "No shareable items were provided.")
            return
        }
        Task { await loadInitial() }
    }

    func selectAccount(_ id: String) async {
        guard id != selectedAccountID else { return }
        selectedAccountID = id
        currentRepo = nil
        currentPath = "/"
        repos = []
        directories = []
        errorText = nil
        await loadInitial()
    }

    func loadInitial() async {
        guard account != nil else { return }
        await loadRepos()
        recentDirs = storedRecents()
        await loadStarred()
        guard let destination = storedDestination(),
              let repo = repos.first(where: { $0.id == destination.repoID }) else {
            return
        }
        currentRepo = repo
        currentPath = destination.path
        await loadDirectories()
    }

    func openStarred(_ item: ShareStarredDir) async {
        guard let repo = repos.first(where: { $0.id == item.repoID }) else { return }
        currentRepo = repo
        currentPath = item.path
        await loadDirectories()
    }

    func openRecent(_ item: RecentDestination) async {
        guard let repo = repos.first(where: { $0.id == item.repoID }) else { return }
        currentRepo = repo
        currentPath = item.path
        await loadDirectories()
    }

    private func loadStarred() async {
        guard let account else {
            starredDirs = []
            return
        }
        let client = ShareAPIClient(account: account)
        starredDirs = (try? await client.starredDirectories()) ?? []
    }

    func loadRepos() async {
        guard let account else { return }
        isLoadingRepos = true
        errorText = nil
        defer { isLoadingRepos = false }
        do {
            let client = ShareAPIClient(account: account)
            repos = try await client.repos()
        } catch {
            repos = []
            errorText = error.localizedDescription
        }
    }

    func open(_ repo: ShareRepo) async {
        currentRepo = repo
        currentPath = "/"
        directories = []
        await loadDirectories()
    }

    func enter(_ directory: ShareDirent) async {
        currentPath = join(currentPath, directory.name)
        await loadDirectories()
    }

    func goBack() async {
        if currentPath == "/" {
            currentRepo = nil
            directories = []
            errorText = nil
            return
        }
        currentPath = parent(of: currentPath)
        await loadDirectories()
    }

    func loadDirectories() async {
        guard let account, let repo = currentRepo else { return }
        isLoadingFolder = true
        errorText = nil
        defer { isLoadingFolder = false }
        do {
            let client = ShareAPIClient(account: account)
            directories = try await client.directories(repoID: repo.id, path: currentPath)
        } catch {
            directories = []
            errorText = error.localizedDescription
        }
    }

    func createFolder(named name: String) async -> Bool {
        guard let account, let repo = currentRepo else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let client = ShareAPIClient(account: account)
            try await client.createDirectory(repoID: repo.id, path: currentPath, name: trimmed)
            await loadDirectories()
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func upload() async {
        guard !isUploading,
              !items.isEmpty,
              let account,
              let repo = currentRepo else { return }
        isUploading = true
        uploadProgress = 0
        errorText = nil
        let client = ShareAPIClient(account: account)
        let count = items.count
        let path = currentPath

        for (index, item) in items.enumerated() {
            do {
                try await client.upload(fileURL: item.url,
                                        fileName: item.name,
                                        repoID: repo.id,
                                        directoryPath: path,
                                        progress: { fraction in
                                            Task { @MainActor [weak self] in
                                                self?.uploadProgress = (Double(index) + fraction) / Double(count)
                                            }
                                        })
            } catch {
                isUploading = false
                errorText = error.localizedDescription
                return
            }
        }

        uploadProgress = 1
        isUploading = false
        saveDestination(repo: repo, path: path)
        uploadedCount = count
    }

    // MARK: - Destination persistence

    private func destinationKey(_ accountID: String) -> String {
        "share.destination.\(accountID)"
    }

    private func storedDestination() -> StoredDestination? {
        guard let account,
              let data = ShareSessionStore.defaults?.data(forKey: destinationKey(account.id)) else {
            return nil
        }
        return try? JSONDecoder().decode(StoredDestination.self, from: data)
    }

    private func saveDestination(repo: ShareRepo, path: String) {
        guard let account,
              let data = try? JSONEncoder().encode(StoredDestination(repoID: repo.id,
                                                                     repoName: repo.name,
                                                                     path: path)) else {
            return
        }
        ShareSessionStore.defaults?.set(data, forKey: destinationKey(account.id))
        ShareSessionStore.defaults?.set(account.id, forKey: "share.lastAccountID")
        recordRecent(repo: repo, path: path)
    }

    private func recentKey(_ accountID: String) -> String {
        "share.recent.\(accountID)"
    }

    private func storedRecents() -> [RecentDestination] {
        guard let account,
              let data = ShareSessionStore.defaults?.data(forKey: recentKey(account.id)),
              let list = try? JSONDecoder().decode([StoredDestination].self, from: data) else {
            return []
        }
        return list.map {
            RecentDestination(repoID: $0.repoID, repoName: $0.repoName, path: $0.path)
        }
    }

    private func recordRecent(repo: ShareRepo, path: String) {
        guard let account else { return }
        var list = storedRecents()
        list.removeAll { $0.repoID == repo.id && $0.path == path }
        list.insert(RecentDestination(repoID: repo.id, repoName: repo.name, path: path), at: 0)
        list = Array(list.prefix(5))
        let stored = list.map {
            StoredDestination(repoID: $0.repoID, repoName: $0.repoName, path: $0.path)
        }
        if let data = try? JSONEncoder().encode(stored) {
            ShareSessionStore.defaults?.set(data, forKey: recentKey(account.id))
        }
        recentDirs = list
    }

    private func join(_ base: String, _ name: String) -> String {
        base == "/" ? "/\(name)" : "\(base)/\(name)"
    }

    private func parent(of path: String) -> String {
        let value = (path as NSString).deletingLastPathComponent
        return value.isEmpty ? "/" : value
    }
}
