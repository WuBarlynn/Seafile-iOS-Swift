import Foundation

struct ActivityDetail: Identifiable, Hashable, Sendable {
    let id: String
    let opType: String?
    let objType: String?
    let name: String?
    let path: String?
    let oldPath: String?
    let count: Int

    init?(json: [String: Any], index: Int) {
        guard let dict = json as? [String: Any] else { return nil }
        objType = dict["obj_type"] as? String
        opType = dict["op_type"] as? String
        name = dict["name"] as? String
        path = dict["path"] as? String
        oldPath = dict["old_path"] as? String
        count = (dict["count"] as? NSNumber)?.intValue ?? 1
        id = "\(index)-\(name ?? path ?? objType ?? "")"
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let path { return (path as NSString).lastPathComponent }
        return objType ?? ""
    }
}

struct ActivityEvent: Identifiable, Hashable, Sendable {
    let id: String
    let authorName: String?
    let avatarURL: URL?
    let repoID: String?
    let repoName: String?
    let time: Date?
    let opType: String?
    let objType: String?
    let name: String?
    let path: String?
    let oldName: String?
    let count: Int
    let days: Int?
    let details: [ActivityDetail]

    init?(json: [String: Any], index: Int) {
        guard let dict = json as? [String: Any] else { return nil }
        authorName = dict["author_name"] as? String
        avatarURL = (dict["avatar_url"] as? String).flatMap(URL.init(string:))
        repoID = dict["repo_id"] as? String
        repoName = dict["repo_name"] as? String
        time = ServerDateParser.parse(dict["time"])
        opType = dict["op_type"] as? String
        var objectType = dict["obj_type"] as? String
        name = dict["name"] as? String
        path = dict["path"] as? String
        oldName = dict["old_name"] as? String
        count = (dict["count"] as? NSNumber)?.intValue ?? 0
        days = (dict["days"] as? NSNumber)?.intValue
        if let name, name.hasSuffix("(draft).md") { objectType = "draft" }
        objType = objectType
        let rawDetails = dict["details"] as? [Any] ?? []
        details = rawDetails.enumerated().compactMap { ActivityDetail(json: $0.element as? [String: Any] ?? [:], index: $0.offset) }
        id = "\(index)-\(time?.timeIntervalSince1970 ?? 0)-\(authorName ?? "")-\(name ?? "")"
    }

    var summary: String {
        ActivityEvent.operationTitle(opType: opType, objType: objType, count: count, days: days)
    }

    var detailText: String? {
        if opType == "rename" {
            let old = oldName ?? ""
            let new = name ?? ""
            if !old.isEmpty || !new.isEmpty { return "\(old) → \(new)" }
        }
        if details.count > 1 {
            return details.prefix(3).map(\.displayName).joined(separator: ", ") + (details.count > 3 ? "…" : "")
        }
        if let name, !name.isEmpty { return name }
        if let repoName { return repoName }
        return nil
    }

    static func operationTitle(opType: String?, objType: String?, count: Int, days: Int?) -> String {
        guard let opType, let objType else { return "" }
        if opType == "clean-up-trash" {
            if let days, days > 0 {
                return String(format: String(localized: "Removed items older than %lld days from trash"), days)
            }
            return String(localized: "Removed all items from trash")
        }
        switch objType {
        case "repo":
            switch opType {
            case "create": return String(localized: "Created library")
            case "rename": return String(localized: "Renamed library")
            case "delete": return String(localized: "Deleted library")
            case "restore", "recover": return String(localized: "Restored library")
            case "edit": return String(localized: "Updated library")
            default: return ""
            }
        case "dir":
            switch opType {
            case "create", "batch_create":
                return count > 1
                    ? String(format: String(localized: "Created %lld folders"), count)
                    : String(localized: "Created folder")
            case "rename": return String(localized: "Renamed folder")
            case "delete", "batch_delete":
                return count > 1
                    ? String(format: String(localized: "Deleted %lld folders"), count)
                    : String(localized: "Deleted folder")
            case "restore", "recover": return String(localized: "Restored folder")
            case "move": return String(localized: "Moved folder")
            case "edit": return String(localized: "Updated folder")
            default: return ""
            }
        case "file":
            switch opType {
            case "create", "batch_create":
                return count > 1
                    ? String(format: String(localized: "Created %lld files"), count)
                    : String(localized: "Created file")
            case "rename": return String(localized: "Renamed file")
            case "delete", "batch_delete":
                return count > 1
                    ? String(format: String(localized: "Deleted %lld files"), count)
                    : String(localized: "Deleted file")
            case "restore", "recover": return String(localized: "Restored file")
            case "move": return String(localized: "Moved file")
            case "update", "edit": return String(localized: "Updated file")
            default: return ""
            }
        case "draft":
            switch opType {
            case "create": return String(localized: "Created draft")
            case "rename": return String(localized: "Renamed draft")
            case "delete": return String(localized: "Deleted draft")
            case "update", "edit": return String(localized: "Updated draft")
            case "publish": return String(localized: "Published draft")
            default: return ""
            }
        case "files":
            return opType == "create" ? String(localized: "Created files") : ""
        default:
            return ""
        }
    }
}
