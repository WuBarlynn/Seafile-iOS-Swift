import Foundation
import Observation

@MainActor
@Observable
final class OfflineDownloadManager {
    private let api: APIClient
    private let transfers: TransferCenter
    private var task: Task<Void, Never>?

    private(set) var isDownloading = false
    private(set) var title = ""
    private(set) var totalFiles = 0
    private(set) var completedFiles = 0
    private(set) var failedFiles = 0
    private(set) var currentName: String?
    private(set) var lastMessage: String?

    init(api: APIClient, transfers: TransferCenter) {
        self.api = api
        self.transfers = transfers
    }

    var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return min(1, Double(completedFiles) / Double(totalFiles))
    }

    @discardableResult
    func download(repoID: String, path: String, title: String) -> Bool {
        guard task == nil else { return false }
        isDownloading = true
        self.title = title
        totalFiles = 0
        completedFiles = 0
        failedFiles = 0
        currentName = nil
        lastMessage = nil

        task = Task { [weak self] in
            guard let self else { return }
            await self.run(repoID: repoID, path: path)
            self.task = nil
            self.isDownloading = false
            self.currentName = nil
        }
        return true
    }

    func cancel() {
        task?.cancel()
    }

    func clearLastMessage() {
        lastMessage = nil
    }

    private func run(repoID: String, path: String) async {
        var pendingDirectories = [path]
        var files: [Dirent] = []

        do {
            while let directory = pendingDirectories.popLast() {
                try Task.checkCancellation()
                let entries = try await api.dirents(repoID: repoID, path: directory)
                for entry in entries {
                    if entry.isDirectory {
                        pendingDirectories.append(entry.path)
                    } else {
                        files.append(entry)
                    }
                }
            }

            totalFiles = files.count
            for file in files {
                try Task.checkCancellation()
                if transfers.offlineFileExists(repoID: repoID,
                                               path: file.path,
                                               name: file.name,
                                               version: file.version) {
                    completedFiles += 1
                    continue
                }
                currentName = file.name
                do {
                    _ = try await transfers.download(repoID: repoID,
                                                     path: file.path,
                                                     name: file.name,
                                                     version: file.version,
                                                     persistOffline: true)
                    completedFiles += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failedFiles += 1
                }
            }

            if failedFiles > 0 {
                lastMessage = String(
                    format: String(localized: "Downloaded %lld files for offline use. %lld failed."),
                    completedFiles,
                    failedFiles
                )
            } else {
                lastMessage = String(
                    format: String(localized: "Downloaded %lld files for offline use."),
                    completedFiles
                )
            }
        } catch is CancellationError {
            lastMessage = String(localized: "Offline download cancelled.")
        } catch {
            if Task.isCancelled {
                lastMessage = String(localized: "Offline download cancelled.")
            } else {
                lastMessage = String(
                    format: String(localized: "Offline download failed: %@"),
                    error.localizedDescription
                )
            }
        }
    }
}
