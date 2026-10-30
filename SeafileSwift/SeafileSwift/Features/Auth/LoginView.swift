import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var model: LoginModel
    @State private var showPassword = false
    @State private var showSSO = false
    @State private var showClientCertificate = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case server, username, password, otp
    }

    init(account: Account? = nil) {
        _model = State(initialValue: LoginModel(account: account))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    VStack(spacing: 20) {
                        header
                        credentialsCard
                        optionsCard
                        if let error = model.errorMessage {
                            errorCard(error)
                        }
                        signInButton
                        ssoButton
                        footer
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(model.requiresOTP ? LocalizedStringKey("Two-Step Verification") : LocalizedStringKey("Add Account"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showClientCertificate = true
                    } label: {
                        Image(systemName: "key.viewfinder")
                    }
                    .accessibilityLabel("Client Certificate")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .sheet(isPresented: $showSSO) {
                SSOLoginView(serverAddress: model.serverAddress,
                             allowUntrusted: model.allowUntrusted) { account, token in
                    showSSO = false
                    Task {
                        await app.signIn(account: account, token: token)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showClientCertificate) {
                ClientCertificateView()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            SeafileSymbol(size: 62)
            Text(LocalizedStringKey(model.requiresOTP ? "Enter your verification code" : "Connect to your Seafile server"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey(model.requiresOTP
                 ? "Open your authenticator app and enter the six-digit code."
                 : "Sign in with your account on the server."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    private var credentialsCard: some View {
        VStack(spacing: 0) {
            fieldRow(icon: "server.rack") {
                TextField("https://cloud.seafile.com", text: $model.serverAddress)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .server)
                    .submitLabel(.next)
                    .onSubmit { focus = .username }
                    .disabled(model.isSubmitting)
            }
            divider
            fieldRow(icon: "person.fill") {
                TextField("Email or username", text: $model.username)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .username)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .disabled(model.isSubmitting)
            }
            divider
            fieldRow(icon: "key.fill") {
                Group {
                    if showPassword {
                        TextField("Password", text: $model.password)
                    } else {
                        SecureField("Password", text: $model.password)
                    }
                }
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .password)
                .submitLabel(model.requiresOTP ? .next : .go)
                .onSubmit {
                    if model.requiresOTP { focus = .otp } else { submit() }
                }
                .disabled(model.isSubmitting)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
            if model.requiresOTP {
                divider
                fieldRow(icon: "lock.shield.fill") {
                    TextField("Verification code", text: $model.otp)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .focused($focus, equals: .otp)
                        .disabled(model.isSubmitting)
                }
            }
        }
        .glassCard(cornerRadius: 24, padding: 4)
    }

    private func fieldRow<Content: View>(icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.seafileOrange)
                .frame(width: 24)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Divider()
            .padding(.leading, 50)
            .opacity(0.5)
    }

    private var optionsCard: some View {
        VStack(spacing: 14) {
            Toggle(isOn: $model.allowUntrusted) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Allow untrusted certificates")
                        .font(.subheadline.weight(.medium))
                    Text("Only for servers with self-signed certificates you trust.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(.seafileOrange)
            .disabled(model.isSubmitting)

            if model.requiresOTP {
                Toggle(isOn: $model.rememberDevice) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember this device")
                            .font(.subheadline.weight(.medium))
                        Text("Skip verification next time on this device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.seafileOrange)
                .disabled(model.isSubmitting)
            }
        }
        .glassCard(cornerRadius: 20, padding: 16)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .glassCard(cornerRadius: 18, tint: Color.red.opacity(0.10), padding: 14)
    }

    private var signInButton: some View {
        Button {
            submit()
        } label: {
            HStack(spacing: 8) {
                if model.isSubmitting {
                    ProgressView().tint(.white)
                }
                Text(LocalizedStringKey(model.isSubmitting ? "Connecting…" : (model.requiresOTP ? "Verify" : "Sign In")))
            }
        }
        .buttonStyle(GlassProminentButtonStyle())
        .disabled(!model.canSubmit)
        .opacity(model.canSubmit ? 1 : 0.6)
    }

    private var ssoButton: some View {
        Button {
            showSSO = true
        } label: {
            Label("Sign in with Single Sign-On", systemImage: "person.badge.key.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .disabled(model.isSubmitting)
    }

    private var footer: some View {
        Text("Your password is used only to obtain an access token and is never stored on this device.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(.top, 4)
    }

    private func submit() {
        focus = nil
        Task {
            guard let result = await model.submit() else { return }
            await app.signIn(account: result.0, token: result.1)
            dismiss()
        }
    }
}
