import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAppLocked = UserDefaults.standard.object(forKey: AppSettingsKeys.biometricUnlock) as? Bool ?? false

    var body: some View {
        @Bindable var app = app
        ZStack {
            Group {
                switch app.phase {
            case .loading:
                SplashView()
                    .transition(.opacity)
            case .signedOut:
                AccountListView()
                    .transition(.opacity)
                case .signedIn:
                    if let session = app.session {
                        MainView(session: session)
                            .id(session.id)
                            .transition(.opacity)
                    } else {
                        AccountListView()
                    }
                }
            }
            .seafileToast($app.toastMessage)

            if isAppLocked {
                AppLockView {
                    isAppLocked = false
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .animation(.smooth(duration: 0.35), value: app.phase)
        .animation(.smooth(duration: 0.25), value: isAppLocked)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                app.session?.photoSync.resume()
            } else {
                app.session?.photoSync.pause()
            }
            if newPhase == .background {
                PhotoSyncBackgroundScheduler.shared.schedule()
            }
            if newPhase == .background, app.settings.biometricUnlockEnabled {
                isAppLocked = true
            }
        }
        .task {
            await app.bootstrap()
            if scenePhase == .background {
                PhotoSyncBackgroundScheduler.shared.schedule()
            }
        }
        .onOpenURL { url in
            app.handleIncomingURL(url)
        }
    }
}

struct SplashView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            SeafileBackground()
            VStack(spacing: 18) {
                SeafileSymbol(size: 92)
                    .scaleEffect(appeared ? 1 : 0.86)
                    .opacity(appeared ? 1 : 0)
                Text("Seafile")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .opacity(appeared ? 1 : 0)
                ProgressView()
                    .tint(.seafileOrange)
                    .padding(.top, 8)
            }
        }
        .onAppear {
            withAnimation(.smooth(duration: 0.5)) { appeared = true }
        }
    }
}
