import SwiftUI

struct AccountSwitcherView: View {
    @Environment(AppModel.self) private var app
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var showLogin = false
    @State private var loginAccount: Account?
    @State private var showSignOutConfirm = false

    private var accounts: [Account] {
        var list = app.accounts
        if !list.contains(where: { $0.id == session.account.id }) {
            list.insert(session.account, at: 0)
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(accounts) { account in
                            if account.id == session.account.id {
                                accountRow(account, isCurrent: true)
                                    .contextMenu {
                                        Button {
                                            loginAccount = account
                                            showLogin = true
                                        } label: {
                                            Label("Edit Account", systemImage: "pencil")
                                        }
                                    }
                            } else {
                                Button {
                                    if app.token(for: account) == nil {
                                        loginAccount = account
                                        showLogin = true
                                    } else {
                                        Task {
                                            await app.switchAccount(account)
                                            dismiss()
                                        }
                                    }
                                } label: {
                                    accountRow(account, isCurrent: false)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        loginAccount = account
                                        showLogin = true
                                    } label: {
                                        Label("Edit Account", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        app.removeAccount(account)
                                    } label: {
                                        Label("Remove Account", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        Button {
                            loginAccount = nil
                            showLogin = true
                        } label: {
                            Label("Add Account", systemImage: "plus")
                        }
                        .buttonStyle(GlassProminentButtonStyle())
                        .padding(.top, 6)

                        Button(role: .destructive) {
                            showSignOutConfirm = true
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .glassEffect(.regular.tint(Color.red.opacity(0.08)), in: .rect(cornerRadius: 20))
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loginAccount = nil
                        showLogin = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Account")
                }
            }
            .fullScreenCover(isPresented: $showLogin, onDismiss: { loginAccount = nil }) {
                LoginView(account: loginAccount)
            }
            .fullScreenCover(isPresented: $showSignOutConfirm) {
                FullScreenConfirmationView(
                    icon: "rectangle.portrait.and.arrow.right",
                    title: String(localized: "Sign out of \(session.account.displayLabel)?"),
                    message: String(localized: "You will need to sign in again. Your files stay on the server."),
                    confirmTitle: String(localized: "Sign Out")
                ) {
                    dismiss()
                    app.signOutCurrent()
                }
            }
        }
    }

    private func accountRow(_ account: Account, isCurrent: Bool) -> some View {
        HStack(spacing: 14) {
            AccountAvatar(initials: account.initials,
                          size: 46,
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
                if account.isSSO {
                    Text("Single Sign-On")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.seafileOrange)
            }
        }
        .glassCard(cornerRadius: 22, padding: 14)
        .contentShape(Rectangle())
    }
}
