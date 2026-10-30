import Foundation

enum APIError: LocalizedError, Equatable {
    case invalidServerURL
    case twoFactorRequired
    case invalidCredentials
    case unauthorized
    case forbidden
    case repoPasswordRequired
    case http(status: Int, message: String?)
    case invalidResponse
    case decoding(String)
    case network(String)
    case cancelled
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL: return String(localized: "Enter a valid server address.")
        case .twoFactorRequired: return String(localized: "Two-factor authentication is required.")
        case .invalidCredentials: return String(localized: "Wrong username or password.")
        case .unauthorized: return String(localized: "Your session has expired. Sign in again.")
        case .forbidden: return String(localized: "You do not have permission to do that.")
        case .repoPasswordRequired: return String(localized: "This library is encrypted and requires a password.")
        case let .http(status, message):
            return message ?? String(localized: "The server returned an error (HTTP \(status)).")
        case .invalidResponse: return String(localized: "The server returned an unexpected response.")
        case let .decoding(message): return String(localized: "Could not read the server response: \(message)")
        case let .network(message): return message
        case .cancelled: return String(localized: "The operation was cancelled.")
        case let .message(message): return message
        }
    }

    static func == (lhs: APIError, rhs: APIError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}
