import Foundation
import Security

enum ClientCertificateStore {
    private static let label = "Seafile Client Certificate"
    private static let chainService = "SeafileClientCertificate"
    private static let chainAccount = "chain"

    enum ImportError: LocalizedError {
        case invalidFile
        case incorrectPassword
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidFile:
                return String(localized: "The selected file is not a valid PKCS#12 certificate.")
            case .incorrectPassword:
                return String(localized: "The certificate password is incorrect.")
            case .keychain(let status):
                return String(format: String(localized: "Could not save the client certificate (Keychain error %lld)."),
                              status)
            }
        }
    }

    static func hasCertificate() -> Bool {
        currentIdentity() != nil
    }

    static func summary() -> String? {
        guard let identity = currentIdentity() else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    static func importPKCS12(data: Data, password: String) throws {
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password]
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess else {
            throw status == errSecAuthFailed ? ImportError.incorrectPassword : ImportError.invalidFile
        }
        guard let array = items as? [[String: Any]],
              let first = array.first,
              let identity = first[kSecImportItemIdentity as String] else {
            throw ImportError.invalidFile
        }

        removeCertificate()

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecValueRef as String: identity,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ImportError.keychain(addStatus)
        }

        let chain = first[kSecImportItemCertChain as String] as? [SecCertificate] ?? []
        saveChain(chain.map { SecCertificateCopyData($0) as Data })
    }

    static func removeCertificate() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label
        ]
        SecItemDelete(query as CFDictionary)
        SecItemDelete(chainQuery(value: nil) as CFDictionary)
    }

    static func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate else {
            return nil
        }
        return credential()
    }

    private static func credential() -> URLCredential? {
        guard let identity = currentIdentity() else { return nil }
        var certificates = chainCertificates()
        if certificates.isEmpty {
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            certificates = certificate.map { [$0] } ?? []
        }
        return URLCredential(identity: identity,
                             certificates: certificates,
                             persistence: .none)
    }

    private static func saveChain(_ chain: [Data]) {
        SecItemDelete(chainQuery(value: nil) as CFDictionary)
        guard !chain.isEmpty, let data = try? JSONEncoder().encode(chain) else { return }
        var query = chainQuery(value: data)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func chainCertificates() -> [SecCertificate] {
        var result: CFTypeRef?
        guard SecItemCopyMatching(chainQuery(value: nil, returnData: true) as CFDictionary,
                                  &result) == errSecSuccess,
              let data = result as? Data,
              let chain = try? JSONDecoder().decode([Data].self, from: data) else {
            return []
        }
        return chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }

    private static func chainQuery(value: Data?, returnData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: chainService,
            kSecAttrAccount as String: chainAccount
        ]
        if let value {
            query[kSecValueData as String] = value
        }
        if returnData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private static func currentIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result else {
            return nil
        }
        return (result as! SecIdentity)
    }
}
