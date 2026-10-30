import Foundation

struct Repository: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mine
        case shared
        case group
        case `public`
        case other

        init(raw: String?) {
            switch raw?.lowercased() {
            case "mine": self = .mine
            case "shared": self = .shared
            case "group": self = .group
            case "public": self = .public
            default: self = .other
            }
        }
    }

    let id: String
    let name: String
    let owner: String?
    let ownerName: String?
    let kind: Kind
    let permission: String?
    let size: Int64
    let modified: Date?
    let encrypted: Bool
    let groupName: String?
    let groupId: Int?

    var isReadOnly: Bool { permission?.lowercased() == "r" }
    var groupIDValue: Int? { groupId }

    init?(json: [String: Any]) {
        guard let repoID = json["repo_id"] as? String,
              let repoName = json["repo_name"] as? String else { return nil }
        id = repoID
        name = repoName
        owner = json["owner_email"] as? String
        ownerName = json["owner_name"] as? String
        kind = Kind(raw: json["type"] as? String)
        permission = json["permission"] as? String
        size = (json["size"] as? NSNumber)?.int64Value ?? 0
        modified = ServerDateParser.parse(json["last_modified"])
            ?? (json["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        encrypted = (json["encrypted"] as? NSNumber)?.boolValue ?? false
        groupName = json["group_name"] as? String
        groupId = (json["group_id"] as? NSNumber)?.intValue
    }

    init(id: String, name: String, owner: String? = nil, ownerName: String? = nil,
         kind: Kind = .mine, permission: String? = nil, size: Int64 = 0, modified: Date? = nil,
         encrypted: Bool = false, groupName: String? = nil, groupId: Int? = nil) {
        self.id = id
        self.name = name
        self.owner = owner
        self.ownerName = ownerName
        self.kind = kind
        self.permission = permission
        self.size = size
        self.modified = modified
        self.encrypted = encrypted
        self.groupName = groupName
        self.groupId = groupId
    }
}

struct RepositorySection: Identifiable, Hashable {
    let id: String
    let title: String
    let repositories: [Repository]
}
