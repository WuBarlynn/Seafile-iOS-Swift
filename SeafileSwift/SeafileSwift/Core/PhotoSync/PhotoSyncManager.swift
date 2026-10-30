import Foundation
import Network
import Observation
import Photos
import UIKit

enum PhotoSyncAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case limited
    case authorized

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .limited: self = .limited
        case .authorized: self = .authorized
        @unknown default: self = .denied
        }
    }

    var canRead: Bool {
        self == .authorized || self == .limited
    }
}

private enum PhotoSyncError: LocalizedError {
    case missingResource
    case invalidAsset

    var errorDescription: String? {
        switch self {
        case .missingResource:
            return String(localized: "Could not read the original photo data.")
        case .invalidAsset:
            return String(localized: "This item is no longer available in the photo library.")
        }
    }
}

@MainActor
@Observable
final class PhotoSyncManager {
    private static let folderName = "Camera Uploads"
    private static let temporaryFolder = "seafile-photo-sync"

    private let accountID: String
    private let api: APIClient
    private let transfers: TransferCenter
    private let settings: AppSettings
    private let defaults = UserDefaults.standard
    private let stateStore: PhotoSyncStateStore
    private let pathMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "com.seafile.photo-sync.network")

    private var state = PhotoSyncState()
    private var stateRepoID: String?
    private var syncTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var observer: PhotoLibraryObserver?
    private var needsResync = false
    private var isAppActive = true
    private var backgroundSyncRequested = false
    private var isOnWiFi = false
    private var isNetworkAvailable = true

    private(set) var isEnabled: Bool
    private(set) var destinationRepoID: String?
    private(set) var authorization: PhotoSyncAuthorization
    private(set) var isSyncing = false
    private(set) var isScanning = false
    private(set) var pendingCount = 0
    private(set) var uploadedThisRun = 0
    private(set) var lastError: String?
    private(set) var lastSyncDate: Date?
    private(set) var isWaitingForWiFi = false
    private(set) var didInitialScan = false

    var uploadVideos: Bool {
        didSet {
            defaults.set(uploadVideos, forKey: pref("videos"))
            if uploadVideos { syncNow() }
        }
    }

    var wifiOnly: Bool {
        didSet {
            defaults.set(wifiOnly, forKey: pref("wifiOnly"))
            if !wifiOnly { startSyncIfPossible() }
        }
    }

    var isLimitedAccess: Bool { authorization == .limited }

    private var canRunSync: Bool { isAppActive || backgroundSyncRequested }

    var statusText: String {
        if !isEnabled { return String(localized: "Off") }
        if !authorization.canRead { return String(localized: "Photo access is required.") }
        if destinationRepoID == nil { return String(localized: "Choose a library.") }
        if isScanning { return String(localized: "Preparing photo library…") }
        if isWaitingForWiFi { return String(localized: "Waiting for Wi-Fi.") }
        if !isNetworkAvailable { return String(localized: "No network connection.") }
        if isSyncing {
            if pendingCount > 0 {
                return String(format: String(localized: "Uploading %lld… %lld remaining"),
                              uploadedThisRun,
                              pendingCount)
            }
            return String(localized: "Uploading…")
        }
        if let lastError { return lastError }
        if didInitialScan && pendingCount == 0 {
            return isLimitedAccess
                ? String(localized: "All selected photos backed up.")
                : String(localized: "All photos backed up.")
        }
        return String(localized: "Ready.")
    }

    init(account: Account,
         api: APIClient,
         transfers: TransferCenter,
         settings: AppSettings) {
        self.accountID = account.id
        self.api = api
        self.transfers = transfers
        self.settings = settings
        stateStore = PhotoSyncStateStore(accountID: account.id)
        let defaults = UserDefaults.standard
        let prefix = "photoSync.\(account.id)."
        isEnabled = defaults.bool(forKey: prefix + "enabled")
        destinationRepoID = defaults.string(forKey: prefix + "repoID")
        uploadVideos = defaults.object(forKey: prefix + "videos") as? Bool ?? true
        wifiOnly = defaults.object(forKey: prefix + "wifiOnly") as? Bool ?? true
        authorization = PhotoSyncAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
        startNetworkMonitor()
    }

    deinit {
        pathMonitor.cancel()
    }

    func prepare() async {
        refreshAuthorization()
        guard isEnabled, authorization.canRead, destinationRepoID != nil else { return }
        await loadStateIfNeeded()
        registerObserver()
        startSyncIfPossible()
    }

    func resume() {
        isAppActive = true
        refreshAuthorization()
        guard isEnabled else { return }
        registerObserver()
        startSyncIfPossible()
    }

    func pause() {
        isAppActive = false
        debounceTask?.cancel()
        debounceTask = nil
        syncTask?.cancel()
        isWaitingForWiFi = false
        unregisterObserver()
    }

    func stop() {
        pause()
        syncTask?.cancel()
        pathMonitor.cancel()
        unregisterObserver()
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        if !enabled {
            isEnabled = false
            defaults.set(false, forKey: pref("enabled"))
            PhotoSyncBackgroundScheduler.shared.cancel()
            needsResync = false
            syncTask?.cancel()
            debounceTask?.cancel()
            debounceTask = nil
            isWaitingForWiFi = false
            unregisterObserver()
            return true
        }

        let status = await requestAuthorizationIfNeeded()
        authorization = PhotoSyncAuthorization(status)
        guard authorization.canRead else {
            lastError = String(localized: "Photo access is required to back up your library.")
            return false
        }

        isEnabled = true
        lastError = nil
        defaults.set(true, forKey: pref("enabled"))
        await loadStateIfNeeded()
        registerObserver()
        startSyncIfPossible()
        return true
    }

    func setDestination(_ repoID: String) {
        if repoID == destinationRepoID {
            startSyncIfPossible()
            return
        }
        syncTask?.cancel()
        needsResync = false
        destinationRepoID = repoID
        defaults.set(repoID, forKey: pref("repoID"))
        state = PhotoSyncState()
        stateRepoID = nil
        didInitialScan = false
        pendingCount = 0
        uploadedThisRun = 0
        lastError = nil
        isWaitingForWiFi = false
        Task {
            await loadStateIfNeeded()
            startSyncIfPossible()
        }
    }

    func performBackgroundSync() async -> Bool {
        guard isEnabled, destinationRepoID != nil, authorization.canRead else { return true }
        backgroundSyncRequested = true
        defer { backgroundSyncRequested = false }

        if let existing = syncTask {
            await existing.value
        }
        if syncTask == nil {
            syncNow()
        }
        if let task = syncTask {
            await task.value
        }
        return lastError == nil
    }

    func cancelBackgroundSync() {
        syncTask?.cancel()
    }

    func syncNow() {
        guard isEnabled, canRunSync, destinationRepoID != nil, authorization.canRead else { return }
        guard syncTask == nil else {
            needsResync = true
            return
        }
        needsResync = false
        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.runSync()
            self.syncTask = nil
            if self.needsResync {
                self.needsResync = false
                self.syncNow()
            }
        }
    }

    private func runSync() async {
        guard isEnabled, canRunSync,
              let repoID = destinationRepoID,
              authorization.canRead else { return }
        await loadStateIfNeeded()
        guard stateRepoID == repoID, destinationRepoID == repoID else { return }

        guard canUploadNow else {
            isWaitingForWiFi = wifiOnly && isNetworkAvailable && !isOnWiFi
            return
        }

        isSyncing = true
        isScanning = true
        isWaitingForWiFi = false
        lastError = nil
        uploadedThisRun = 0
        defer {
            isSyncing = false
            isScanning = false
        }

        do {
            let folderPath = try await ensureCameraFolder(repoID: repoID)
            let remoteNames = try await remoteFileNames(repoID: repoID, path: folderPath)
            guard isEnabled, destinationRepoID == repoID, canRunSync else { return }

            let assets = await Self.fetchAssets(includeVideos: uploadVideos)
            guard isEnabled, destinationRepoID == repoID, canRunSync else { return }

            var remoteNamesByBase: [String: String] = [:]
            for name in remoteNames {
                let base = (name as NSString).deletingPathExtension.lowercased()
                if remoteNamesByBase[base] == nil {
                    remoteNamesByBase[base] = name
                }
            }

            // A server-side deletion must invalidate the local "uploaded" mark,
            // otherwise manual or automatic syncs would keep skipping that asset.
            reconcileUploadedState(assets: assets, remoteNames: remoteNames)
            guard isEnabled, destinationRepoID == repoID, stateRepoID == repoID else { return }

            if !state.didInitialScan {
                let matched = await Self.remoteMatchedIdentifiers(
                    assets: assets,
                    remoteNamesByBase: remoteNamesByBase,
                    uploaded: state.uploadedIdentifiers
                )
                guard isEnabled, destinationRepoID == repoID, stateRepoID == repoID else { return }
                state.uploadedIdentifiers.formUnion(matched.keys)
                var names = state.uploadedNames ?? [:]
                for (identifier, name) in matched {
                    names[identifier] = name
                }
                state.uploadedNames = names.isEmpty ? nil : names
                state.didInitialScan = true
                didInitialScan = true
                await saveState(repoID: repoID)
            }

            let pending = assets.filter { !state.uploadedIdentifiers.contains($0.localIdentifier) }
            pendingCount = pending.count
            isScanning = false

            guard !pending.isEmpty else {
                await saveState(repoID: repoID)
                lastSyncDate = Date()
                return
            }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.temporaryFolder, isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory,
                                                    withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            var reservedNames = Set(remoteNames.map { $0.lowercased() })

            for (index, asset) in pending.enumerated() {
                try Task.checkCancellation()
                guard isEnabled, canRunSync, destinationRepoID == repoID else { return }
                guard canUploadNow else {
                    isWaitingForWiFi = wifiOnly && isNetworkAvailable && !isOnWiFi
                    break
                }

                pendingCount = max(0, pending.count - index)
                if asset.mediaType == .video, !uploadVideos {
                    pendingCount = max(0, pendingCount - 1)
                    continue
                }
                if state.uploadedIdentifiers.contains(asset.localIdentifier) {
                    pendingCount = max(0, pendingCount - 1)
                    continue
                }

                do {
                    let prepared = try prepareExport(asset: asset,
                                                     in: temporaryDirectory,
                                                     reservedNames: &reservedNames)
                    defer { try? FileManager.default.removeItem(at: prepared.url) }
                    try await export(prepared: prepared, asset: asset)
                    let uploadedName = try await upload(prepared: prepared,
                                                        repoID: repoID,
                                                        folderPath: folderPath,
                                                        reservedNames: &reservedNames)
                    guard canRunSync,
                          isEnabled,
                          destinationRepoID == repoID,
                          stateRepoID == repoID else { return }
                    state.uploadedIdentifiers.insert(asset.localIdentifier)
                    var uploadedNames = state.uploadedNames ?? [:]
                    uploadedNames[asset.localIdentifier] = uploadedName
                    state.uploadedNames = uploadedNames
                    lastError = nil
                    uploadedThisRun += 1
                    if uploadedThisRun % 25 == 0 {
                        await saveState(repoID: repoID)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = String(format: String(localized: "Could not back up a photo: %@"),
                                       error.localizedDescription)
                }
                pendingCount = max(0, pending.count - index - 1)
            }

            pendingCount = pending.reduce(0) {
                $0 + (state.uploadedIdentifiers.contains($1.localIdentifier) ? 0 : 1)
            }
            await saveState(repoID: repoID)
            lastSyncDate = Date()
        } catch is CancellationError {
            // Pausing or switching libraries stops the current pass.
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadStateIfNeeded() async {
        guard let repoID = destinationRepoID else {
            state = PhotoSyncState()
            stateRepoID = nil
            didInitialScan = false
            return
        }
        guard stateRepoID != repoID else { return }
        state = await stateStore.load(repoID: repoID)
        stateRepoID = repoID
        didInitialScan = state.didInitialScan
        pendingCount = 0
    }

    private func saveState(repoID: String) async {
        guard stateRepoID == repoID else { return }
        state.updatedAt = Date()
        await stateStore.save(state, repoID: repoID)
        didInitialScan = state.didInitialScan
    }

    private func startSyncIfPossible() {
        guard isEnabled, isAppActive, destinationRepoID != nil, authorization.canRead else { return }
        guard canUploadNow else {
            isWaitingForWiFi = wifiOnly && isNetworkAvailable && !isOnWiFi
            return
        }
        isWaitingForWiFi = false
        syncNow()
    }

    private var canUploadNow: Bool {
        guard isNetworkAvailable else { return false }
        return !wifiOnly || isOnWiFi
    }

    private func ensureCameraFolder(repoID: String) async throws -> String {
        let root = try await api.dirents(repoID: repoID, path: "/")
        if let folder = root.first(where: {
            $0.isDirectory && $0.name.caseInsensitiveCompare(Self.folderName) == .orderedSame
        }) {
            return folder.path
        }

        do {
            try await api.createDirectory(repoID: repoID,
                                          parentPath: "/",
                                          name: Self.folderName)
        } catch {
            let refreshed = try await api.dirents(repoID: repoID, path: "/")
            if let folder = refreshed.first(where: {
                $0.isDirectory && $0.name.caseInsensitiveCompare(Self.folderName) == .orderedSame
            }) {
                return folder.path
            }
            throw error
        }
        return "/\(Self.folderName)"
    }

    private func remoteFileNames(repoID: String, path: String) async throws -> [String] {
        let items = try await api.dirents(repoID: repoID, path: path)
        return items.filter { !$0.isDirectory }.map(\.name)
    }

    private func upload(prepared: PreparedAsset,
                        repoID: String,
                        folderPath: String,
                        reservedNames: inout Set<String>) async throws -> String {
        do {
            try await transfers.upload(fileURL: prepared.url,
                                       fileName: prepared.fileName,
                                       repoID: repoID,
                                       dirPath: folderPath,
                                       replace: false)
            return prepared.fileName
        } catch {
            let fallbackName = uniqueName(base: prepared.baseName,
                                          ext: prepared.extension,
                                          reservedNames: &reservedNames)
            try await transfers.upload(fileURL: prepared.url,
                                       fileName: fallbackName,
                                       repoID: repoID,
                                       dirPath: folderPath,
                                       replace: false)
            return fallbackName
        }
    }

    private struct PreparedAsset {
        let url: URL
        let fileName: String
        let baseName: String
        let `extension`: String
        let resource: PHAssetResource
        let convertsToJPEG: Bool
        let isLivePhoto: Bool
    }

    private func prepareExport(asset: PHAsset,
                               in directory: URL,
                               reservedNames: inout Set<String>) throws -> PreparedAsset {
        guard let resource = Self.primaryResource(for: asset) else {
            throw PhotoSyncError.missingResource
        }

        let originalName = FileNames.sanitized(resource.originalFilename)
        let fallbackName = Self.fallbackName(for: asset)
        var baseName = (originalName as NSString).deletingPathExtension
        if baseName.isEmpty { baseName = (fallbackName as NSString).deletingPathExtension }
        var ext = (originalName as NSString).pathExtension.lowercased()
        if ext.isEmpty { ext = (fallbackName as NSString).pathExtension.lowercased() }

        let liveExtension = LivePhotoExport.outputExtension(for: asset)
        let isLivePhoto = asset.mediaType == .image
            && settings.uploadLivePhotos
            && LivePhotoExport.isLivePhoto(asset)
            && liveExtension != nil
            && LivePhotoExport.hasPairedVideo(asset)
        if isLivePhoto, let liveExtension { ext = liveExtension }

        let convertsToJPEG = !isLivePhoto
            && asset.mediaType == .image
            && settings.convertPhotosToJPEG
            && (ext == "heic" || ext == "heif")
        if convertsToJPEG { ext = "jpg" }

        let fileName = uniqueName(base: baseName, ext: ext, reservedNames: &reservedNames)
        return PreparedAsset(url: directory.appendingPathComponent(fileName),
                             fileName: fileName,
                             baseName: baseName,
                             extension: ext,
                             resource: resource,
                             convertsToJPEG: convertsToJPEG,
                             isLivePhoto: isLivePhoto)
    }

    private func export(prepared: PreparedAsset, asset: PHAsset) async throws {
        if prepared.isLivePhoto {
            let data = try await LivePhotoExport.motionPhotoData(for: asset)
            let url = prepared.url
            try await Task.detached(priority: .utility) {
                try data.write(to: url, options: .atomic)
            }.value
        } else {
            try await Self.writeResource(prepared.resource, to: prepared.url)

            if prepared.convertsToJPEG {
                guard let data = ImageTranscoder.jpegDataPreservingMetadata(fromFile: prepared.url) else {
                    throw PhotoSyncError.invalidAsset
                }
                try data.write(to: prepared.url, options: .atomic)
            }
        }

        if let modified = asset.modificationDate {
            try? FileManager.default.setAttributes([.modificationDate: modified],
                                                  ofItemAtPath: prepared.url.path)
        }
    }

    private func uniqueName(base: String,
                            ext: String,
                            reservedNames: inout Set<String>) -> String {
        var cleanedBase = FileNames.sanitized(base).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanedBase.isEmpty { cleanedBase = "Photo" }
        var candidate = ext.isEmpty ? cleanedBase : "\(cleanedBase).\(ext)"
        var index = 2
        while reservedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty
                ? "\(cleanedBase)-\(index)"
                : "\(cleanedBase)-\(index).\(ext)"
            index += 1
        }
        reservedNames.insert(candidate.lowercased())
        return candidate
    }

    private func reconcileUploadedState(assets: [PHAsset], remoteNames: [String]) {
        guard !state.uploadedIdentifiers.isEmpty else { return }

        let remoteLowercased = Set(remoteNames.map { $0.lowercased() })
        var remoteNamesByBase: [String: String] = [:]
        for name in remoteNames {
            let base = (name as NSString).deletingPathExtension.lowercased()
            if remoteNamesByBase[base] == nil {
                remoteNamesByBase[base] = name
            }
        }
        let assetsByID = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.localIdentifier, $0)
        })
        var names = state.uploadedNames ?? [:]
        var identifiersToRemove: [String] = []

        for identifier in state.uploadedIdentifiers {
            if let recorded = names[identifier], !recorded.isEmpty {
                if !remoteLowercased.contains(recorded.lowercased()) {
                    identifiersToRemove.append(identifier)
                }
                continue
            }
            guard let asset = assetsByID[identifier] else { continue }
            if !remoteNamesByBase.keys.contains(Self.assetBaseName(asset)) {
                identifiersToRemove.append(identifier)
            }
        }

        for identifier in identifiersToRemove {
            state.uploadedIdentifiers.remove(identifier)
            names.removeValue(forKey: identifier)
        }
        if state.uploadedNames != names {
            state.uploadedNames = names.isEmpty ? nil : names
        }
    }

    private static func remoteMatchedIdentifiers(assets: [PHAsset],
                                                 remoteNamesByBase: [String: String],
                                                 uploaded: Set<String>) async -> [String: String] {
        await Task.detached(priority: .utility) {
            var matches: [String: String] = [:]
            for asset in assets where !uploaded.contains(asset.localIdentifier) {
                if let remoteName = remoteNamesByBase[assetBaseName(asset)] {
                    matches[asset.localIdentifier] = remoteName
                }
            }
            return matches
        }.value
    }

    nonisolated private static func primaryResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        let preferred: [PHAssetResourceType] = asset.mediaType == .video
            ? [.fullSizeVideo, .video]
            : [.fullSizePhoto, .photo]
        return resources.first(where: { preferred.contains($0.type) }) ?? resources.first
    }

    nonisolated private static func assetBaseName(_ asset: PHAsset) -> String {
        if let name = primaryResource(for: asset)?.originalFilename, !name.isEmpty {
            return ((name as NSString).deletingPathExtension).lowercased()
        }
        return ((fallbackName(for: asset) as NSString).deletingPathExtension).lowercased()
    }

    nonisolated private static func fallbackName(for asset: PHAsset) -> String {
        let date = asset.creationDate ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let ext = asset.mediaType == .video ? "mov" : "jpg"
        return "IMG_\(formatter.string(from: date)).\(ext)"
    }

    private static func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func fetchAssets(includeVideos: Bool) async -> [PHAsset] {
        await Task.detached(priority: .utility) {
            let collections = PHAssetCollection.fetchAssetCollections(with: .smartAlbum,
                                                                      subtype: .smartAlbumUserLibrary,
                                                                      options: nil)
            guard let collection = collections.firstObject else { return [] }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            if includeVideos {
                options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d",
                                                Int32(PHAssetMediaType.image.rawValue),
                                                Int32(PHAssetMediaType.video.rawValue))
            } else {
                options.predicate = NSPredicate(format: "mediaType == %d",
                                                Int32(PHAssetMediaType.image.rawValue))
            }
            let result = PHAsset.fetchAssets(in: collection, options: options)
            var assets: [PHAsset] = []
            assets.reserveCapacity(result.count)
            result.enumerateObjects { asset, _, _ in
                assets.append(asset)
            }
            return assets
        }.value
    }

    private func requestAuthorizationIfNeeded() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func refreshAuthorization() {
        authorization = PhotoSyncAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func presentLimitedLibraryPicker() {
        guard authorization == .limited,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }),
              var top = scene.keyWindow?.rootViewController else {
            return
        }
        while let presented = top.presentedViewController {
            top = presented
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    private func registerObserver() {
        guard observer == nil, authorization.canRead else { return }
        let observer = PhotoLibraryObserver(manager: self)
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    private func unregisterObserver() {
        guard let observer else { return }
        PHPhotoLibrary.shared().unregisterChangeObserver(observer)
        self.observer = nil
    }

    fileprivate func photoLibraryDidChange() {
        guard isEnabled, isAppActive else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.syncNow()
        }
    }

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor [weak self] in
                self?.networkChanged(available: available, wifi: wifi)
            }
        }
        pathMonitor.start(queue: networkQueue)
    }

    private func networkChanged(available: Bool, wifi: Bool) {
        isNetworkAvailable = available
        isOnWiFi = wifi
        guard isEnabled, isAppActive, available else { return }
        if wifiOnly && !wifi {
            isWaitingForWiFi = true
            return
        }
        if isWaitingForWiFi || !didInitialScan || pendingCount > 0 || lastSyncDate == nil {
            startSyncIfPossible()
        }
    }

    private func pref(_ name: String) -> String {
        "photoSync.\(accountID).\(name)"
    }
}

private final class PhotoLibraryObserver: NSObject, PHPhotoLibraryChangeObserver {
    weak var manager: PhotoSyncManager?

    init(manager: PhotoSyncManager) {
        self.manager = manager
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            self?.manager?.photoLibraryDidChange()
        }
    }
}
