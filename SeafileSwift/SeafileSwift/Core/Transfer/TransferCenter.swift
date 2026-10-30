import Foundation
import Observation

@MainActor
@Observable
final class TransferCenter {
    enum TransferKind: String, Equatable {
        case upload
        case download
    }

    struct TransferRecord: Identifiable, Equatable {
        let id: String
        let kind: TransferKind
        let name: String
        let repoID: String
        let path: String
        let startedAt: Date
        var progress: TransferProgress
        var finishedAt: Date? = nil
        var isCancelled = false

        var isActive: Bool {
            !isCancelled && progress.isActive
        }
    }

    struct UploadJob: Identifiable, Equatable {
        let id: String
        let fileName: String
        var progress: TransferProgress
    }

    private let api: APIClient
    let cache: FileCache
    let offlineFiles: FileCache
    private(set) var downloads: [String: TransferProgress] = [:]
    private(set) var uploadJobs: [UploadJob] = []
    private(set) var transferRecords: [TransferRecord] = []
    private var cancellationTokens: [String: TransferCancellationToken] = [:]
    var cryptoKeyProvider: ((String) -> RepoCryptoKey?)?

    init(api: APIClient, cache: FileCache, offlineFiles: FileCache) {
        self.api = api
        self.cache = cache
        self.offlineFiles = offlineFiles
    }

    private func key(repoID: String, path: String) -> String { "\(repoID)|\(path)" }

    func downloadProgress(repoID: String, path: String) -> TransferProgress? {
        downloads[key(repoID: repoID, path: path)]
    }

    func offlineFileExists(repoID: String, path: String, name: String, version: String) -> Bool {
        offlineFiles.existingURL(repoID: repoID, path: path, name: name, version: version) != nil
    }

    func download(repoID: String,
                  path: String,
                  name: String,
                  version: String,
                  persistOffline: Bool = false) async throws -> URL {
        if let existing = offlineFiles.existingURL(repoID: repoID, path: path, name: name, version: version) {
            return existing
        }
        if let existing = cache.existingURL(repoID: repoID, path: path, name: name, version: version) {
            if persistOffline {
                return try offlineFiles.storeCopy(from: existing,
                                                  repoID: repoID,
                                                  path: path,
                                                  name: name,
                                                  version: version)
            }
            return existing
        }

        let recordID = UUID().uuidString
        let token = TransferCancellationToken()
        cancellationTokens[recordID] = token
        addRecord(id: recordID,
                  kind: .download,
                  name: name,
                  repoID: repoID,
                  path: path,
                  progress: TransferProgress(state: .queued))

        let cacheKey = key(repoID: repoID, path: path)
        downloads[cacheKey] = TransferProgress(state: .running)
        updateRecord(id: recordID, progress: TransferProgress(state: .running))
        let cryptoKey = cryptoKeyProvider?(repoID)
        let onProgress: @Sendable (Double, Int64, Int64) -> Void = { [weak self] fraction, completed, total in
            Task { @MainActor in
                guard let self else { return }
                let progress = TransferProgress(state: .running,
                                                fraction: fraction,
                                                completedBytes: completed,
                                                totalBytes: total)
                self.downloads[cacheKey] = progress
                self.updateRecord(id: recordID, progress: progress)
            }
        }

        do {
            let temp: URL
            if let cryptoKey {
                temp = try await api.downloadEncrypted(repoID: repoID,
                                                       path: path,
                                                       key: cryptoKey,
                                                       progress: onProgress,
                                                       cancellation: token)
            } else {
                let link = try await api.downloadLink(repoID: repoID, path: path)
                temp = try await api.downloadFile(from: link,
                                                   progress: onProgress,
                                                   cancellation: token)
            }
            if token.isCancelled {
                throw CancellationError()
            }
            let store = persistOffline ? offlineFiles : cache
            let localURL = try store.store(tempURL: temp, repoID: repoID, path: path, name: name, version: version)
            let finished = TransferProgress(state: .finished, fraction: 1)
            downloads[cacheKey] = finished
            finishRecord(id: recordID, progress: finished)
            cancellationTokens[recordID] = nil
            return localURL
        } catch {
            let cancelled = token.isCancelled
            let progress = TransferProgress(state: .failed(cancelled
                ? String(localized: "Cancelled")
                : error.localizedDescription))
            downloads[cacheKey] = progress
            if cancelled {
                markCancelled(id: recordID)
            } else {
                finishRecord(id: recordID, progress: progress)
            }
            cancellationTokens[recordID] = nil
            throw error
        }
    }

    @discardableResult
    func upload(fileURL: URL,
                fileName: String,
                repoID: String,
                dirPath: String,
                replace: Bool = false) async throws -> String {
        let jobID = UUID().uuidString
        let token = TransferCancellationToken()
        cancellationTokens[jobID] = token
        addRecord(id: jobID,
                  kind: .upload,
                  name: fileName,
                  repoID: repoID,
                  path: dirPath,
                  progress: TransferProgress(state: .queued))
        uploadJobs.insert(UploadJob(id: jobID,
                                       fileName: fileName,
                                       progress: TransferProgress(state: .queued)),
                          at: 0)

        let accessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { fileURL.stopAccessingSecurityScopedResource() }
        }

