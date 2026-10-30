import Foundation

struct Account: Identifiable, Codable, Hashable, Sendable {
    let serverURL: URL
    let username: String
    var displayName: String?
    var email: String?
    var lastUsed: Date
    var allowUntrustedCertificate: Bool
    var isSSO: Bool

    var id: String { Self.identifier(serverURL: serverURL, username: username) }

    init(serverURL: URL, username: String, displayName: String? = nil, email: String? = nil,
         lastUsed: Date = Date(), allowUntrustedCertificate: Bool = false, isSSO: Bool = false) {
        self.serverURL = serverURL
        self.username = username
        self.displayName = displayName
        self.email = email
        self.lastUsed = lastUsed
        self.allowUntrustedCertificate = allowUntrustedCertificate
        self.isSSO = isSSO
    }

    private enum CodingKeys: String, CodingKey {
        case serverURL, username, displayName, email, lastUsed, allowUntrustedCertificate, isSSO
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverURL = try container.decode(URL.self, forKey: .serverURL)
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        lastUsed = try container.decodeIfPresent(Date.self, forKey: .lastUsed) ?? Date()
        allowUntrustedCertificate = try container.decodeIfPresent(Bool.self, forKey: .allowUntrustedCertificate) ?? false
        isSSO = try container.decodeIfPresent(Bool.self, forKey: .isSSO) ?? false
    }

    var serverAddress: String {
        var value = serverURL.absoluteString
        if value.hasSuffix("/") { value.removeLast() }
        return value
    }

    var displayLabel: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, !Self.isInternalAddress(name) { return name }
        if isSSO || Self.isInternalAddress(username) {
            let local = username.split(separator: "@").first.map(String.init) ?? username
            return local.isEmpty ? username : local
        }
        return name.isEmpty ? username : name
    }

    var accountSubtitle: String {
        if isSSO { return String(localized: "Single Sign-On") }
        if let email, !email.isEmpty, !Self.isInternalAddress(email) { return email }
        if Self.isInternalAddress(username) {
            let local = username.split(separator: "@").first.map(String.init) ?? username
            return local
        }
        return username
    }

    static func isInternalAddress(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.contains("@auth.local")
            || lower.contains("@seafile-sso")
            || lower.hasSuffix("@seafile.local")
            || lower.hasSuffix("@seafile-sso.local")
    }

    var initials: String {
        let source = displayLabel
        let parts = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first {
            return "\(first)\(last)".uppercased()
        }
        return String(source.prefix(2)).uppercased()
    }

    static func identifier(serverURL: URL, username: String) -> String {
        "\(serverURL.absoluteString)|\(username.lowercased())"
    }
}

struct AccountInfo: Sendable {
    var email: String?
    var name: String?
    var totalQuota: Int64?
    var usage: Int64?
    var department: String?

    init(json: [String: Any]) {
        email = json["email"] as? String
        name = json["name"] as? String
        totalQuota = (json["total"] as? NSNumber)?.int64Value
        usage = (json["usage"] as? NSNumber)?.int64Value
        department = json["department"] as? String
    }

    var usageFraction: Double? {
        guard let total = totalQuota, total > 0, let usage else { return nil }
        return min(1, max(0, Double(usage) / Double(total)))
    }
}
