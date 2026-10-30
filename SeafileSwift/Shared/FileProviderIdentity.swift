import Foundation

enum FileProviderDomainID {
    static let prefix = "seafile.account."

    static func identifier(forAccountID id: String) -> String {
        prefix + base64(id)
    }

    static func accountID(from identifier: String) -> String? {
        guard identifier.hasPrefix(prefix) else { return nil }
        return decode(String(identifier.dropFirst(prefix.count)))
    }

    private static func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ value: String) -> String? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
