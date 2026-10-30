import Foundation

struct SearchResult: Identifiable, Hashable, Sendable {
    let repoID: String
    var repoName: String?
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { "\(repoID)|\(path)" }

    init?(json: [String: Any], repoName: String?) {
        guard let repoID = json["repo_id"] as? String,
              let fullPath = json["fullpath"] as? String else { return nil }
        self.repoID = repoID
        self.repoName = repoName
        path = fullPath
        name = (json["name"] as? String) ?? (fullPath as NSString).lastPathComponent
        isDirectory = (json["is_dir"] as? NSNumber)?.boolValue ?? false
        size = (json["size"] as? NSNumber)?.int64Value ?? 0
        modified = (json["mtime"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    var parentPath: String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }
}
