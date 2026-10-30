import SwiftUI

@main
struct SeafileApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.settings)
                .preferredColorScheme(app.settings.appearance.colorScheme)
                .tint(.seafileOrange)
        }
    }
}
