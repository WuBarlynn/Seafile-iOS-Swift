import Foundation

enum ShareGroup {
    static let identifier = "group.com.seafile.seafileSwift"
}

struct SharedAccount: Codable, Identifiable, Hashable {
    let id: String
    let serverURL: String
    let username: String
    var displayName: String?
    var email: String?
    var token: String
    var allowUntrustedCertificate: Bool
    var isSSO: Bool
    var lastUsed: Date

    var label: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return username
    }

    var baseURL: URL? { URL(string: serverURL) }
}

struct SharedAccountsFile: Codable {
    var accounts: [SharedAccount] = []
    var lastAccountID: String?
}

enum ShareSessionStore {
    private static var directoryURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareGroup.identifier)
    }

    private static var fileURL: URL? {
        directoryURL?.appendingPathComponent("share-accounts.json")
    }

    static func load() -> SharedAccountsFile {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else {
            return SharedAccountsFile()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(SharedAccountsFile.self, from: data)) ?? SharedAccountsFile()
    }

    static func save(_ value: SharedAccountsFile) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([
            .posixPermissions: 0o600,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ], ofItemAtPath: fileURL.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(values)
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: ShareGroup.identifier)
    }
}
