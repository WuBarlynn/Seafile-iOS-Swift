import Foundation
import Observation

@MainActor
@Observable
final class Session {
    let account: Account
    let api: APIClient
    let cache: FileCache
    let offlineFiles: FileCache
    let offline: OfflineCache
    let transfers: TransferCenter
    let thumbnails: ThumbnailService
    let settings: AppSettings
    let photoSync: PhotoSyncManager
    let offlineDownloads: OfflineDownloadManager

    private(set) var serverInfo: ServerInfo?
    private(set) var accountInfo: AccountInfo?
    private(set) var repositories: [Repository] = []
    var isLoadingLibraries = false
    var librariesError: String?

    private(set) var starredItems: [StarredItem] = []
    var isLoadingStarred = false
    var starredError: String?

    private(set) var activities: [ActivityEvent] = []
    var isLoadingActivities = false
    var activitiesError: String?
    private(set) var hasMoreActivities = true
    private var nextActivitiesPage = 1

    private var didBootstrap = false
    private var repoCryptoKeys: [String: RepoCryptoKey] = [:]
    private var repoEncInfos: [String: RepoEncryptionInfo] = [:]
    private var repoLastAccess: [String: Date] = [:]
    private var autoLockTask: Task<Void, Never>?
    private let autoLockInterval: TimeInterval = 30 * 60

    var id: String { account.id }
    var searchEnabled: Bool { serverInfo?.isSearchEnabled ?? false }
    var activitiesAvailable: Bool { serverInfo?.isActivityEnabled ?? true }
    var wikiAvailable: Bool { serverInfo?.isWikiSupported ?? false }
    var onlineOfficeAvailable: Bool { serverInfo?.has("onlyoffice") ?? false }

    func isRepoUnlocked(_ repoID: String) -> Bool {
        repoCryptoKeys[repoID] != nil
    }

    func unlockRepo(_ repoID: String, password: String, remember: Bool) async throws {
        try await deriveAndStoreKey(repoID: repoID, password: password, remember: remember)
    }

    func ensureRepoUnlocked(_ repoID: String) async -> Bool {
        if repoCryptoKeys[repoID] != nil {
            touchRepo(repoID)
            return true
        }
        guard rememberPasswordsEnabled() else { return false }
        guard let stored = RepoSecretStore.password(accountID: account.id, repoID: repoID) else {
            return false
        }
        do {
            try await deriveAndStoreKey(repoID: repoID, password: stored, remember: true)
            return true
        } catch RepoUnlockError.incorrectPassword {
            RepoSecretStore.delete(accountID: account.id, repoID: repoID)
            return false
        } catch {
            return false
        }
    }

    private func rememberPasswordsEnabled() -> Bool {
        UserDefaults.standard.object(forKey: AppSettingsKeys.rememberRepoPasswords) as? Bool ?? true
    }

