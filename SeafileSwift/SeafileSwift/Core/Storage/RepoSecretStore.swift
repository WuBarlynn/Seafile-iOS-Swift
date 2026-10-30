import Foundation
import Security

enum RepoSecretStore {
    private static let service = "com.seafile.seafileSwift.repoSecrets"

    private static func accountKey(accountID: String, repoID: String) -> String {
        "\(accountID)|\(repoID)"
    }

    static func password(accountID: String, repoID: String) -> String? {
        if let value = keychainPassword(accountID: accountID, repoID: repoID) { return value }
        return fallbackSecrets()[accountKey(accountID: accountID, repoID: repoID)]
    }

    private static func keychainPassword(accountID: String, repoID: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(accountID: accountID, repoID: repoID),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(password: String, accountID: String, repoID: String) {
        let key = accountKey(accountID: accountID, repoID: repoID)
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let saved: Bool
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            saved = SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        } else {
            var insert = query
            insert.merge(attributes) { _, new in new }
            saved = SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }

        var secrets = fallbackSecrets()
        if saved {
            if secrets.removeValue(forKey: key) != nil { writeFallback(secrets) }
        } else {
            // The unsigned simulator build has no Keychain entitlement.
            secrets[key] = password
            writeFallback(secrets)
        }
    }

    static func delete(accountID: String, repoID: String) {
        let key = accountKey(accountID: accountID, repoID: repoID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var secrets = fallbackSecrets()
        if secrets.removeValue(forKey: key) != nil { writeFallback(secrets) }
    }

    static func deleteAll(accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String,
                      account.hasPrefix("\(accountID)|") else { continue }
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }
        var secrets = fallbackSecrets()
        let prefix = "\(accountID)|"
        secrets = secrets.filter { !$0.key.hasPrefix(prefix) }
        writeFallback(secrets)
    }

    static func deleteAllAccounts() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            for item in items {
                guard let account = item[kSecAttrAccount as String] as? String else { continue }
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account
                ]
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }
        writeFallback([:])
    }

    private static var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SeafileSwift", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("repoSecrets.json")
    }

    private static func fallbackSecrets() -> [String: String] {
        guard let data = try? Data(contentsOf: fallbackURL),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return values
    }

    private static func writeFallback(_ values: [String: String]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        let url = fallbackURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([
            .posixPermissions: 0o600,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ], ofItemAtPath: url.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(resourceValues)
    }
}
