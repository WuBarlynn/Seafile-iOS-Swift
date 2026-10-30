import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(Session.self) private var session
    @Environment(AppModel.self) private var app
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    @State private var showAccounts = false
    @State private var showSignOut = false
    @State private var showClearCache = false
    @State private var showClearOffline = false
    @State private var showTransfers = false
    @State private var showClientCertificate = false
    @State private var showSortOptions = false
    @State private var showPhotoSyncLibraryPicker = false
    @State private var photoSyncActionInFlight = false
    @State private var cacheSize: Int64 = 0
    @State private var offlineSize: Int64 = 0
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        accountCard
                        preferencesCard
                        photoSyncCard
                        securityCard
                        serverCard
                        storageCard
                        aboutCard
                        signOutButton
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Settings")
            .fullScreenCover(isPresented: $showAccounts) {
                AccountSwitcherView()
            }
            .fullScreenCover(isPresented: $showSignOut) {
                FullScreenConfirmationView(
                    icon: "rectangle.portrait.and.arrow.right",
                    title: String(localized: "Sign out of \(session.account.displayLabel)?"),
                    message: String(localized: "You will need to sign in again. Your files stay on the server."),
                    confirmTitle: String(localized: "Sign Out")
                ) {
                    app.signOutCurrent()
                }
            }
            .fullScreenCover(isPresented: $showSortOptions) {
                SortOptionsView(selection: Binding(get: { settings.sortKey },
                                                   set: { settings.sortKey = $0 }))
            }
            .sheet(isPresented: $showPhotoSyncLibraryPicker, onDismiss: {
                if session.photoSync.isEnabled, session.photoSync.destinationRepoID == nil {
                    Task { await session.photoSync.setEnabled(false) }
                }
            }) {
                PhotoSyncLibraryPicker(selectedRepoID: session.photoSync.destinationRepoID) { repository in
                    session.photoSync.setDestination(repository.id)
                }
            }
            .fullScreenCover(isPresented: $showClearCache) {
                FullScreenConfirmationView(
                    icon: "trash",
                    title: String(localized: "Clear downloaded files?"),
                    message: String(localized: "Downloaded files will be removed from this device. Nothing is deleted from your server."),
                    confirmTitle: String(localized: "Clear Cache")
                ) {
                    session.cache.clear()
                    cacheSize = session.cacheSize()
                    toast = String(localized: "Cache cleared.")
                }
            }
            .fullScreenCover(isPresented: $showClearOffline) {
                FullScreenConfirmationView(
                    icon: "arrow.down.circle",
                    title: String(localized: "Remove offline downloads?"),
                    message: String(localized: "Files downloaded for offline use will be removed from this device. Nothing is deleted from your server."),
                    confirmTitle: String(localized: "Remove Offline Downloads")
                ) {
                    session.offlineFiles.clear()
                    offlineSize = session.offlineFiles.totalSize()
                    toast = String(localized: "Offline downloads removed.")
                }
            }
            .fullScreenCover(isPresented: $showTransfers) {
                TransferCenterView()
            }
            .sheet(isPresented: $showClientCertificate) {
                ClientCertificateView()
            }
            .seafileToast($toast)
            .onChange(of: session.offlineDownloads.isDownloading) { _, downloading in
                if !downloading {
                    offlineSize = session.offlineFiles.totalSize()
                }
            }
            .task {
                cacheSize = session.cacheSize()
                offlineSize = session.offlineFiles.totalSize()
            }
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                AccountAvatar(initials: session.account.initials,
                              size: 52,
                              account: session.account,
                              token: session.api.token)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.account.displayLabel)
                        .font(.headline)
                        .lineLimit(1)
                    Text(session.account.accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(session.account.serverAddress)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showAccounts = true
                } label: {
                    Image(systemName: "person.2.badge.gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Manage accounts")
            }
            QuotaMeter(used: session.accountInfo?.usage, total: session.accountInfo?.totalQuota)
            if session.account.allowUntrustedCertificate {
                Label("Certificate validation is disabled for this account.", systemImage: "exclamationmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button {
                showAccounts = true
            } label: {
                Label("Switch Account", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        .glassCard(cornerRadius: 26, padding: 16)
    }

    private var preferencesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Preferences")
            VStack(spacing: 14) {
                HStack {
                    Label("Appearance", systemImage: "circle.lefthalf.filled")
                        .font(.subheadline)
                    Spacer()
                }
                Picker("Appearance", selection: Binding(get: { settings.appearance },
                                                        set: { settings.appearance = $0 })) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Text(LocalizedStringKey(preference.title)).tag(preference)
                    }
                }
                .pickerStyle(.segmented)

                Divider().opacity(0.5)

                Toggle(isOn: Binding(get: { settings.useGrid },
                                     set: { settings.useGrid = $0 })) {
                    Label("Grid layout", systemImage: "square.grid.2x2")
                        .font(.subheadline)
                }
                .tint(.seafileOrange)

                Toggle(isOn: Binding(get: { settings.sortAscending },
                                     set: { settings.sortAscending = $0 })) {
                    Label("Sort ascending", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                }
                .tint(.seafileOrange)

                HStack {
                    Label("Sort by", systemImage: "textformat.abc")
                        .font(.subheadline)
                    Spacer()
                    Button {
                        showSortOptions = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(LocalizedStringKey(settings.sortKey.title))
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Divider().opacity(0.5)

                Toggle(isOn: Binding(get: { settings.convertPhotosToJPEG },
                                     set: { settings.convertPhotosToJPEG = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Convert photos to JPEG")
                            .font(.subheadline.weight(.medium))
                        Text("HEIC/HEIF photos will be uploaded as JPEG so they open on more devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.seafileOrange)

                Divider().opacity(0.5)

                Toggle(isOn: Binding(get: { settings.uploadLivePhotos },
                                     set: { settings.uploadLivePhotos = $0 })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upload Live Photo")
                            .font(.subheadline.weight(.medium))
                        Text("Live Photos are uploaded as Motion Photos (HEIC with the video embedded). This overrides JPEG conversion for Live Photos.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.seafileOrange)
            }
        }
        .glassCard(cornerRadius: 24, padding: 16)
    }

    private var photoSyncCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Camera Upload")
            VStack(spacing: 14) {
                Toggle(isOn: photoSyncEnabledBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Upload")
                            .font(.subheadline.weight(.medium))
                        Text("Back up new photos and videos from your photo library.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.seafileOrange)
                .disabled(photoSyncActionInFlight)

                if session.photoSync.isEnabled {
                    Divider().opacity(0.5)

                    Button {
                        showPhotoSyncLibraryPicker = true
                    } label: {
                        HStack {
                            Label("Upload Destination", systemImage: "folder.badge.plus")
                                .font(.subheadline)
                            Spacer(minLength: 10)
                            Text(photoSyncDestinationName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Divider().opacity(0.5)

                    Toggle(isOn: Binding(get: { session.photoSync.uploadVideos },
                                         set: { session.photoSync.uploadVideos = $0 })) {
                        Label("Upload Videos", systemImage: "video")
                            .font(.subheadline)
                    }
                    .tint(.seafileOrange)

                    Toggle(isOn: Binding(get: { session.photoSync.wifiOnly },
                                         set: { session.photoSync.wifiOnly = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Wi-Fi Only", systemImage: "wifi")
                                .font(.subheadline)
                            Text("Wait for a Wi-Fi connection before uploading.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tint(.seafileOrange)

                    Divider().opacity(0.5)

                    HStack(alignment: .top, spacing: 10) {
                        if session.photoSync.isSyncing || session.photoSync.isScanning {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.seafileOrange)
                        } else {
                            Image(systemName: photoSyncStatusIcon)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(photoSyncStatusColor)
                                .frame(width: 16)
                        }
                        Text(session.photoSync.statusText)
                            .font(.caption)
                            .foregroundStyle(session.photoSync.lastError == nil ? Color.secondary : Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }

                    HStack {
                        Button {
                            session.photoSync.syncNow()
                        } label: {
                            Label("Sync Now", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .disabled(session.photoSync.isSyncing
                                  || session.photoSync.isScanning
                                  || session.photoSync.destinationRepoID == nil)

                        Spacer()

                        if !session.photoSync.authorization.canRead {
                            Button {
                                openURL(URL(string: UIApplication.openSettingsURLString)!)
                            } label: {
                                Text("Open Settings")
                                    .font(.caption.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.seafileOrange)
                        }
                    }

                    Text("Uploads go to the “Camera Uploads” folder. iOS may run occasional background backups while Seafile is not open.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if session.photoSync.isLimitedAccess {
                        Text("Only photos selected in system settings are backed up.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("New items are uploaded to the “Camera Uploads” folder in the library you choose.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .glassCard(cornerRadius: 24, padding: 16)
    }

    private var photoSyncEnabledBinding: Binding<Bool> {
        Binding(get: { session.photoSync.isEnabled },
                set: { enabled in
                    guard !photoSyncActionInFlight else { return }
                    photoSyncActionInFlight = true
                    Task {
                        let ok = await session.photoSync.setEnabled(enabled)
                        photoSyncActionInFlight = false
                        if !ok {
                            toast = session.photoSync.lastError
                                ?? String(localized: "Photo access is required to back up your library.")
                        } else if enabled, session.photoSync.destinationRepoID == nil {
                            showPhotoSyncLibraryPicker = true
                        }
                    }
                })
    }

    private var photoSyncDestinationName: String {
        guard let repoID = session.photoSync.destinationRepoID else {
            return String(localized: "Choose Library")
        }
        return session.repositories.first(where: { $0.id == repoID })?.name
            ?? String(localized: "Choose Library")
    }

    private var photoSyncStatusIcon: String {
        if !session.photoSync.authorization.canRead { return "hand.raised" }
        if session.photoSync.isWaitingForWiFi { return "wifi.slash" }
        if session.photoSync.isSyncing || session.photoSync.isScanning { return "arrow.up.circle" }
        if session.photoSync.lastError != nil { return "exclamationmark.triangle" }
        if session.photoSync.didInitialScan, session.photoSync.pendingCount == 0 {
            return "checkmark.circle.fill"
        }
        return "photo.stack"
    }

    private var photoSyncStatusColor: Color {
        if !session.photoSync.authorization.canRead || session.photoSync.lastError != nil {
            return .red
        }
        if session.photoSync.isWaitingForWiFi { return .orange }
        if session.photoSync.didInitialScan, session.photoSync.pendingCount == 0 {
            return .green
        }
        return .secondary
    }

    private var securityCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Security")
            VStack(spacing: 14) {
                Toggle(isOn: biometricBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Face ID Unlock")
                            .font(.subheadline.weight(.medium))
                        Text("Use Face ID or your device passcode when opening the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.seafileOrange)

                Divider().opacity(0.5)

                Toggle(isOn: Binding(get: { settings.rememberRepoPasswords },
                                     set: { enabled in
                                         settings.rememberRepoPasswords = enabled
                                         if !enabled {
                                             clearSavedPasswords()
                                         }
                                     })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save encrypted library passwords")
                            .font(.subheadline.weight(.medium))
                        Text("Passwords are stored in the Keychain on this device. If disabled, unlocked libraries lock after 30 minutes of inactivity.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.seafileOrange)

                Button(role: .destructive) {
                    clearSavedPasswords()
                } label: {
                    Label("Clear saved library passwords", systemImage: "key.slash")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .glassEffect(.regular.tint(Color.red.opacity(0.08)), in: .rect(cornerRadius: 16))

                Divider().opacity(0.5)

                Button {
                    showClientCertificate = true
                } label: {
                    HStack {
                        Label("Client Certificate", systemImage: "key.viewfinder")
                            .font(.subheadline)
                        Spacer()
                        Text(ClientCertificateStore.hasCertificate()
                             ? String(localized: "Installed")
                             : String(localized: "Not set"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard(cornerRadius: 24, padding: 16)
    }

    private var biometricBinding: Binding<Bool> {
        Binding(get: { settings.biometricUnlockEnabled },
                set: { enabled in
                    if !enabled {
                        settings.biometricUnlockEnabled = false
                        return
                    }
                    Task {
                        let ok = await BiometricAuth.authenticate(reason: String(localized: "Enable Face ID unlock"))
                        await MainActor.run {
                            if ok {
                                settings.biometricUnlockEnabled = true
                            } else {
                                settings.biometricUnlockEnabled = false
                                toast = String(localized: "Face ID is not available. Set it up in system settings first.")
                            }
                        }
                    }
                })
    }

    private func clearSavedPasswords() {
        session.discardSavedRepoPasswords()
        RepoSecretStore.deleteAllAccounts()
        toast = String(localized: "Saved passwords removed. Libraries without saved passwords lock after 30 minutes of inactivity.")
    }

    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Server")
            VStack(spacing: 10) {
                infoRow("Version", session.serverInfo?.version ?? String(localized: "Unknown"))
                Divider().opacity(0.5)
                infoRow("Edition", session.serverInfo?.isPro == true ? String(localized: "Seafile Professional") : String(localized: "Seafile Community"))
                Divider().opacity(0.5)
                infoRow("Address", session.account.serverAddress)
            }
            HStack(spacing: 8) {
                featureBadge("Search", icon: "magnifyingglass", enabled: session.searchEnabled)
                featureBadge("Activities", icon: "clock.arrow.circlepath", enabled: session.activitiesAvailable)
                featureBadge("Wiki", icon: "book.pages", enabled: session.wikiAvailable)
            }
        }
        .glassCard(cornerRadius: 24, padding: 16)
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Storage")
            Button {
                showTransfers = true
            } label: {
                HStack {
                    Label("Transfers", systemImage: "arrow.up.arrow.down")
                        .font(.subheadline)
                    Spacer()
                    if !session.transfers.activeTransfers.isEmpty {
                        Text("\(session.transfers.activeTransfers.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.seafileOrange, in: Capsule())
                    }
                    Text("View")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().opacity(0.5)

            HStack {
                Label("Cached files", systemImage: "internaldrive")
                    .font(.subheadline)
                Spacer()
                Text(DisplayFormat.fileSize(cacheSize))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                showClearCache = true
            } label: {
                Label("Clear Cache", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .glassEffect(.regular.tint(Color.red.opacity(0.08)), in: .rect(cornerRadius: 16))

            Divider().opacity(0.5)

            HStack {
                Label("Offline downloads", systemImage: "arrow.down.circle")
                    .font(.subheadline)
                Spacer()
                Text(DisplayFormat.fileSize(offlineSize))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button {
                showClearOffline = true
            } label: {
                Label("Remove Offline Downloads", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .glassEffect(.regular.tint(Color.red.opacity(0.08)), in: .rect(cornerRadius: 16))
        }
        .glassCard(cornerRadius: 24, padding: 16)
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "About")
            VStack(spacing: 10) {
                infoRow("Seafile", appVersion)
                Divider().opacity(0.5)
                Link(destination: URL(string: "https://www.seafile.com")!) {
                    HStack {
                        Label("Website", systemImage: "safari")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                }
                Divider().opacity(0.5)
                Link(destination: URL(string: "https://github.com/WuBarlynn/Seafile-iOS-Swift")!) {
                    HStack {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                }
                Divider().opacity(0.5)
                Link(destination: URL(string: "https://www.seafile.com/en/privacy_policy/")!) {
                    HStack {
                        Label("Privacy Policy", systemImage: "hand.raised")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                }
            }
        }
        .glassCard(cornerRadius: 24, padding: 16)
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            showSignOut = true
        } label: {
            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .glassEffect(.regular.tint(Color.red.opacity(0.08)), in: .rect(cornerRadius: 20))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.subheadline)
    }

    private func featureBadge(_ title: String, icon: String, enabled: Bool) -> some View {
        Label(LocalizedStringKey(title), systemImage: icon)
            .font(.caption.weight(.medium))
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(enabled ? Color.seafileOrange.opacity(0.14) : Color.gray.opacity(0.08)),
                         in: .capsule)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? APIClient.appVersion
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}
