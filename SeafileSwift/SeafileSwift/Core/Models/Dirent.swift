import Foundation

struct Dirent: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case file
        case directory
    }

    let kind: Kind
    let name: String
    let path: String
    let oid: String?
    let size: Int64
    let modified: Date?
    let permission: String?
    let thumbnailPath: String?

    var id: String { path }
    var isDirectory: Bool { kind == .directory }
    var isReadOnly: Bool { permission?.lowercased() == "r" }
    var version: String { oid ?? String(modified?.timeIntervalSince1970 ?? 0) }

    init?(json: [String: Any], parentPath: String) {
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        let rawType = json["type"] as? String
        kind = rawType == "dir" ? .directory : .file
        self.name = name
        path = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        oid = json["id"] as? String
        size = (json["size"] as? NSNumber)?.int64Value ?? 0
        modified = (json["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            ?? ServerDateParser.parse(json["last_modified"])
        permission = json["permission"] as? String
        thumbnailPath = json["encoded_thumbnail_src"] as? String
    }

    init(kind: Kind, name: String, path: String, oid: String? = nil, size: Int64 = 0,
         modified: Date? = nil, permission: String? = nil, thumbnailPath: String? = nil) {
        self.kind = kind
        self.name = name
        self.path = path
        self.oid = oid
        self.size = size
        self.modified = modified
        self.permission = permission
        self.thumbnailPath = thumbnailPath
    }
}

enum DirentSortKey: String, CaseIterable, Identifiable {
    case name
    case modified
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Date Modified"
        case .size: return "Size"
        }
    }

    var symbol: String {
        switch self {
        case .name: return "textformat.abc"
        case .modified: return "calendar"
        case .size: return "arrow.up.arrow.down.square"
        }
    }
}

extension Array where Element == Dirent {
    func sorted(by key: DirentSortKey, ascending: Bool) -> [Dirent] {
        sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            let result: ComparisonResult
            switch key {
            case .name:
                result = NaturalSort.compare(lhs.name, rhs.name)
            case .modified:
                let l = lhs.modified?.timeIntervalSince1970 ?? 0
                let r = rhs.modified?.timeIntervalSince1970 ?? 0
                result = l == r ? NaturalSort.compare(lhs.name, rhs.name) : (l < r ? .orderedAscending : .orderedDescending)
            case .size:
                if lhs.size == rhs.size {
                    result = NaturalSort.compare(lhs.name, rhs.name)
                } else {
                    result = lhs.size < rhs.size ? .orderedAscending : .orderedDescending
                }
            }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
    }
}
