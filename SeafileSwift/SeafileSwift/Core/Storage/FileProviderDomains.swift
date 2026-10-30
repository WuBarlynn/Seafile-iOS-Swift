import FileProvider
import Foundation

@MainActor
enum FileProviderDomains {
    private static let fingerprintKey = "settings.fileProviderDomains.fingerprint"
    private static let identifiersKey = "settings.fileProviderDomains.identifiers"

    static func sync(accounts: [Account]) {
        let fingerprint = accounts
            .map { "\($0.id)|\($0.displayLabel)" }
            .sorted()
            .joined(separator: ";")
        guard UserDefaults.standard.string(forKey: fingerprintKey) != fingerprint else { return }
        UserDefaults.standard.set(fingerprint, forKey: fingerprintKey)

        let desired = Dictionary(uniqueKeysWithValues: accounts.map {
            (FileProviderDomainID.identifier(forAccountID: $0.id), $0)
        })
        let tracked = Set(UserDefaults.standard.stringArray(forKey: identifiersKey) ?? [])

        Task { @MainActor in
            for identifier in tracked where desired[identifier] == nil {
                let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(identifier),
                                                  displayName: "Seafile")
                try? await NSFileProviderManager.remove(domain)
            }
            for (identifier, account) in desired where !tracked.contains(identifier) {
                let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(identifier),
                                                  displayName: FileProviderDomains.displayName(account))
                try? await NSFileProviderManager.add(domain)
            }
            UserDefaults.standard.set(Array(desired.keys), forKey: identifiersKey)
        }
    }

    private static func displayName(_ account: Account) -> String {
        let host = URL(string: account.serverAddress)?.host ?? account.serverAddress
        return "\(account.displayLabel) – \(host)"
    }
}
