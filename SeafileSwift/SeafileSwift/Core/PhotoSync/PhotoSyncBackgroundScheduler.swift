import BackgroundTasks
import Foundation

@MainActor
final class PhotoSyncBackgroundScheduler {
    static let shared = PhotoSyncBackgroundScheduler()

    private static let refreshIdentifier = "com.seafile.seafileSwift.photosync.refresh"
    private static let processingIdentifier = "com.seafile.seafileSwift.photosync.processing"

    private var registered = false

    func register() {
        guard !registered else { return }
        registered = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshIdentifier,
                                        using: nil) { task in
            Self.handle(task)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingIdentifier,
                                        using: nil) { task in
            Self.handle(task)
        }
    }

    func schedule() {
        guard AppModel.shared?.settings.backgroundPhotoSync == true,
              AppModel.shared?.session?.photoSync.isEnabled == true else { return }

        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(refresh)

        let processing = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(processing)
    }

    func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingIdentifier)
    }

    nonisolated private static func handle(_ task: BGTask) {
        let work = Task { @MainActor in
            guard let app = AppModel.shared,
                  app.settings.backgroundPhotoSync,
                  let manager = await app.sessionForBackgroundTask()?.photoSync,
                  manager.isEnabled else {
                task.setTaskCompleted(success: true)
                return
            }
            let success = await manager.performBackgroundSync()
            PhotoSyncBackgroundScheduler.shared.schedule()
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            Task { @MainActor in
                AppModel.shared?.session?.photoSync.cancelBackgroundSync()
                work.cancel()
            }
        }
    }
}