    private func deriveAndStoreKey(repoID: String, password: String, remember: Bool) async throws {
        let info = try await encryptionInfo(repoID: repoID)
        guard info.encrypted else {
            repoCryptoKeys.removeValue(forKey: repoID)
            return
        }

        let magic = info.magic
        let randomKey = info.randomKey

        if info.version == 3 {
            throw RepoUnlockError.unsupportedVersion
        }

        if info.version == 4 {
            guard let salt = info.salt, !salt.isEmpty else {
                throw RepoUnlockError.missingKey
            }
            guard let randomKey, !randomKey.isEmpty else {
                throw RepoUnlockError.missingKey
            }
            if let magic, !magic.isEmpty {
                let expected = try await Task.detached(priority: .userInitiated) {
                    try SeafCrypto.passwordMagicV4(repoID: repoID, password: password, saltHex: salt)
                }.value
                guard expected.caseInsensitiveCompare(magic) == .orderedSame else {
                    throw RepoUnlockError.incorrectPassword
                }
            }
            let key = try await Task.detached(priority: .userInitiated) {
                try SeafCrypto.deriveRepoKeyV4(password: password,
                                               randomKeyHex: randomKey,
                                               saltHex: salt)
            }.value
            storeKey(key, info: info, repoID: repoID, password: password, remember: remember)
            return
        }

        if info.version == 2 || (info.version == 0 && randomKey != nil) {
            guard let randomKey, !randomKey.isEmpty else {
                throw RepoUnlockError.missingKey
            }
            if let magic, !magic.isEmpty {
                let expected = try await Task.detached(priority: .userInitiated) {
                    try SeafCrypto.passwordMagicV2(repoID: repoID, password: password)
                }.value
                guard expected.caseInsensitiveCompare(magic) == .orderedSame else {
                    throw RepoUnlockError.incorrectPassword
                }
            }
            let key = try await Task.detached(priority: .userInitiated) {
                try SeafCrypto.deriveRepoKey(password: password, randomKeyHex: randomKey)
            }.value
            storeKey(key, info: info, repoID: repoID, password: password, remember: remember)
            return
        }

        if let magic, !magic.isEmpty {
            let expectedV1 = try await Task.detached(priority: .userInitiated) {
                try SeafCrypto.passwordMagicV1(repoID: repoID, password: password)
            }.value
            if expectedV1.caseInsensitiveCompare(magic) == .orderedSame {
                let key = try await Task.detached(priority: .userInitiated) {
                    try SeafCrypto.deriveRepoKeyV1(password: password)
                }.value
                storeKey(key, info: info, repoID: repoID, password: password, remember: remember)
                return
            }
            if info.version == 0, let randomKey, !randomKey.isEmpty {
                let expectedV2 = try await Task.detached(priority: .userInitiated) {
                    try SeafCrypto.passwordMagicV2(repoID: repoID, password: password)
                }.value
                if expectedV2.caseInsensitiveCompare(magic) == .orderedSame {
                    let key = try await Task.detached(priority: .userInitiated) {
                        try SeafCrypto.deriveRepoKey(password: password, randomKeyHex: randomKey)
                    }.value
                    storeKey(key, info: info, repoID: repoID, password: password, remember: remember)
                    return
                }
            }
            throw RepoUnlockError.incorrectPassword
        }

        if info.version == 1 || info.version == 0 {
            let key = try await Task.detached(priority: .userInitiated) {
                try SeafCrypto.deriveRepoKeyV1(password: password)
            }.value
            storeKey(key, info: info, repoID: repoID, password: password, remember: remember)
            return
        }
        throw RepoUnlockError.missingKey
    }

    private func storeKey(_ key: RepoCryptoKey,
                          info: RepoEncryptionInfo,
                          repoID: String,
                          password: String,
                          remember: Bool) {
        repoCryptoKeys[repoID] = key
        repoEncInfos[repoID] = info
        touchRepo(repoID)
        if remember && rememberPasswordsEnabled() {
            RepoSecretStore.save(password: password, accountID: account.id, repoID: repoID)
        } else {
            RepoSecretStore.delete(accountID: account.id, repoID: repoID)
        }
    }

    private func encryptionInfo(repoID: String) async throws -> RepoEncryptionInfo {
        if let cached = repoEncInfos[repoID] { return cached }
        do {
            let info = try await api.repoEncryptionInfo(repoID: repoID)
            repoEncInfos[repoID] = info
            await offline.saveEncryptionInfo(info, repoID: repoID)
            return info
        } catch {
            if let cached = await offline.loadEncryptionInfo(repoID: repoID) {
                repoEncInfos[repoID] = cached
                return cached
            }
            throw error
        }
    }

    func touchRepo(_ repoID: String) {
        repoLastAccess[repoID] = Date()
    }

    func forgetRepoPassword(_ repoID: String) {
        repoCryptoKeys.removeValue(forKey: repoID)
        repoEncInfos.removeValue(forKey: repoID)
        repoLastAccess.removeValue(forKey: repoID)
        RepoSecretStore.delete(accountID: account.id, repoID: repoID)
    }

    /// Removes the stored copies without locking the libraries that are
    /// currently open. Unlocked-but-unsaved libraries will be locked by the
    /// 30-minute inactivity timer.
    func discardSavedRepoPasswords() {
        RepoSecretStore.deleteAll(accountID: account.id)
    }