        let cryptoKey = cryptoKeyProvider?(repoID)
        let onProgress: @Sendable (Double, Int64, Int64) -> Void = { [weak self] fraction, completed, total in
            Task { @MainActor in
                guard let self, let index = self.uploadJobs.firstIndex(where: { $0.id == jobID }) else { return }
                let progress = TransferProgress(state: .running,
                                                fraction: fraction,
                                                completedBytes: completed,
                                                totalBytes: total)
                self.uploadJobs[index].progress = progress
                self.updateRecord(id: jobID, progress: progress)
            }
        }

        do {
            if let cryptoKey {
                try await api.uploadEncrypted(fileURL: fileURL,
                                              repoID: repoID,
                                              dirPath: dirPath,
                                              fileName: fileName,
                                              replace: replace,
                                              key: cryptoKey,
                                              progress: onProgress,
                                              cancellation: token)
            } else {
                try await api.upload(fileURL: fileURL,
                                     repoID: repoID,
                                     dirPath: dirPath,
                                     fileName: fileName,
                                     replace: replace,
                                     progress: onProgress,
                                     cancellation: token)
            }
            if token.isCancelled {
                throw CancellationError()
            }
            let finished = TransferProgress(state: .finished, fraction: 1)
            if let index = uploadJobs.firstIndex(where: { $0.id == jobID }) {
                uploadJobs[index].progress = finished
            }
            finishRecord(id: jobID, progress: finished)
            cancellationTokens[jobID] = nil
            scheduleCleanup(jobID: jobID)
            return jobID
        } catch {
            let cancelled = token.isCancelled
            let progress = TransferProgress(state: .failed(cancelled
                ? String(localized: "Cancelled")
                : error.localizedDescription))
            if let index = uploadJobs.firstIndex(where: { $0.id == jobID }) {
                uploadJobs[index].progress = progress
            }
            if cancelled {
                markCancelled(id: jobID)
            } else {
                finishRecord(id: jobID, progress: progress)
            }
            cancellationTokens[jobID] = nil
            scheduleCleanup(jobID: jobID, delay: 6)
            throw error
        }
    }

    func cancelTransfer(id: String) {
        guard let index = transferRecords.firstIndex(where: { $0.id == id }),
              transferRecords[index].isActive else { return }
        cancellationTokens[id]?.cancel()
        let failed = TransferProgress(state: .failed(String(localized: "Cancelled")))
        let record = transferRecords[index]
        transferRecords[index].progress = failed
        transferRecords[index].isCancelled = true
        transferRecords[index].finishedAt = Date()
        if record.kind == .upload {
            if let jobIndex = uploadJobs.firstIndex(where: { $0.id == id }) {
                uploadJobs[jobIndex].progress = failed
            }
        } else {
            downloads[key(repoID: record.repoID, path: record.path)] = failed
        }
    }

    func cancelAllActiveTransfers() {
        for record in transferRecords where record.isActive {
            cancelTransfer(id: record.id)
        }
    }

    func clearCompletedTransfers() {
        transferRecords.removeAll { !$0.isActive }
    }

    var activeTransfers: [TransferRecord] {
        transferRecords.filter(\.isActive)
    }

    var completedTransfers: [TransferRecord] {
        transferRecords.filter { !$0.isActive }
    }

    var activeUploads: [UploadJob] {
        uploadJobs.filter { $0.progress.isActive }
    }

    var cacheSize: Int64 { cache.totalSize() }

    private func addRecord(id: String,
                           kind: TransferKind,
                           name: String,
                           repoID: String,
                           path: String,
                           progress: TransferProgress) {
        transferRecords.insert(TransferRecord(id: id,
                                              kind: kind,
                                              name: name,
                                              repoID: repoID,
                                              path: path,
                                              startedAt: Date(),
                                              progress: progress),
                               at: 0)
        if transferRecords.count > 120 {
            let active = transferRecords.filter(\.isActive)
            let completed = transferRecords.filter { !$0.isActive }.prefix(max(0, 100 - active.count))
            transferRecords = active + completed
        }
    }

    private func updateRecord(id: String, progress: TransferProgress) {
        guard let index = transferRecords.firstIndex(where: { $0.id == id }),
              !transferRecords[index].isCancelled else { return }
        transferRecords[index].progress = progress
    }

    private func finishRecord(id: String, progress: TransferProgress) {
        guard let index = transferRecords.firstIndex(where: { $0.id == id }),
              !transferRecords[index].isCancelled else { return }
        transferRecords[index].progress = progress
        transferRecords[index].finishedAt = Date()
    }

    private func markCancelled(id: String) {
        guard let index = transferRecords.firstIndex(where: { $0.id == id }) else { return }
        transferRecords[index].progress = TransferProgress(state: .failed(String(localized: "Cancelled")))
        transferRecords[index].isCancelled = true
        transferRecords[index].finishedAt = Date()
    }

    private func scheduleCleanup(jobID: String, delay: TimeInterval = 3) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.uploadJobs.removeAll { $0.id == jobID }
        }
    }
}

