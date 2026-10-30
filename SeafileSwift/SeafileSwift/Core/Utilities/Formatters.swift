import Foundation

enum ServerDateParser {
    private static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let legacy: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        return formatter
    }()

    static func parse(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            let raw = number.doubleValue
            guard raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw)
        case let string as String:
            guard !string.isEmpty else { return nil }
            if let date = withFractional.date(from: string) { return date }
            if let date = plain.date(from: string) { return date }
            if let date = legacy.date(from: string) { return date }
            if let seconds = Double(string) { return Date(timeIntervalSince1970: seconds) }
            return nil
        default:
            return nil
        }
    }
}

enum NaturalSort {
    private static let locale = Locale(identifier: "zh-Hans-CN")

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .numeric], range: nil, locale: locale)
    }

    static func lessThan(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }
}

enum DisplayFormat {
    static func fileSize(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func quota(used: Int64?, total: Int64?) -> String {
        let usedText = fileSize(used ?? 0)
        guard let total, total > 0 else { return usedText }
        return "\(usedText) / \(fileSize(total))"
    }
}

enum FileNames {
    static func sanitized(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:")
        return name.components(separatedBy: invalid).joined(separator: "_")
    }

    static func unique(in directory: URL, name: String) -> URL {
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }
}
