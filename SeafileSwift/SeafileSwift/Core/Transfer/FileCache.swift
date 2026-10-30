import CryptoKit
import Foundation

final class FileCache: @unchecked Sendable {
    private let root: URL
    private let fileManager = FileManager.default

    init(accountID: String, persistent: Bool = false) {
        let base: URL
        if persistent {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("SeafileSwift", isDirectory: true)
                .appendingPathComponent("OfflineFiles", isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("SeafileSwift", isDirectory: true)
                .appendingPathComponent("Files", isDirectory: true)
        }
        root = base.appendingPathComponent(Self.hash(accountID), isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if persistent {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableRoot = root
            try? mutableRoot.setResourceValues(values)
        }
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func directory(repoID: String, path: String, version: String) -> URL {
        let key = Self.hash("\(repoID)|\(path)|\(version)")
        return root.appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    func existingURL(repoID: String, path: String, name: String, version: String) -> URL? {
        let url = directory(repoID: repoID, path: path, version: version)
            .appendingPathComponent(FileNames.sanitized(name))
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func store(tempURL: URL, repoID: String, path: String, name: String, version: String) throws -> URL {
        let dir = directory(repoID: repoID, path: path, version: version)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(FileNames.sanitized(name))
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempURL, to: destination)
        return destination
    }

    func storeCopy(from sourceURL: URL,
                   repoID: String,
                   path: String,
                   name: String,
                   version: String) throws -> URL {
        let dir = directory(repoID: repoID, path: path, version: version)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appendingPathComponent(FileNames.sanitized(name))
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    func totalSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    func clear() {
        guard let children = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for child in children {
            try? fileManager.removeItem(at: child)
        }
    }
}
