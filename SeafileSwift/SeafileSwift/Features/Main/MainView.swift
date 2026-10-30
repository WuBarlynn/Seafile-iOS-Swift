import SwiftUI

enum MainTab: Hashable {
    case libraries
    case starred
    case knowledge
    case activities
    case settings
}

struct MainView: View {
    let session: Session
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @State private var selection: MainTab = MainView.initialTab

    private static var initialTab: MainTab {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["SEAFILE_INITIAL_TAB"] {
        case "knowledge": return .knowledge
        case "starred": return .starred
        case "activities": return .activities
        case "settings": return .settings
        default: return .libraries
        }
        #else
        return .libraries
        #endif
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Libraries", systemImage: "books.vertical.fill", value: MainTab.libraries) {
                LibrariesView()
            }
            Tab("Starred", systemImage: "star.fill", value: MainTab.starred) {
                StarredView()
            }
            if session.wikiAvailable && settings.wikiTabEnabled {
                Tab("Knowledge", systemImage: "book.pages.fill", value: MainTab.knowledge) {
                    WikiListView()
                }
            }
            if session.activitiesAvailable {
                Tab("Activities", systemImage: "clock.arrow.circlepath", value: MainTab.activities) {
                    ActivitiesView()
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: MainTab.settings) {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(session)
        .tint(.seafileOrange)
        .onChange(of: session.offlineDownloads.lastMessage) { _, message in
            guard let message else { return }
            app.toastMessage = message
            session.offlineDownloads.clearLastMessage()
        }
        .onChange(of: app.pendingDeepLink) { _, link in
            if link != nil {
                selection = .libraries
            }
        }
        .onAppear {
            if app.pendingDeepLink != nil {
                selection = .libraries
            }
        }
        .task {
            await importPendingFile()
        }
        .onChange(of: app.pendingImportURL) { _, _ in
            Task { await importPendingFile() }
        }
    }

    private func importPendingFile() async {
        guard let url = app.pendingImportURL else { return }
        app.pendingImportURL = nil
        let destination = session.currentFolder
            ?? session.repositories.first(where: { !$0.isReadOnly && !$0.encrypted })
                .map { FolderLocation(repoID: $0.id, repoName: $0.name, path: "/") }
        guard let destination else {
            app.toastMessage = String(localized: "Create or join a writable library first.")
            try? FileManager.default.removeItem(at: url)
            return
        }
        let name = url.lastPathComponent
        do {
            _ = try await session.transfers.upload(fileURL: url,
                                                   fileName: name,
                                                   repoID: destination.repoID,
                                                   dirPath: destination.path)
            app.toastMessage = String(format: String(localized: "Uploaded %@."), name)
            selection = .libraries
        } catch {
            app.toastMessage = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: url)
    }
}
