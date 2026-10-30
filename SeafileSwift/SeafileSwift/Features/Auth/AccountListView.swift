import SwiftUI

struct AccountListView: View {
    @Environment(AppModel.self) private var app
    @State private var showLogin = false
    @State private var showSSO = false
    @State private var showClientCertificate = false
    @State private var loginAccount: Account?

    var body: some View {
        ZStack {
            SeafileBackground()
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        BrandHeader()
                        if !app.accounts.isEmpty {
                            Text("Welcome back")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                        }
                    }
                    .padding(.top, 48)

                    if !app.accounts.isEmpty {
                        VStack(spacing: 12) {
                            ForEach(app.accounts) { account in
                                accountCard(account)
                            }
                        }
                        .transition(.opacity)
                    }

                    VStack(spacing: 12) {
                        Button {
                            loginAccount = nil
                            showLogin = true
                        } label: {
                            Label(LocalizedStringKey(app.accounts.isEmpty ? "Add Account" : "Add Another Account"),
                                  systemImage: "plus")
                        }
                        .buttonStyle(GlassProminentButtonStyle())

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

                        Button {
                            showClientCertificate = true
                        } label: {
                            Label("Client Certificate", systemImage: "key.viewfinder")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    Text("Your libraries stay on your own Seafile server. Seafile is open source.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 48)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showLogin, onDismiss: { loginAccount = nil }) {
            LoginView(account: loginAccount)
        }
        .sheet(isPresented: $showSSO) {
            SSOLoginView { account, token in
                showSSO = false
                Task { await app.signIn(account: account, token: token) }
            }
        }
        .sheet(isPresented: $showClientCertificate) {
            ClientCertificateView()
        }
    }

    private func accountCard(_ account: Account) -> some View {
        Button {
            if app.token(for: account) != nil {
                Task { await app.switchAccount(account) }
            } else {
                loginAccount = account
                showLogin = true
            }
        } label: {
            HStack(spacing: 14) {
                AccountAvatar(initials: account.initials,
                              size: 48,
                              account: account,
                              token: app.token(for: account))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayLabel)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(account.serverAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .glassCard(cornerRadius: 24, padding: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                app.removeAccount(account)
            } label: {
                Label("Remove Account", systemImage: "trash")
            }
        }
    }
}
