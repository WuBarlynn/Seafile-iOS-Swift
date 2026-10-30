import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FPItem: NSObject, NSFileProviderItem {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let itemVersion: NSFileProviderItemVersion
    let capabilities: NSFileProviderItemCapabilities
    let isDownloaded: Bool
    let isMostRecentVersionDownloaded: Bool
    let isUploaded: Bool
    let isUploading: Bool
    let isDownloading: Bool
    let isShared: Bool
    let isTrashed: Bool
    let childItemCount: NSNumber?

    init(itemIdentifier: NSFileProviderItemIdentifier,
         parentItemIdentifier: NSFileProviderItemIdentifier,
         filename: String,
         contentType: UTType,
         documentSize: Int64?,
         modified: Date?,
         versionSeed: String,
         isDirectory: Bool,
         writable: Bool) {
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data((versionSeed.isEmpty ? "0" : versionSeed).utf8),
            metadataVersion: Data((versionSeed.isEmpty ? "0" : versionSeed).utf8))
        self.itemIdentifier = itemIdentifier
        self.parentItemIdentifier = parentItemIdentifier
        self.filename = filename
        self.contentType = contentType
        self.documentSize = documentSize.map { NSNumber(value: $0) }
        self.creationDate = modified
        self.contentModificationDate = modified
        var flags: NSFileProviderItemCapabilities = [.allowsReading]
        if writable {
            flags.formUnion([.allowsWriting, .allowsRenaming, .allowsDeleting, .allowsReparenting])
        }
        if isDirectory {
            flags.formUnion([.allowsContentEnumerating])
            if writable { flags.formUnion([.allowsAddingSubItems]) }
        }
        self.capabilities = flags
        self.isDownloaded = isDirectory
        self.isMostRecentVersionDownloaded = isDirectory
        self.isUploaded = true
        self.isUploading = false
        self.isDownloading = false
        self.isShared = false
        self.isTrashed = false
        self.childItemCount = nil
        super.init()
    }

    static func root(displayName: String) -> FPItem {
        FPItem(itemIdentifier: .rootContainer,
               parentItemIdentifier: .rootContainer,
               filename: displayName,
               contentType: .folder,
               documentSize: nil,
               modified: nil,
               versionSeed: "root",
               isDirectory: true,
               writable: false)
    }

    static func repo(_ repo: FPRepo) -> FPItem {
        FPItem(itemIdentifier: FPIdentifier.repoIdentifier(repo.id),
               parentItemIdentifier: .rootContainer,
               filename: repo.name,
               contentType: .folder,
               documentSize: nil,
               modified: nil,
               versionSeed: "repo-\(repo.id)",
               isDirectory: true,
               writable: repo.isWritable)
    }

    static func dirent(repoID: String, parentPath: String, entry: FPDirent) -> FPItem {
        let path = parentPath == "/" ? "/\(entry.name)" : "\(parentPath)/\(entry.name)"
        let parent = parentPath == "/"
            ? FPIdentifier.repoIdentifier(repoID)
            : FPIdentifier.identifier(repoID: repoID, path: parentPath)
        let ext = (entry.name as NSString).pathExtension
        let type = entry.isDirectory
            ? UTType.folder
            : (UTType(filenameExtension: ext) ?? .data)
        let modified = entry.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let seed = entry.id ?? String(entry.mtime ?? 0)
        return FPItem(itemIdentifier: FPIdentifier.identifier(repoID: repoID, path: path),
                      parentItemIdentifier: parent,
                      filename: entry.name,
                      contentType: type,
                      documentSize: entry.isDirectory ? nil : (entry.size ?? 0),
                      modified: modified,
                      versionSeed: seed,
                      isDirectory: entry.isDirectory,
                      writable: (entry.permission ?? "rw").lowercased() == "rw")
    }

    static func folder(repoID: String, path: String) -> FPItem {
        FPItem(itemIdentifier: FPIdentifier.identifier(repoID: repoID, path: path),
               parentItemIdentifier: folderParent(repoID: repoID, path: path),
               filename: FPIdentifier.name(path),
               contentType: .folder,
               documentSize: nil,
               modified: Date(),
               versionSeed: UUID().uuidString,
               isDirectory: true,
               writable: true)
    }

    static func file(repoID: String, path: String, size: Int64, modified: Date = Date()) -> FPItem {
        let ext = (path as NSString).pathExtension
        return FPItem(itemIdentifier: FPIdentifier.identifier(repoID: repoID, path: path),
                      parentItemIdentifier: folderParent(repoID: repoID, path: path),
                      filename: FPIdentifier.name(path),
                      contentType: UTType(filenameExtension: ext) ?? .data,
                      documentSize: size,
                      modified: modified,
                      versionSeed: UUID().uuidString,
                      isDirectory: false,
                      writable: true)
    }

    private static func folderParent(repoID: String, path: String) -> NSFileProviderItemIdentifier {
        let parent = FPIdentifier.parentPath(path)
        return parent == "/"
            ? FPIdentifier.repoIdentifier(repoID)
            : FPIdentifier.identifier(repoID: repoID, path: parent)
    }
}
