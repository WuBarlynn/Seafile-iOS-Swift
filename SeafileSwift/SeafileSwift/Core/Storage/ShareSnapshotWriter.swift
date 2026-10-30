import Foundation

@MainActor
enum ShareSnapshotWriter {
    static func write(accounts: [Account], lastAccountID: String?) {
        var shared: [SharedAccount] = []
        for account in accounts {
            guard let token = CredentialStore.token(for: account.id), !token.isEmpty else { continue }
            shared.append(SharedAccount(id: account.id,
                                        serverURL: account.serverAddress,
                                        username: account.username,
                                        displayName: account.displayName,
                                        email: account.email,
                                        token: token,
                                        allowUntrustedCertificate: account.allowUntrustedCertificate,
                                        isSSO: account.isSSO,
                                        lastUsed: account.lastUsed))
        }
        ShareSessionStore.save(SharedAccountsFile(accounts: shared, lastAccountID: lastAccountID))
    }
}
