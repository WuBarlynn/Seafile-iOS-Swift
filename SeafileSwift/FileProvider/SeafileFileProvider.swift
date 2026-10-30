import FileProvider
import Foundation
import UniformTypeIdentifiers

final class SeafileFileProvider: NSObject, NSFileProviderReplicatedExtension, NSFileProviderThumbnailing {
    let domain: NSFileProviderDomain
    private let account: SharedAccount?
    private let api: FileProviderAPI?

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        let accountID = FileProviderDomainID.accountID(from: domain.identifier.rawValue)
        let accounts = ShareSessionStore.load().accounts
        let account = accounts.first { $0.id == accountID }
        self.account = account
        self.api = account.map(FileProviderAPI.init)
        super.init()
    }

    func invalidate() {}

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            guard let api else {
                completionHandler(nil, FPEnumerator.map(FPAPIError.invalidServer))
                return
            }
            if identifier == .rootContainer {
                completionHandler(FPItem.root(displayName: domain.displayName), nil)
                return
            }
            do {
                guard let item = try await loadItem(identifier, api: api) else {
                    completionHandler(nil, FPEnumerator.noSuchItemError)
                    return
                }
                completionHandler(FPDecorationStore.shared.apply(to: item), nil)
            } catch {
                completionHandler(nil, FPEnumerator.map(error))
            }
        }
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            guard let api, let decoded = FPIdentifier.decode(itemIdentifier), !decoded.path.isEmpty else {
                completionHandler(nil, nil, FPEnumerator.noSuchItemError)
                return
            }
            do {
                guard let item = try await loadItem(itemIdentifier, api: api) else {
                    completionHandler(nil, nil, FPEnumerator.noSuchItemError)
                    return
                }
                let link = try await api.downloadLink(repoID: decoded.repoID, path: decoded.path)
                let temp = try await api.download(from: link)
                completionHandler(temp, item, nil)
            } catch {
                completionHandler(nil, nil, FPEnumerator.map(error))
            }
        }
        return progress
    }

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            guard let api,
                  let parent = FPIdentifier.decode(itemTemplate.parentItemIdentifier) else {
                completionHandler(nil, [], false, FPEnumerator.noSuchItemError)
                return
            }
            let dirPath = parent.path.isEmpty ? "/" : parent.path
            let name = itemTemplate.filename
            let path = dirPath == "/" ? "/\(name)" : "\(dirPath)/\(name)"
            do {
                if itemTemplate.contentType == .folder {
                    try await api.createDirectory(repoID: parent.repoID,
                                                  parentPath: dirPath,
                                                  name: name)
                    completionHandler(FPItem.folder(repoID: parent.repoID, path: path),
                                      [], false, nil)
                } else if let url {
                    try await api.upload(fileURL: url,
                                         fileName: name,
                                         repoID: parent.repoID,
                                         dirPath: dirPath,
                                         replace: false)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                    completionHandler(FPItem.file(repoID: parent.repoID, path: path, size: size),
                                      [], false, nil)
                } else {
                    completionHandler(nil, [], false, FPEnumerator.map(FPAPIError.invalidResponse))
                }
            } catch {
                completionHandler(nil, [], false, FPEnumerator.map(error))
            }
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            guard let api, let decoded = FPIdentifier.decode(item.itemIdentifier) else {
                completionHandler(nil, [], false, FPEnumerator.noSuchItemError)
                return
            }
            let decorationFields: NSFileProviderItemFields = [.favoriteRank, .tagData, .lastUsedDate]
            if !changedFields.intersection(decorationFields).isEmpty {
                FPDecorationStore.shared.update(from: item,
                                                fields: changedFields,
                                                identifier: item.itemIdentifier)
                if changedFields.subtracting(decorationFields).isEmpty {
                    if let current = try? await loadItem(item.itemIdentifier, api: api) {
                        completionHandler(FPDecorationStore.shared.apply(to: current), [], false, nil)
                    } else {
                        completionHandler(nil, [], false, FPEnumerator.noSuchItemError)
                    }
                    return
                }
            }
            let newParent = FPIdentifier.decode(item.parentItemIdentifier)
            let newDirectory = newParent?.path ?? FPIdentifier.parentPath(decoded.path)
            let oldName = FPIdentifier.name(decoded.path)
            let newName = item.filename
            let parentChanged = newParent?.repoID != decoded.repoID
                || newDirectory != FPIdentifier.parentPath(decoded.path)
            let nameChanged = newName != oldName
            let isDirectory = item.contentType == .folder

            do {
                if let newContents, !isDirectory {
                    let targetRepo = newParent?.repoID ?? decoded.repoID
                    try await api.upload(fileURL: newContents,
                                         fileName: newName,
                                         repoID: targetRepo,
                                         dirPath: newDirectory,
                                         replace: true)
                    if parentChanged || nameChanged {
                        try? await api.delete(repoID: decoded.repoID, path: decoded.path)
                    }
                } else if parentChanged {
                    try await api.move(repoID: decoded.repoID,
                                       path: decoded.path,
                                       destinationRepoID: newParent?.repoID ?? decoded.repoID,
                                       destinationPath: newDirectory)
                    if nameChanged {
                        let movedPath = newDirectory == "/" ? "/\(oldName)" : "\(newDirectory)/\(oldName)"
                        try await api.rename(repoID: newParent?.repoID ?? decoded.repoID,
                                             path: movedPath,
                                             newName: newName)
                    }
                } else if nameChanged {
                    try await api.rename(repoID: decoded.repoID,
                                         path: decoded.path,
                                         newName: newName)
                }

                let finalRepoID = newParent?.repoID ?? decoded.repoID
                let finalPath = newDirectory == "/" ? "/\(newName)" : "\(newDirectory)/\(newName)"
                let size: Int64
                if let newContents,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: newContents.path),
                   let number = attributes[.size] as? NSNumber {
                    size = number.int64Value
                } else {
                    size = (item.documentSize ?? nil)?.int64Value ?? 0
                }
                let updated = isDirectory
                    ? FPItem.folder(repoID: finalRepoID, path: finalPath)
                    : FPItem.file(repoID: finalRepoID, path: finalPath, size: size)
                completionHandler(updated, [], false, nil)
            } catch {
                completionHandler(nil, [], false, FPEnumerator.map(error))
            }
        }
        return progress
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            defer { progress.completedUnitCount = 1 }
            guard let api, let decoded = FPIdentifier.decode(identifier), !decoded.path.isEmpty else {
                completionHandler(FPEnumerator.noSuchItemError)
                return
            }
            do {
                try await api.delete(repoID: decoded.repoID, path: decoded.path)
                completionHandler(nil)
            } catch {
                completionHandler(FPEnumerator.map(error))
            }
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        guard let api else { throw FPEnumerator.map(FPAPIError.invalidServer) }
        return FPEnumerator(container: containerItemIdentifier, api: api)
    }

    func fetchThumbnails(for itemIdentifiers: [NSFileProviderItemIdentifier],
                         requestedSize size: CGSize,
                         perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
                         completionHandler: @escaping (Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        guard !itemIdentifiers.isEmpty else {
            completionHandler(nil)
            return progress
        }
        let side = min(max(Int(max(size.width, size.height)), 64), 512)
        Task {
            for identifier in itemIdentifiers {
                if progress.isCancelled { break }
                defer { progress.completedUnitCount += 1 }
                guard let api,
                      let decoded = FPIdentifier.decode(identifier),
                      !decoded.path.isEmpty,
                      let type = UTType(filenameExtension: (decoded.path as NSString).pathExtension),
                      type.conforms(to: .image) else {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                    continue
                }
                do {
                    let data = try await api.thumbnail(repoID: decoded.repoID,
                                                      path: decoded.path,
                                                      size: side)
                    perThumbnailCompletionHandler(identifier, data, nil)
                } catch {
                    perThumbnailCompletionHandler(identifier, nil, nil)
                }
            }
            completionHandler(nil)
        }
        return progress
    }

    // MARK: - Helpers

    private func loadItem(_ identifier: NSFileProviderItemIdentifier,
                          api: FileProviderAPI) async throws -> FPItem? {
        guard let decoded = FPIdentifier.decode(identifier) else { return nil }
        if decoded.path.isEmpty {
            let repo = try await api.repos().first { $0.id == decoded.repoID && !$0.isEncrypted }
            return repo.map(FPItem.repo)
        }
        let parent = FPIdentifier.parentPath(decoded.path)
        let entries = try await api.dirents(repoID: decoded.repoID, path: parent)
        guard let entry = entries.first(where: { $0.name == FPIdentifier.name(decoded.path) }) else {
            return nil
        }
        return FPItem.dirent(repoID: decoded.repoID, parentPath: parent, entry: entry)
    }
}
