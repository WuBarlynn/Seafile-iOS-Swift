import CryptoKit
import Foundation

struct StoredTransferRetry: Codable, Sendable {
    let id: String
    let kind: String
    let name: String
    let repoID: String
    let path: String
    let version: String?
    let persistOffline: Bool
    let uploadReplace: Bool
    let error: String
    let startedAt: Date
    var sourceFileName: String?
}

final class TransferRetryStore {
    private let root: URL
    private let filesRoot: URL
    private let indexURL: URL
    private let fileManager = FileManager.default

    init(accountID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SeafileSwift", isDirectory: true)
            .appendingPathComponent("TransferRetries", isDirectory: true)
        root = base.appendingPathComponent(Self.hash(accountID), isDirectory: true)
        filesRoot = root.appendingPathComponent("files", isDirectory: true)
        indexURL = root.appendingPathComponent("retries.json")
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    func load() -> [StoredTransferRetry] {
        guard let data = try? Data(contentsOf: indexURL),
              let records = try? JSONDecoder().decode([StoredTransferRetry].self, from: data) else {
            return []
        }
        return records
    }

    @discardableResult
    func save(_ record: StoredTransferRetry, sourceURL: URL?) -> URL? {
        var updated = record
        if let sourceURL {
            let directory = filesRoot.appendingPathComponent(record.id, isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                var name = FileNames.sanitized(sourceURL.lastPathComponent)
                if name.isEmpty { name = "upload" }
                let destination = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: sourceURL, to: destination)
                updated.sourceFileName = name
            } catch {
                updated.sourceFileName = nil
            }
        }
        var records = load().filter { $0.id != record.id }
        records.insert(updated, at: 0)
        persist(records)
        guard let sourceFileName = updated.sourceFileName else { return nil }
        return filesRoot.appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent(sourceFileName)
    }

    func remove(id: String) {
        try? fileManager.removeItem(at: filesRoot.appendingPathComponent(id, isDirectory: true))
        var records = load()
        records.removeAll { $0.id == id }
        persist(records)
    }

    func sourceURL(for record: StoredTransferRetry) -> URL? {
        guard let sourceFileName = record.sourceFileName, !sourceFileName.isEmpty else { return nil }
        let url = filesRoot.appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent(sourceFileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func clear() {
        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func persist(_ records: [StoredTransferRetry]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
