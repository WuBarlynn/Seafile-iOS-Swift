import Foundation
import Observation

@MainActor
@Observable
final class LoginModel {
    var serverAddress: String
    var username: String
    var password = ""
    var otp = ""
    var rememberDevice = false
    var allowUntrusted: Bool

    var isSubmitting = false
    var requiresOTP = false
    var errorMessage: String?

    private let editingAccount: Account?

    init(account: Account? = nil) {
        editingAccount = account
        serverAddress = account?.serverAddress ?? ""
        username = account?.username ?? ""
        allowUntrusted = account?.allowUntrustedCertificate ?? false
    }

    var canSubmit: Bool {
        !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        (!requiresOTP || !otp.isEmpty) &&
        !isSubmitting
    }

    func submit() async -> (Account, String)? {
        guard canSubmit else { return nil }
        errorMessage = nil
        isSubmitting = true
        defer { isSubmitting = false }

        guard let url = APIClient.serverURL(from: serverAddress) else {
            errorMessage = String(localized: "Enter a valid server address, for example https://cloud.seafile.com.")
            return nil
        }

        let client = APIClient(serverURL: url, token: nil, allowUntrusted: allowUntrusted)
        do {
            let token = try await client.login(username: username.trimmingCharacters(in: .whitespaces),
                                               password: password,
                                               otp: requiresOTP ? otp : nil,
                                               rememberDevice: rememberDevice)
            let authenticated = APIClient(serverURL: url, token: token, allowUntrusted: allowUntrusted)
            let info = try? await authenticated.accountInfo()
            let account = Account(serverURL: url,
                                  username: username.trimmingCharacters(in: .whitespaces),
                                  displayName: info?.name,
                                  email: info?.email,
                                  allowUntrustedCertificate: allowUntrusted)
            return (account, token)
        } catch APIError.twoFactorRequired {
            requiresOTP = true
            errorMessage = nil
        } catch APIError.invalidCredentials {
            errorMessage = requiresOTP ? String(localized: "The verification code is incorrect.") : String(localized: "Wrong username or password.")
        } catch APIError.unauthorized {
            errorMessage = String(localized: "This account is not authorized.")
        } catch {
            errorMessage = error.localizedDescription
        }
        return nil
    }
}
