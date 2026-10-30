import Foundation
import Security

enum CredentialStore {
    private static let service = "com.seafile.seafileSwift.credentials"

    static func token(for accountID: String) -> String? {
        if let token = keychainToken(for: accountID) { return token }
        return fallbackTokens()[accountID]
    }

    @discardableResult
    static func save(_ token: String, for accountID: String) -> Bool {
        let savedInKeychain = keychainSave(token, for: accountID)
        if savedInKeychain {
            var tokens = fallbackTokens()
            if tokens.removeValue(forKey: accountID) != nil { writeFallback(tokens) }
            return true
        }
        // Unsigned simulator builds have no Keychain entitlement. Keep the
        // token in the app's protected container so the session still survives
        // relaunches; signed production builds use the Keychain path above.
        var tokens = fallbackTokens()
        tokens[accountID] = token
        writeFallback(tokens)
        return fallbackTokens()[accountID] != nil
    }

    static func delete(for accountID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        SecItemDelete(query as CFDictionary)
        var tokens = fallbackTokens()
        if tokens.removeValue(forKey: accountID) != nil { writeFallback(tokens) }
    }

    private static func keychainToken(for accountID: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainSave(_ token: String, for accountID: String) -> Bool {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecSuccess
        }
        var insert = query
        insert.merge(attributes) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    private static var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SeafileSwift", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("credentials.json")
    }

    private static func fallbackTokens() -> [String: String] {
        guard let data = try? Data(contentsOf: fallbackURL),
              let tokens = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return tokens
    }

    private static func writeFallback(_ tokens: [String: String]) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let url = fallbackURL
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([
            .posixPermissions: 0o600,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }
}
