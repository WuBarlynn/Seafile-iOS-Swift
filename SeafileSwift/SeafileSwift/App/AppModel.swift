import Foundation
import Observation

enum AppPhase: Equatable {
    case loading
    case signedOut
    case signedIn
}

@MainActor
@Observable
final class AppModel {
    static weak var shared: AppModel?

    private(set) var phase: AppPhase = .loading
    private(set) var accounts: [Account] = []
    private(set) var session: Session?
    let settings = AppSettings()

    var toastMessage: String?

    private let store = AccountStore.shared
    private var didBootstrap = false

    init() {
        accounts = store.accounts
        Self.shared = self
        PhotoSyncBackgroundScheduler.shared.register()
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        #if DEBUG
        if ProcessInfo.processInfo.environment["SEAFILE_AUTOLOGIN"] == "1" {
            await debugAutoLogin()
            return
        }
        #endif

        guard let lastID = store.lastAccountID ?? store.accounts.first?.id,
              let account = store.accounts.first(where: { $0.id == lastID }),
              let token = store.token(for: account), !token.isEmpty else {
            phase = .signedOut
            return
        }
        await activate(account: account, token: token)
    }

    #if DEBUG
    private func debugAutoLogin() async {
        let environment = ProcessInfo.processInfo.environment
        let server = environment["SEAFILE_SERVER"] ?? "http://127.0.0.1:8765"
        let username = environment["SEAFILE_USER"] ?? "demo@example.com"
        let password = environment["SEAFILE_PASSWORD"] ?? "demo"
        guard let url = APIClient.serverURL(from: server) else {
            phase = .signedOut
            return
        }
        let client = APIClient(serverURL: url, token: nil)
        do {
            let token = try await client.login(username: username,
                                               password: password,
                                               otp: nil,
                                               rememberDevice: false)
            let authenticated = APIClient(serverURL: url, token: token)
            let info = try? await authenticated.accountInfo()
            let account = Account(serverURL: url,
                                  username: username,
                                  displayName: info?.name,
                                  email: info?.email)
            await signIn(account: account, token: token)
        } catch {
            phase = .signedOut
            toastMessage = "Debug login failed: \(error.localizedDescription)"
        }
    }
    #endif

    func signIn(account: Account, token: String) async {
        let stored = store.add(account, token: token)
        accounts = store.accounts
        await activate(account: stored, token: token)
    }

    func switchAccount(_ account: Account) async {
        guard let token = store.token(for: account), !token.isEmpty else {
            toastMessage = "Please sign in again for \(account.displayLabel)."
            return
        }
        phase = .loading
        session?.photoSync.stop()
        session?.offlineDownloads.cancel()
        PhotoSyncBackgroundScheduler.shared.cancel()
        session = nil
        await activate(account: account, token: token)
    }

    private func activate(account: Account, token: String) async {
        store.markUsed(id: account.id)
        accounts = store.accounts
        let newSession = Session(account: account, token: token, settings: settings)
        session = newSession
        phase = .signedIn
        await newSession.bootstrap()
        syncProfile(newSession)
    }

    private func syncProfile(_ session: Session) {
        guard let info = session.accountInfo else { return }
        store.updateProfile(id: session.account.id, displayName: info.name, email: info.email)
        accounts = store.accounts
    }

    func sessionForBackgroundTask(timeout: TimeInterval = 10) async -> Session? {
        if let session { return session }
        await bootstrap()
        let deadline = Date().addingTimeInterval(timeout)
        while session == nil, phase != .signedOut, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return session
    }

    func token(for account: Account) -> String? {
        store.token(for: account)
    }

    func signOutCurrent() {
        guard let session else { return }
        session.photoSync.stop()
        session.offlineDownloads.cancel()
        PhotoSyncBackgroundScheduler.shared.cancel()
        store.signOut(session.account)
        accounts = store.accounts
        self.session = nil
        phase = .signedOut
    }

    func removeAccount(_ account: Account) {
        let isCurrent = session?.account.id == account.id
        if isCurrent {
            session?.photoSync.stop()
            session?.offlineDownloads.cancel()
            PhotoSyncBackgroundScheduler.shared.cancel()
        }
        store.remove(account)
        accounts = store.accounts
        if isCurrent {
            session = nil
            phase = .signedOut
        }
    }

    func updateProfile(displayName: String?, email: String?) {
        guard let session else { return }
        store.updateProfile(id: session.account.id, displayName: displayName, email: email)
        accounts = store.accounts
    }
}
