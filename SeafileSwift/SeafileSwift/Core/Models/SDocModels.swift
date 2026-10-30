import Foundation

struct SDocPageOptions: Identifiable, Equatable {
    let seadocServerURL: String
    let seadocAccessToken: String
    let docUUID: String
    let latestContributor: String

    var id: String { docUUID }

    var canUse: Bool {
        !seadocServerURL.isEmpty && !seadocAccessToken.isEmpty && !docUUID.isEmpty
    }

    var seahubBaseURL: URL? {
        var text = seadocServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix("/seadoc") { text = String(text.dropLast("/seadoc".count)) }
        if !text.hasSuffix("/seahub") { text += "/seahub" }
        return URL(string: text)
    }

    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        let server = (dict["seadocServerUrl"] as? String)
            ?? (dict["seadocServerURL"] as? String)
            ?? (dict["seadoc_server_url"] as? String)
            ?? ""
        let token = (dict["seadocAccessToken"] as? String)
            ?? (dict["seadoc_access_token"] as? String)
            ?? ""
        let uuid = (dict["docUuid"] as? String)
            ?? (dict["docUUID"] as? String)
            ?? (dict["doc_uuid"] as? String)
            ?? ""
        guard !server.isEmpty, !token.isEmpty, !uuid.isEmpty else { return nil }
        self.seadocServerURL = server
        self.seadocAccessToken = token
        self.docUUID = uuid
        self.latestContributor = dict["latestContributor"] as? String ?? ""
    }
}

struct SDocOutlineItem: Identifiable, Equatable {
    let id: Int
    let type: String
    let text: String
    let payload: [String: Any]

    var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return type.isEmpty ? String(id + 1) : type
    }

    var indentLevel: Int {
        switch type {
        case "header2": return 1
        case "header3": return 2
        default: return 0
        }
    }

    var payloadWithText: [String: Any] {
        var value = payload
        if (value["text"] as? String) != text {
            value["text"] = text
        }
        return value
    }

    static func == (lhs: SDocOutlineItem, rhs: SDocOutlineItem) -> Bool {
        lhs.id == rhs.id && lhs.type == rhs.type && lhs.text == rhs.text
    }

    static func parse(_ json: Any) -> [SDocOutlineItem] {
        guard let array = json as? [Any] else { return [] }
        let allowed: Set<String> = ["header1", "header2", "header3"]
        var items: [SDocOutlineItem] = []
        for (index, element) in array.enumerated() {
            guard let dict = element as? [String: Any] else { continue }
            let type = dict["type"] as? String ?? ""
            guard allowed.contains(type) else { continue }
            let rawChildren = dict["children"] as? [Any] ?? []
            var text = dict["text"] as? String ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard !rawChildren.isEmpty else { continue }
                text = rawChildren.compactMap { child -> String? in
                    guard let child = child as? [String: Any],
                          let value = child["text"] as? String else { return nil }
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }.joined()
            }
            items.append(SDocOutlineItem(id: index, type: type, text: text, payload: dict))
        }
        return items
    }
}

enum SDocCommentContent: Equatable {
    case text(String)
    case image(String)
}

struct SDocUser: Identifiable, Equatable {
    let name: String
    let email: String
    let avatarURL: String?

    var id: String {
        let key = email.lowercased()
        return key.isEmpty ? "name:\(name.lowercased())" : key
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? email : trimmed
    }

    init?(json: Any) {
        guard let dict = json as? [String: Any] else { return nil }
        let name = Self.string(dict, keys: ["name", "display_name", "username"])
        let email = Self.string(dict, keys: ["email", "contact_email", "user_email", "contactEmail"])
        guard !name.isEmpty || !email.isEmpty else { return nil }
        self.name = name
        self.email = email
        let avatar = Self.string(dict, keys: ["avatar_url", "avatarUrl"])
        avatarURL = avatar.isEmpty ? nil : avatar
    }

