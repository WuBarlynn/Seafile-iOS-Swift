import Foundation

@MainActor
final class AccountStore {
    static let shared = AccountStore()

    private struct Snapshot: Codable {
        var accounts: [Account]
        var lastAccountID: String?
    }

    private(set) var accounts: [Account] = []
    private(set) var lastAccountID: String?
    private let fileURL: URL
    private let backupKey = "seafile.swift.accounts.backup"

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SeafileSwift", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("accounts.json")
        reloadFromDisk()
        ShareSnapshotWriter.write(accounts: accounts, lastAccountID: lastAccountID)
        FileProviderDomains.sync(accounts: accounts)
    }

    private func reloadFromDisk() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var snapshot: Snapshot?
        if let data = try? Data(contentsOf: fileURL) {
            snapshot = try? decoder.decode(Snapshot.self, from: data)
        }
        if snapshot == nil, let backup = UserDefaults.standard.data(forKey: backupKey) {
            snapshot = try? decoder.decode(Snapshot.self, from: backup)
        }
        guard let snapshot else { return }
        accounts = snapshot.accounts
        lastAccountID = snapshot.lastAccountID
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = Snapshot(accounts: accounts, lastAccountID: lastAccountID)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(data, forKey: backupKey)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        ShareSnapshotWriter.write(accounts: accounts, lastAccountID: lastAccountID)
        FileProviderDomains.sync(accounts: accounts)
    }

    @discardableResult
    func add(_ account: Account, token: String) -> Account {
        reloadFromDisk()
        // Keep the account record even if the Keychain write fails; the user can
        // sign in again and the record remains available for quick switching.
        _ = CredentialStore.save(token, for: account.id)
        var stored = account
        stored.lastUsed = Date()
        accounts.removeAll { $0.id == stored.id }
        accounts.insert(stored, at: 0)
        lastAccountID = stored.id
        persist()
        return stored
    }

    func update(_ account: Account) {
        reloadFromDisk()
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        persist()
    }

    func updateProfile(id: String, displayName: String?, email: String?) {
        reloadFromDisk()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        if let displayName, !displayName.isEmpty { accounts[index].displayName = displayName }
        if let email, !email.isEmpty { accounts[index].email = email }
        accounts[index].lastUsed = Date()
        persist()
    }

    func markUsed(id: String) {
        reloadFromDisk()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].lastUsed = Date()
        accounts.insert(accounts.remove(at: index), at: 0)
        lastAccountID = id
        persist()
    }

    func remove(_ account: Account) {
        reloadFromDisk()
        CredentialStore.delete(for: account.id)
        RepoSecretStore.deleteAll(accountID: account.id)
        accounts.removeAll { $0.id == account.id }
        if lastAccountID == account.id { lastAccountID = accounts.first?.id }
        persist()
    }

    func signOut(_ account: Account) {
        reloadFromDisk()
        CredentialStore.delete(for: account.id)
        RepoSecretStore.deleteAll(accountID: account.id)
        if lastAccountID == account.id { lastAccountID = accounts.first?.id }
        persist()
    }

    func token(for account: Account) -> String? {
        CredentialStore.token(for: account.id)
    }
}
