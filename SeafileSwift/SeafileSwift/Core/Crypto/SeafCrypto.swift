import CommonCrypto
import CryptoKit
import Foundation

struct RepoCryptoKey: Sendable {
    let key: Data
    let iv: Data
    let version: Int

    init(key: Data, iv: Data, version: Int = 2) throws {
        guard key.count == 16 || key.count == 32, iv.count == kCCBlockSizeAES128 else {
            throw SeafCryptoError.invalidKey
        }
        self.key = key
        self.iv = iv
        self.version = version
    }
}

enum SeafCryptoError: LocalizedError {
    case invalidKey
    case invalidSalt
    case invalidRandomKey
    case decryptionFailed
    case encryptionFailed
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return String(localized: "The library key is invalid.")
        case .invalidSalt:
            return String(localized: "The server did not provide a valid encryption salt.")
        case .invalidRandomKey:
            return String(localized: "The server did not provide a valid library key.")
        case .decryptionFailed:
            return String(localized: "Could not decrypt this file. The library password may be incorrect.")
        case .encryptionFailed:
            return String(localized: "Could not encrypt this file.")
        case .unsupportedVersion:
            return String(localized: "This library uses an older encryption format that is not supported for local decryption yet.")
        }
    }
}

enum SeafCrypto {
    private static let salt = Data([0xda, 0x90, 0x45, 0xc3, 0x06, 0xc7, 0xcc, 0x26])
    private static let repoSaltLength = 32

    /// v2 password check value: hex(PBKDF2-SHA256(repoID + password, salt, 1000, 32)).
    static func passwordMagicV2(repoID: String, password: String) throws -> String {
        try deriveKeyAndIV(data: Data((repoID + password).utf8), salt: salt).key.hexString
    }

    /// v4 password check value uses the per-library salt instead of the fixed one.
    static func passwordMagicV4(repoID: String, password: String, saltHex: String) throws -> String {
        let repoSalt = try decodeRepoSalt(saltHex)
        return try deriveKeyAndIV(data: Data((repoID + password).utf8), salt: repoSalt).key.hexString
    }

    static func passwordMagic(repoID: String, password: String) throws -> String {
        try passwordMagicV2(repoID: repoID, password: password)
    }

    /// v1 password check value: hex(EVP_BytesToKey-SHA1(repoID + password, 2^19, 16)).
    static func passwordMagicV1(repoID: String, password: String) throws -> String {
        let derived = try evpBytesToKey(password: Data((repoID + password).utf8),
                                        iterations: 1 << 19,
                                        keyLength: 16,
                                        ivLength: 16)
        return derived.key.hexString
    }

    /// Derives the AES-256 key/IV for a v2 repository. The random key is stored
    /// encrypted with a key derived from the password; the final content key is
    /// derived from that random key.
    static func deriveRepoKey(password: String, randomKeyHex: String) throws -> RepoCryptoKey {
        try deriveRepoKey(password: password, randomKeyHex: randomKeyHex, salt: salt, version: 2)
    }

    /// v4 repositories derive every key from the 32-byte per-library salt.
    static func deriveRepoKeyV4(password: String, randomKeyHex: String, saltHex: String) throws -> RepoCryptoKey {
        try deriveRepoKey(password: password,
                          randomKeyHex: randomKeyHex,
                          salt: try decodeRepoSalt(saltHex),
                          version: 4)
    }

    private static func deriveRepoKey(password: String,
                                      randomKeyHex: String,
                                      salt: Data,
                                      version: Int) throws -> RepoCryptoKey {
        guard let encryptedRandomKey = Data(hexString: randomKeyHex),
              encryptedRandomKey.count == 48 else {
            throw SeafCryptoError.invalidRandomKey
        }

        let initial = try deriveKeyAndIV(data: Data(password.utf8), salt: salt)
        let randomKey = try aesDecrypt(encryptedRandomKey, key: initial.key, iv: initial.iv)
        guard randomKey.count == 32 else { throw SeafCryptoError.invalidRandomKey }

        let content = try deriveKeyAndIV(data: randomKey, salt: salt)
        return try RepoCryptoKey(key: content.key, iv: content.iv, version: version)
    }