    static func list(from object: Any, keys: [String]) -> [SDocUser] {
        let raw: [Any]
        if let array = object as? [Any] {
            raw = array
        } else if let dict = object as? [String: Any] {
            raw = keys.lazy.compactMap { dict[$0] as? [Any] }.first ?? []
        } else {
            raw = []
        }
        return raw.compactMap { SDocUser(json: $0) }
    }

    private static func string(_ dict: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }
}

struct SDocComment: Identifiable, Equatable {
    let id: Int64
    let author: String
    let avatarURL: String?
    let createdAt: Date?
    let fallbackTime: String
    let content: [SDocCommentContent]
    var isResolved: Bool

    var displayTime: String {
        if let createdAt {
            return createdAt.formatted(date: .numeric, time: .shortened)
        }
        return fallbackTime
    }

    static func parse(_ json: [String: Any]) -> SDocComment? {
        let rawID = json["id"] as? NSNumber
        let id = rawID?.int64Value ?? Int64(json["id"] as? String ?? "") ?? 0
        guard id > 0 else { return nil }
        let time = json["created_at"] as? String ?? ""
        return SDocComment(
            id: id,
            author: json["user_name"] as? String ?? "",
            avatarURL: (json["avatar_url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            createdAt: parseDate(time),
            fallbackTime: time,
            content: parseContent(json["comment"] as? String ?? ""),
            isResolved: (json["resolved"] as? NSNumber)?.boolValue ?? (json["resolved"] as? Bool) ?? false
        )
    }

    static func parseContent(_ markdown: String) -> [SDocCommentContent] {
        guard !markdown.isEmpty else { return [] }
        let markdownPattern = #"!\[\]\(([^)]+)\)"#
        let htmlPattern = #"<img[^>]*src="([^"]+)"[^>]*>"#
        let markdownRegex = try? NSRegularExpression(pattern: markdownPattern)
        let htmlRegex = try? NSRegularExpression(pattern: htmlPattern, options: [.caseInsensitive])

        var items: [SDocCommentContent] = []
        let paragraphs = markdown.components(separatedBy: "\n\n")
        for paragraph in paragraphs where !paragraph.isEmpty {
            let range = NSRange(paragraph.startIndex..<paragraph.endIndex, in: paragraph)
            var matches: [NSTextCheckingResult] = []
            if let markdownRegex {
                matches.append(contentsOf: markdownRegex.matches(in: paragraph, range: range))
            }
            if let htmlRegex {
                matches.append(contentsOf: htmlRegex.matches(in: paragraph, range: range))
            }
            matches.sort { $0.range.location < $1.range.location }

            if matches.isEmpty {
                appendText(paragraph, to: &items)
                continue
            }

            var cursor = 0
            for match in matches {
                guard match.range.location >= cursor else { continue }
                if match.range.location > cursor,
                   let textRange = Range(NSRange(location: cursor, length: match.range.location - cursor), in: paragraph) {
                    appendText(String(paragraph[textRange]), to: &items)
                }
                if match.numberOfRanges > 1,
                   let urlRange = Range(match.range(at: 1), in: paragraph) {
                    let url = String(paragraph[urlRange])
                    if !url.isEmpty { items.append(.image(url)) }
                }
                cursor = match.range.location + match.range.length
            }
            if cursor < (paragraph as NSString).length,
               let textRange = Range(NSRange(location: cursor, length: (paragraph as NSString).length - cursor), in: paragraph) {
                appendText(String(paragraph[textRange]), to: &items)
            }
        }
        return items
    }

    private static func appendText(_ text: String, to items: inout [SDocCommentContent]) {
        let value = text.trimmingCharacters(in: .newlines)
        guard !value.isEmpty else { return }
        if case .text(let existing) = items.last {
            items[items.count - 1] = .text(existing + "\n" + value)
        } else {
            items.append(.text(value))
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        if let date = standard.date(from: value) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"] {
            fallback.dateFormat = format
            if let date = fallback.date(from: value) { return date }
        }
        return nil
    }
}
