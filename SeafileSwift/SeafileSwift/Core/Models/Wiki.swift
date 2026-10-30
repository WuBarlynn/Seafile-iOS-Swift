import Foundation

struct WikiInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: String
    let owner: String?
    let ownerNickname: String?
    let icon: String?
    let color: String?
    let permission: String?
    let publicURL: String?
    let slug: String?
    let repoID: String?
    let updatedAt: Date?
    let isPublished: Bool
    let groupName: String?

    var isLegacy: Bool { type == "old" }

    var canEdit: Bool {
        guard !isLegacy, !id.isEmpty else { return false }
        let value = permission?.lowercased()
        return value == "rw" || value == "admin"
    }

    var displayOwner: String? {
        if let ownerNickname, !ownerNickname.isEmpty { return ownerNickname }
        if let owner, !owner.isEmpty { return owner }
        return nil
    }

    init?(json: [String: Any], legacy: Bool, groupName: String? = nil) {
        guard let name = Self.string(json["name"]), !name.isEmpty else { return nil }
        let rawID = Self.string(json["id"]) ?? ""
        if !legacy && rawID.isEmpty { return nil }
        id = rawID
        self.name = name
        type = legacy ? "old" : (Self.string(json["type"]) ?? "mine")
        owner = Self.string(json["owner"])
        ownerNickname = Self.string(json["owner_nickname"])
        icon = Self.string(json["icon"])
        color = Self.string(json["color"])
        permission = Self.string(json["permission"])
        publicURL = Self.string(json["link"]) ?? Self.string(json["public_url"])
        slug = Self.string(json["slug"])
        repoID = Self.string(json["repo_id"])
        updatedAt = ServerDateParser.parse(json["updated_at"]) ?? ServerDateParser.parse(json["created_at"])
        isPublished = legacy || (json["is_published"] as? NSNumber)?.boolValue == true
        self.groupName = groupName
    }

    func webURL(baseURL: URL) -> URL? {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        if isLegacy {
            guard let slug, !slug.isEmpty,
                  let escaped = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
            return URL(string: "\(base)/published/\(escaped)")
        }
        guard !id.isEmpty,
              let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(base)/wikis/\(escaped)/")
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value.isEmpty ? nil : value
        case let value as NSNumber:
            return value.stringValue
        case let value as NSDictionary:
            return nil
        case let value as NSArray:
            return nil
        default:
            return nil
        }
    }
}

struct WikiSection: Identifiable, Hashable {
    let id: String
    let title: String
    let wikis: [WikiInfo]
}

enum WikiSectionBuilder {
    static func sections(mine: [WikiInfo], shared: [WikiInfo],
                         groups: [String: [WikiInfo]], legacy: [WikiInfo]) -> [WikiSection] {
        var result: [WikiSection] = []
        func append(_ id: String, _ title: String, _ items: [WikiInfo]) {
            guard !items.isEmpty else { return }
            result.append(WikiSection(id: id,
                                      title: title,
                                      wikis: items.sorted { NaturalSort.lessThan($0.name, $1.name) }))
        }
        append("wiki-mine", "My Wikis", mine)
        append("wiki-shared", "Shared with Me", shared)
        for name in groups.keys.sorted(by: NaturalSort.lessThan) {
            append("wiki-group-\(name)", name, groups[name] ?? [])
        }
        append("wiki-legacy", "Legacy Wikis", legacy)
        return result
    }
}