    private static func deriveKeyAndIV(data: Data, salt: Data) throws -> (key: Data, iv: Data) {
        let key = try pbkdf2(password: data, salt: salt, iterations: 1000, length: 32)
        let iv = try pbkdf2(password: key, salt: salt, iterations: 10, length: 16)
        return (key, iv)
    }

    private static func decodeRepoSalt(_ hex: String) throws -> Data {
        guard let data = Data(hexString: hex), data.count == repoSaltLength else {
            throw SeafCryptoError.invalidSalt
        }
        return data
    }

    /// v1 content key: EVP_BytesToKey-SHA1(password, 2^19) with AES-128.
    static func deriveRepoKeyV1(password: String) throws -> RepoCryptoKey {
        let derived = try evpBytesToKey(password: Data(password.utf8),
                                        iterations: 1 << 19,
                                        keyLength: 16,
                                        ivLength: 16)
        return try RepoCryptoKey(key: derived.key, iv: derived.iv, version: 1)
    }

    static func encrypt(_ data: Data, with repoKey: RepoCryptoKey) throws -> Data {
        try aesCrypt(CCOperation(kCCEncrypt), data: data, key: repoKey.key, iv: repoKey.iv)
    }

    static func decrypt(_ data: Data, with repoKey: RepoCryptoKey) throws -> Data {
        guard !data.isEmpty, data.count % kCCBlockSizeAES128 == 0 else {
            throw SeafCryptoError.decryptionFailed
        }
        return try aesCrypt(CCOperation(kCCDecrypt), data: data, key: repoKey.key, iv: repoKey.iv)
    }

    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func aesDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try aesCrypt(CCOperation(kCCDecrypt), data: data, key: key, iv: iv)
    }

    private static func aesCrypt(_ operation: CCOperation, data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16 || key.count == 24 || key.count == 32, iv.count == kCCBlockSizeAES128 else {
            throw SeafCryptoError.invalidKey
        }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress,
                                key.count,
                                ivBytes.baseAddress,
                                dataBytes.baseAddress,
                                data.count,
                                outputBytes.baseAddress,
                                outputCapacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCEncrypt) ? SeafCryptoError.encryptionFailed : SeafCryptoError.decryptionFailed
        }
        return Data(output.prefix(moved))
    }

    private static func evpBytesToKey(password: Data,
                                      iterations: Int,
                                      keyLength: Int,
                                      ivLength: Int) throws -> (key: Data, iv: Data) {
        var derived = Data()
        var previous = Data()
        var first = true
        let total = keyLength + ivLength
        while derived.count < total {
            var input = Data()
            if !first { input.append(previous) }
            input.append(password)
            input.append(salt)
            var digest = sha1(input)
            if iterations > 1 {
                for _ in 1..<iterations {
                    digest = sha1(digest)
                }
            }
            derived.append(digest)
            previous = digest
            first = false
        }
        guard derived.count >= total else { throw SeafCryptoError.invalidKey }
        return (Data(derived.prefix(keyLength)),
                Data(derived.dropFirst(keyLength).prefix(ivLength)))
    }

    private static func sha1(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest)
    }

    private static func pbkdf2(password: Data, salt: Data, iterations: Int, length: Int) throws -> Data {
        var derived = Data(count: length)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.bindMemory(to: Int8.self).baseAddress,
                                         password.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress,
                                         salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                         UInt32(iterations),
                                         derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                                         length)
                }
            }
        }
        guard status == kCCSuccess else { throw SeafCryptoError.invalidKey }
        return derived
    }
}

extension Data {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count % 2 == 0 else { return nil }
        var value = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            value.append(byte)
            index = next
        }
        self = value
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
