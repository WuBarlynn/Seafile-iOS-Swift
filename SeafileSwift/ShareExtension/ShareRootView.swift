import SwiftUI

struct ShareRootView: View {
    let model: ShareModel
    @State private var showNewFolder = false
    @State private var newFolderName = ""

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Seafile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        }
        .tint(.orange)
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName
                newFolderName = ""
                Task { _ = await model.createFolder(named: name) }
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoadingItems {
            VStack(spacing: 12) {
                ProgressView()
                Text("Preparing items…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.accounts.isEmpty {
            emptyAccountsView
        } else if let count = model.uploadedCount {
            successView(count)
        } else if let repo = model.currentRepo {
            folderBrowser(repo: repo)
        } else {
            repoBrowser
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 12) {
                if model.currentRepo != nil, model.uploadedCount == nil {
                    Button {
                        Task { await model.goBack() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Back")
                }
                Button("Cancel") { model.onCancel() }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if model.currentRepo != nil, model.uploadedCount == nil {
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("New Folder")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if model.accounts.count > 1, model.uploadedCount == nil {
                Menu {
                    ForEach(model.accounts) { account in
                        Button {
                            Task { await model.selectAccount(account.id) }
                        } label: {
                            if account.id == model.selectedAccountID {
                                Label(account.label, systemImage: "checkmark")
                            } else {
                                Text(account.label)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Switch account")
            }
        }
    }

    private var repoBrowser: some View {
        List {
            Section {
                itemsSummary
                if let error = model.errorText {
                    errorRow(error)
                }
            }

            Section("Libraries") {
                if model.isLoadingRepos {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading libraries…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.writableRepos.isEmpty {
                    Text("No writable libraries are available.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.writableRepos) { repo in
                        Button {
                            Task { await model.open(repo) }
                        } label: {
                            repoRow(repo)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func folderBrowser(repo: ShareRepo) -> some View {
        List {
            Section {
                itemsSummary
                if let error = model.errorText {
                    errorRow(error)
                }
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(repo.name)
                        .fontWeight(.medium)
                    Text(model.currentPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .font(.footnote)
            }

            Section("Folders") {
                if model.isLoadingFolder {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading folders…")
                            .foregroundStyle(.secondary)
                    }
                } else if model.directories.isEmpty {
                    Text("This folder has no subfolders. You can upload here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.directories) { directory in
                        Button {
                            Task { await model.enter(directory) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.orange)
                                Text(directory.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyAccountsView: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text("No Seafile account")
                .font(.headline)
            Text("Open the Seafile app and sign in, then try sharing again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { model.onCancel() }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func successView(_ count: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 58))
                .foregroundStyle(.green)
            Text(count == 1
                 ? String(localized: "Uploaded 1 item")
                 : String(format: String(localized: "Uploaded %lld items"), count))
                .font(.headline)
            if let repo = model.currentRepo {
                Text("\(repo.name)\(model.currentPath == "/" ? "" : model.currentPath)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { model.onFinish() }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var itemsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.items.count == 1
                     ? String(localized: "1 item")
                     : String(format: String(localized: "%lld items"), model.items.count))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: model.totalSize, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.items.prefix(3))) { item in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    Text(item.name)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            if model.items.count > 3 {
                Text("and \(model.items.count - 3) more")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func repoRow(_ repo: ShareRepo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.orange)
            Text(repo.name)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if model.uploadedCount == nil,
           !model.accounts.isEmpty,
           model.currentRepo != nil {
            VStack(spacing: 10) {
                if model.isUploading {
                    ProgressView(value: model.uploadProgress)
                        .tint(.orange)
                    Text("Uploading… \(Int(model.uploadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        Task { await model.upload() }
                    } label: {
                        Label("Upload Here", systemImage: "arrow.up.circle.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.items.isEmpty)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }
}
