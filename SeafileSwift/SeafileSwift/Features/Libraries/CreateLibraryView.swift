import SwiftUI

struct CreateLibraryView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isEncrypted = false
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isCreating = false
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.plus")
                                    .foregroundStyle(Color.seafileOrange)
                                TextField("Library name", text: $name)
                                    .textInputAutocapitalization(.words)
                                    .focused($focused)
                                    .submitLabel(.done)
                                    .onSubmit { create() }
                            }
                            .padding(16)
                        }
                        .glassCard(cornerRadius: 22, padding: 0)

                        VStack(spacing: 14) {
                            Toggle(isOn: $isEncrypted) {
                                Label("Encrypted Library", systemImage: "lock.fill")
                                    .font(.subheadline)
                            }
                            .tint(.seafileOrange)

                            if isEncrypted {
                                Divider().opacity(0.5)
                                SecureField("Password (at least 8 characters)", text: $password)
                                    .textContentType(.newPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(.thinMaterial,
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                SecureField("Confirm Password", text: $confirmPassword)
                                    .textContentType(.newPassword)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(.thinMaterial,
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                if !confirmPassword.isEmpty, password != confirmPassword {
                                    Text("Passwords do not match.")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .glassCard(cornerRadius: 22, padding: 16)

                        if let errorMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(LocalizedStringKey(errorMessage))
                                    .font(.subheadline)
                                Spacer()
                            }
                            .glassCard(cornerRadius: 18, tint: Color.red.opacity(0.1), padding: 14)
                        }

                        Button {
                            create()
                        } label: {
                            HStack {
                                if isCreating { ProgressView().tint(.white) }
                                Text(isCreating ? "Creating…" : "Create Library")
                            }
                        }
                        .buttonStyle(GlassProminentButtonStyle())
                        .disabled(!canCreate)
                        .opacity(canCreate ? 1 : 0.6)

                        Spacer(minLength: 0)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("New Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.large])
    }

    private var canCreate: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isCreating else { return false }
        guard isEncrypted else { return true }
        return password.count >= 8 && password == confirmPassword
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard canCreate else {
            if isEncrypted, password.count < 8 {
                errorMessage = String(localized: "Password must be at least 8 characters.")
            } else if isEncrypted, password != confirmPassword {
                errorMessage = String(localized: "Passwords do not match.")
            }
            return
        }
        isCreating = true
        errorMessage = nil
        Task {
            do {
                _ = try await session.api.createLibrary(name: trimmed,
                                                        password: isEncrypted ? password : nil)
                await session.refreshLibraries()
                if isEncrypted,
                   let repo = session.repositories.first(where: {
                       $0.name == trimmed && $0.encrypted
                   }) {
                    try? await session.unlockRepo(repo.id,
                                                  password: password,
                                                  remember: true)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isCreating = false
        }
    }
}
