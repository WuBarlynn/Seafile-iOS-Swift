import Foundation

struct ServerInfo: Sendable {
    var version: String?
    var features: [String]

    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        version = dict["version"] as? String
        features = (dict["features"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    init(version: String? = nil, features: [String] = []) {
        self.version = version
        self.features = features
    }

    func has(_ feature: String) -> Bool { features.contains(feature) }

    var isPro: Bool { has("seafile-pro") }
    var isSearchEnabled: Bool { isPro && has("file-search") }
    var isActivityEnabled: Bool { isPro }
    var isWikiSupported: Bool { has("wiki") }
    var supportsNewActivitiesAPI: Bool { ServerVersion.atLeast(version, "7.0.0") }
    var supportsNewThumbnailAPI: Bool { ServerVersion.atLeast(version, "14.0.0") }
}

enum ServerVersion {
    static func atLeast(_ version: String?, _ minimum: String) -> Bool {
        guard let version, !version.isEmpty else { return false }
        let left = version.split(separator: ".").map { digits(String($0)) }
        let right = minimum.split(separator: ".").map { digits(String($0)) }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? Int(left[index]) ?? 0 : 0
            let rhs = index < right.count ? Int(right[index]) ?? 0 : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private static func digits(_ value: String) -> String {
        value.filter(\.isNumber)
    }
}
