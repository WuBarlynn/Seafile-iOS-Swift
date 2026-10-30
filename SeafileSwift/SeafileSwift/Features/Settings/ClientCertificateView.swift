import SwiftUI

struct ClientCertificateView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var pendingData: Data?
    @State private var password = ""
    @State private var certificateName: String?
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var showRemoveConfirm = false

    private var hasCertificate: Bool { certificateName != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        statusCard

                        if pendingData != nil {
                            passwordCard
                        }

                        Button {
                            showImporter = true
                        } label: {
                            Label(pendingData == nil ? "Import Certificate" : "Choose Another File",
                                  systemImage: "square.and.arrow.down")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))

                        if hasCertificate {
                            Button(role: .destructive) {
                                showRemoveConfirm = true
                            } label: {
                                Label("Remove Certificate", systemImage: "trash")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .glassEffect(.regular.tint(Color.red.opacity(0.08)), in: .rect(cornerRadius: 16))
                        }

                        Text("The certificate is used for server client-certificate authentication and is stored only in the iOS Keychain.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 12)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Client Certificate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let access = url.startAccessingSecurityScopedResource()
                    defer {
                        if access { url.stopAccessingSecurityScopedResource() }
                    }
                    do {
                        pendingData = try Data(contentsOf: url)
                        password = ""
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Remove client certificate?", isPresented: $showRemoveConfirm) {
                Button("Remove", role: .destructive) {
                    ClientCertificateStore.removeCertificate()
                    refresh()
                    toast = String(localized: "Client certificate removed.")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Server connections that require this certificate will fail until you import it again.")
            }
            .seafileToast($toast)
            .onAppear(perform: refresh)
        }
        .presentationDetents([.medium, .large])
    }

    private var statusCard: some View {
        VStack(spacing: 10) {
            Image(systemName: hasCertificate ? "checkmark.shield.fill" : "key.viewfinder")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(hasCertificate ? Color.green : Color.seafileOrange)
            Text(LocalizedStringKey(hasCertificate ? "Certificate Installed" : "No Client Certificate"))
                .font(.headline)
            if let certificateName {
                Text(certificateName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 24, padding: 22)
    }

    private var passwordCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Certificate Password")
                .font(.subheadline.weight(.medium))
            SecureField("Password (leave empty if none)", text: $password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let errorMessage {
                Text(LocalizedStringKey(errorMessage))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                importCertificate()
            } label: {
                Label("Import Certificate", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(GlassProminentButtonStyle())
        }
        .glassCard(cornerRadius: 22, padding: 16)
    }

    private func refresh() {
        certificateName = ClientCertificateStore.summary()
    }

    private func importCertificate() {
        guard let data = pendingData else { return }
        do {
            try ClientCertificateStore.importPKCS12(data: data, password: password)
            pendingData = nil
            password = ""
            errorMessage = nil
            refresh()
            toast = String(localized: "Client certificate imported.")
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
