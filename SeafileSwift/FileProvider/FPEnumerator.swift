import FileProvider
import Foundation

final class FPEnumerator: NSObject, NSFileProviderEnumerator {
    private let container: NSFileProviderItemIdentifier
    private let api: FileProviderAPI

    init(container: NSFileProviderItemIdentifier, api: FileProviderAPI) {
        self.container = container
        self.api = api
        super.init()
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        Task {
            do {
                if container == .workingSet {
                    observer.finishEnumerating(upTo: nil)
                    return
                }
                if container == .rootContainer {
                    let repos = try await api.repos().filter { !$0.isEncrypted }
                    observer.didEnumerate(repos.map { FPDecorationStore.shared.apply(to: FPItem.repo($0)) })
                } else if let decoded = FPIdentifier.decode(container) {
                    let entries = try await api.dirents(repoID: decoded.repoID, path: decoded.path)
                    observer.didEnumerate(entries.map {
                        FPDecorationStore.shared.apply(to: FPItem.dirent(repoID: decoded.repoID,
                                                                         parentPath: decoded.path,
                                                                         entry: $0))
                    })
                } else {
                    observer.finishEnumeratingWithError(Self.noSuchItemError)
                    return
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(Self.map(error))
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    static let noSuchItemError = NSError(domain: NSFileProviderErrorDomain, code: -1005)

    static func map(_ error: Error) -> Error {
        if let apiError = error as? FPAPIError {
            switch apiError {
            case let .http(code, _) where code == 401 || code == 403:
                return NSError(domain: NSFileProviderErrorDomain, code: -1000)
            case let .http(code, _) where code == 404:
                return noSuchItemError
            default:
                return NSError(domain: NSFileProviderErrorDomain, code: -1004)
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return NSError(domain: NSFileProviderErrorDomain, code: -1004)
        }
        return NSError(domain: NSFileProviderErrorDomain, code: -1004)
    }
}
