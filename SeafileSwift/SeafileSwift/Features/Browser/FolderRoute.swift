import Foundation

struct FolderRoute: Hashable {
    let repo: Repository
    let path: String

    var title: String {
        path == "/" ? repo.name : (path as NSString).lastPathComponent
    }
}

struct PreviewTarget: Identifiable, Hashable {
    let repo: Repository
    let path: String
    let name: String
    let size: Int64
    let modified: Date?
    let version: String

    var id: String { "\(repo.id)|\(path)|\(version)" }

    init(repo: Repository, path: String, name: String, size: Int64 = 0, modified: Date? = nil, version: String = "") {
        self.repo = repo
        self.path = path
        self.name = name
        self.size = size
        self.modified = modified
        self.version = version
    }

    init(repo: Repository, dirent: Dirent) {
        self.init(repo: repo,
                  path: dirent.path,
                  name: dirent.name,
                  size: dirent.size,
                  modified: dirent.modified,
                  version: dirent.oid ?? String(dirent.modified?.timeIntervalSince1970 ?? 0))
    }

    init(starred: StarredItem) {
        self.init(repo: Repository(id: starred.repoID, name: starred.repoName ?? "", encrypted: starred.encrypted),
                  path: starred.path,
                  name: starred.name,
                  modified: starred.modified,
                  version: String(starred.modified?.timeIntervalSince1970 ?? 0))
    }

    init(searchResult: SearchResult, repo: Repository) {
        self.init(repo: repo,
                  path: searchResult.path,
                  name: searchResult.name,
                  size: searchResult.size,
                  modified: searchResult.modified,
                  version: String(searchResult.modified?.timeIntervalSince1970 ?? 0))
    }
}
