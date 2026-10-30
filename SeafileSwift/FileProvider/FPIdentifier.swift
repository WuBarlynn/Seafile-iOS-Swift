import FileProvider
import Foundation

struct FPIdentifier: Hashable {
    let repoID: String
    let path: String

    static func decode(_ identifier: NSFileProviderItemIdentifier) -> FPIdentifier? {
        let raw = identifier.rawValue
        guard raw.hasPrefix("sf_") else { return nil }
        var text = String(raw.dropFirst(3))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let value = String(data: data, encoding: .utf8),
              let separator = value.firstIndex(of: "\u{0}") else {
            return nil
        }
        let repoID = String(value[..<separator])
        let path = String(value[value.index(after: separator)...])
        guard !repoID.isEmpty else { return nil }
        return FPIdentifier(repoID: repoID, path: path)
    }

    static func identifier(repoID: String, path: String) -> NSFileProviderItemIdentifier {
        let value = repoID + "\u{0}" + path
        let encoded = Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NSFileProviderItemIdentifier("sf_" + encoded)
    }

    static func repoIdentifier(_ repoID: String) -> NSFileProviderItemIdentifier {
        identifier(repoID: repoID, path: "")
    }

    static func parentPath(_ path: String) -> String {
        guard path != "/" else { return "/" }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
