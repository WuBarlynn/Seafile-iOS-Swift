import Foundation

struct RepoEncryptionInfo: Sendable, Codable {
    let encrypted: Bool
    let version: Int
    let magic: String?
    let randomKey: String?
    let salt: String?

    init?(json: [String: Any]) {
        encrypted = (json["encrypted"] as? NSNumber)?.boolValue ?? false
        if let number = json["enc_version"] as? NSNumber {
            version = number.intValue
        } else if let string = json["enc_version"] as? String,
                  let value = Int(string.split(separator: ".").first ?? "") {
            version = value
        } else {
            version = 0
        }
        if let string = json["magic"] as? String {
            magic = string
        } else if let number = json["magic"] as? NSNumber {
            magic = number.stringValue
        } else {
            magic = nil
        }
        if let string = json["random_key"] as? String, !string.isEmpty {
            randomKey = string
        } else {
            randomKey = nil
        }
        if let string = json["salt"] as? String, !string.isEmpty {
            salt = string
        } else {
            salt = nil
        }
    }
}
