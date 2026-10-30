import CryptoKit
import Foundation

actor OfflineCache {
    private let root: URL
    private let fileManager = FileManager.default

    init(accountID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SeafileSwift", isDirectory: true)
            .appendingPathComponent("Offline", isDirectory: true)
        root = base.appendingPathComponent(Self.hash(accountID), isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    func loadLibraries() -> [Repository]? {
        decode([Repository].self, from: root.appendingPathComponent("libraries.json"))
    }

    func saveLibraries(_ repositories: [Repository]) {
        encode(repositories, to: root.appendingPathComponent("libraries.json"))
    }

    func loadDirents(repoID: String, path: String) -> [Dirent]? {
        decode([Dirent].self, from: directoryURL(repoID: repoID, path: path))
    }

    func saveDirents(_ dirents: [Dirent], repoID: String, path: String) {
        encode(dirents, to: directoryURL(repoID: repoID, path: path))
    }

    func loadEncryptionInfo(repoID: String) -> RepoEncryptionInfo? {
        decode(RepoEncryptionInfo.self, from: encryptionURL(repoID: repoID))
    }

    func saveEncryptionInfo(_ info: RepoEncryptionInfo, repoID: String) {
        encode(info, to: encryptionURL(repoID: repoID))
    }

    func clear() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func directoryURL(repoID: String, path: String) -> URL {
        root.appendingPathComponent("dir-\(Self.hash("\(repoID)|\(path)"))")
            .appendingPathExtension("json")
    }

    private func encryptionURL(repoID: String) -> URL {
        root.appendingPathComponent("enc-\(Self.hash(repoID))")
            .appendingPathExtension("json")
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
