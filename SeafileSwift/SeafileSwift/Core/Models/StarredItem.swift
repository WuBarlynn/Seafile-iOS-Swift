import Foundation

struct StarredItem: Identifiable, Hashable, Sendable {
    let repoID: String
    let repoName: String?
    let path: String
    let name: String
    let isDirectory: Bool
    let encrypted: Bool
    let modified: Date?
    let thumbnailPath: String?

    var id: String { "\(repoID)|\(path)" }

    init?(json: [String: Any]) {
        guard let repoID = json["repo_id"] as? String,
              let path = json["path"] as? String else { return nil }
        self.repoID = repoID
        repoName = json["repo_name"] as? String
        self.path = path
        name = (json["obj_name"] as? String) ?? (path as NSString).lastPathComponent
        isDirectory = (json["is_dir"] as? NSNumber)?.boolValue ?? false
        encrypted = (json["repo_encrypted"] as? NSNumber)?.boolValue ?? false
        modified = ServerDateParser.parse(json["mtime"])
        thumbnailPath = json["encoded_thumbnail_src"] as? String
    }

    var repository: Repository? {
        guard let repoName else { return nil }
        return Repository(id: repoID, name: repoName, encrypted: encrypted)
    }
}
