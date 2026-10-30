import CryptoKit
import Foundation

struct PhotoSyncState: Codable, Sendable {
    var uploadedIdentifiers: Set<String> = []
    var uploadedNames: [String: String]?
    var didInitialScan = false
    var updatedAt: Date?
}

actor PhotoSyncStateStore {
    private let root: URL
    private let fileManager = FileManager.default

    init(accountID: String) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SeafileSwift", isDirectory: true)
            .appendingPathComponent("PhotoSync", isDirectory: true)
        root = base.appendingPathComponent(Self.hash(accountID), isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = root
        try? mutableRoot.setResourceValues(values)
    }

    func load(repoID: String) -> PhotoSyncState {
        guard let data = try? Data(contentsOf: fileURL(repoID: repoID)),
              let state = try? JSONDecoder().decode(PhotoSyncState.self, from: data) else {
            return PhotoSyncState()
        }
        return state
    }

    func save(_ state: PhotoSyncState, repoID: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: fileURL(repoID: repoID), options: .atomic)
    }

    func clear(repoID: String) {
        try? fileManager.removeItem(at: fileURL(repoID: repoID))
    }

    private func fileURL(repoID: String) -> URL {
        root.appendingPathComponent(Self.hash(repoID))
            .appendingPathExtension("json")
    }

    private static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