    private func startAutoLockTimer() {
        autoLockTask?.cancel()
        autoLockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                self.autoLockInactiveRepos()
            }
        }
    }

    private func autoLockInactiveRepos() {
        let now = Date()
        for (repoID, last) in repoLastAccess where now.timeIntervalSince(last) >= autoLockInterval {
            // Passwords explicitly saved on this device are never auto-cleared.
            if RepoSecretStore.password(accountID: account.id, repoID: repoID) != nil {
                continue
            }
            repoCryptoKeys.removeValue(forKey: repoID)
            repoLastAccess.removeValue(forKey: repoID)
        }
    }

    init(account: Account, token: String, settings: AppSettings) {
        self.account = account
        self.settings = settings
        api = APIClient(serverURL: account.serverURL, token: token, allowUntrusted: account.allowUntrustedCertificate)
        cache = FileCache(accountID: account.id)
        offlineFiles = FileCache(accountID: account.id, persistent: true)
        offline = OfflineCache(accountID: account.id)
        transfers = TransferCenter(api: api, cache: cache, offlineFiles: offlineFiles)
        thumbnails = ThumbnailService(api: api)
        photoSync = PhotoSyncManager(account: account,
                                     api: api,
                                     transfers: transfers,
                                     settings: settings)
        offlineDownloads = OfflineDownloadManager(api: api, transfers: transfers)
        transfers.cryptoKeyProvider = { [weak self] repoID in
            self?.repoCryptoKeys[repoID]
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        if !rememberPasswordsEnabled() {
            RepoSecretStore.deleteAll(accountID: account.id)
        }
        startAutoLockTimer()

        if repositories.isEmpty, let cached = await offline.loadLibraries() {
            repositories = cached
        }

        async let infoResult = try? api.serverInfo()
        async let accountResult = try? api.accountInfo()
        let (info, infoResultAccount) = await (infoResult, accountResult)
        serverInfo = info
        accountInfo = infoResultAccount
        await thumbnails.update(serverInfo: info)
        await refreshLibraries()
        await photoSync.prepare()
    }

    func refreshLibraries(silently: Bool = false) async {
        if !silently { isLoadingLibraries = true }
        do {
            let fresh = try await api.repositories()
            repositories = fresh
            librariesError = nil
            await offline.saveLibraries(fresh)
        } catch {
            if repositories.isEmpty, let cached = await offline.loadLibraries() {
                repositories = cached
            }
            librariesError = repositories.isEmpty ? error.localizedDescription : nil
        }
        isLoadingLibraries = false
    }

    var repositorySections: [RepositorySection] {
        Self.sections(for: repositories)
    }

    static func sections(for repositories: [Repository]) -> [RepositorySection] {
        var result: [RepositorySection] = []

        func append(_ id: String, _ title: String, _ items: [Repository]) {
            guard !items.isEmpty else { return }
            result.append(RepositorySection(id: id,
                                            title: title,
                                            repositories: items.sorted { NaturalSort.lessThan($0.name, $1.name) }))
        }

        append("mine", "My Libraries", repositories.filter { $0.kind == .mine })
        append("shared", "Shared with Me", repositories.filter { $0.kind == .shared })

        let groups = Dictionary(grouping: repositories.filter { $0.kind == .group }) { repo in
            repo.groupName?.isEmpty == false ? repo.groupName! : "Group Libraries"
        }
        for name in groups.keys.sorted(by: NaturalSort.lessThan) {
            append("group-\(name)", name, groups[name] ?? [])
        }

        append("public", "Public Libraries", repositories.filter { $0.kind == .public })
        append("other", "Other Libraries", repositories.filter { $0.kind == .other })
        return result
    }

    func repoName(for repoID: String) -> String? {
        repositories.first(where: { $0.id == repoID })?.name
    }

    func refreshStarred() async {
        isLoadingStarred = true
        do {
            starredItems = try await api.starredItems()
            starredError = nil
        } catch {
            starredError = error.localizedDescription
        }
        isLoadingStarred = false
    }

    func isStarred(repoID: String, path: String) -> Bool {
        starredItems.contains { $0.repoID == repoID && $0.path == path }
    }

    func toggleStarred(repoID: String, path: String) async throws {
        let starred = isStarred(repoID: repoID, path: path)
        try await api.setStarred(!starred, repoID: repoID, path: path)
        await refreshStarred()
    }

    func loadActivities(reset: Bool) async {
        guard !isLoadingActivities else { return }
        if reset {
            activities = []
            nextActivitiesPage = 1
            hasMoreActivities = true
        }
        guard hasMoreActivities else { return }
        isLoadingActivities = true
        do {
            let page = try await api.activities(page: nextActivitiesPage,
                                                useNewAPI: serverInfo?.supportsNewActivitiesAPI ?? true)
            activities.append(contentsOf: page.events)
            nextActivitiesPage = page.nextPage
            hasMoreActivities = page.hasMore
            activitiesError = nil
        } catch {
            activitiesError = error.localizedDescription
        }
        isLoadingActivities = false
    }

    func cacheSize() -> Int64 {
        cache.totalSize()
    }
}

enum RepoUnlockError: LocalizedError {
    case incorrectPassword
    case unsupportedVersion
    case missingKey

    var errorDescription: String? {
        switch self {
        case .incorrectPassword:
            return String(localized: "Incorrect password. Try again.")
        case .unsupportedVersion:
            return String(localized: "This library uses an older encryption format that is not supported for local decryption yet.")
        case .missingKey:
            return String(localized: "The server did not provide the encryption key for this library.")
        }
    }
}
