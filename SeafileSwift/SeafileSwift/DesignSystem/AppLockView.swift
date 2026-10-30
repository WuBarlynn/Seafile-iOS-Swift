import SwiftUI

struct AppLockView: View {
    let onUnlock: () -> Void

    @State private var isAuthenticating = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            SeafileBackground()
            VStack(spacing: 16) {
                SeafileSymbol(size: 82)
                Text("Seafile")
                    .font(.largeTitle.weight(.bold))
                Text("Seafile is locked")
                    .font(.headline)
                Text("Use Face ID or your device passcode to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    authenticate()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "faceid")
                        Text(isAuthenticating ? "Authenticating…" : "Unlock with Face ID")
                    }
                }
                .buttonStyle(GlassProminentButtonStyle())
                .disabled(isAuthenticating)
                .padding(.top, 4)
            }
            .frame(maxWidth: 480)
            .glassCard(cornerRadius: 30, padding: 28)
            .padding(24)
        }
        .task {
            authenticate()
        }
    }

    private func authenticate() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        errorMessage = nil
        Task {
            let success = await BiometricAuth.authenticate(reason: String(localized: "Unlock Seafile"))
            await MainActor.run {
                isAuthenticating = false
                if success {
                    onUnlock()
                } else {
                    errorMessage = String(localized: "Face ID or passcode verification failed. Try again.")
                }
            }
        }
    }
}
