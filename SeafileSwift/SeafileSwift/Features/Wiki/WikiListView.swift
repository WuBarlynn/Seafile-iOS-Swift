import SwiftUI

struct WikiRoute: Hashable {
    let wiki: WikiInfo
}

struct WikiListView: View {
    @Environment(Session.self) private var session

    @State private var sections: [WikiSection] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var path = NavigationPath()

    @State private var renameTarget: WikiInfo?
    @State private var renameText = ""
    @State private var showRename = false

    @State private var publishTarget: WikiInfo?
    @State private var publishText = ""
    @State private var showPublish = false

    @State private var unpublishTarget: WikiInfo?
    @State private var showUnpublish = false

    @State private var deleteTarget: WikiInfo?
    @State private var showDelete = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SeafileBackground()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await load() }
            }
            .navigationTitle("Knowledge Base")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .navigationDestination(for: WikiRoute.self) { route in
                WikiWebScreen(wiki: route.wiki)
            }
            .task {
                if sections.isEmpty { await load() }
                #if DEBUG
                if ProcessInfo.processInfo.environment["SEAFILE_OPEN_FIRST_WIKI"] == "1",
                   path.isEmpty,
                   let first = sections.first?.wikis.first {
                    path.append(WikiRoute(wiki: first))
                }
                #endif
            }
            .alert("Rename Wiki", isPresented: $showRename) {
                TextField("Wiki name", text: $renameText)
                Button("Save") { performRename() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a new name for “\(renameTarget?.name ?? "")”.")
            }
            .alert("Publish Wiki", isPresented: $showPublish) {
                TextField("Publish URL", text: $publishText)
                Button("Publish") { performPublish() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Use the full publish URL provided by your Seafile server, for example https://your-server/wiki/publish/my-wiki.")
            }
            .confirmationDialog("Unpublish “\(unpublishTarget?.name ?? "")”?",
                                isPresented: $showUnpublish,
                                titleVisibility: .visible) {
                Button("Unpublish", role: .destructive) { performUnpublish() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The public link will stop working.")
            }
            .confirmationDialog("Delete “\(deleteTarget?.name ?? "")”?",
                                isPresented: $showDelete,
                                titleVisibility: .visible) {
                Button("Delete Wiki", role: .destructive) { performDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the wiki and all of its pages. This action cannot be undone.")
            }
            .seafileToast($toast)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && sections.isEmpty {
            LoadingCard(message: "Loading knowledge base…")
                .padding(.top, 12)
        } else if let errorMessage, sections.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(LocalizedStringKey(errorMessage))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await load() }
                }
                .buttonStyle(GlassProminentButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 24, padding: 22)
        } else if sections.isEmpty {
            EmptyStateCard(icon: "book.closed",
                           title: "No wikis yet",
                           message: "Wikis created on your Seafile server will appear here. You can create and edit pages in the web interface.")
                .padding(.top, 12)
        } else {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: section.title, subtitle: "\(section.wikis.count)")
                    VStack(spacing: 0) {
                        ForEach(section.wikis) { wiki in
                            wikiRow(wiki)
                            if wiki.id != section.wikis.last?.id {
                                Divider().padding(.leading, 66).opacity(0.5)
                            }
                        }
                    }
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
    }

    private func wikiRow(_ wiki: WikiInfo) -> some View {
        HStack(spacing: 10) {
            Button {
                path.append(WikiRoute(wiki: wiki))
            } label: {
                HStack(spacing: 12) {
                    wikiIcon(wiki)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(wiki.name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let owner = wiki.displayOwner {
                                Text(owner)
                                Text("·")
                            }
                            Text(DisplayFormat.relative(wiki.updatedAt))
                            if wiki.isPublished {
                                Label("Published", systemImage: "globe")
                                    .labelStyle(.titleAndIcon)
                                    .font(.caption2)
                                    .foregroundStyle(Color.seafileOrange)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if wiki.canEdit {
                Menu {
                    Button {
                        path.append(WikiRoute(wiki: wiki))
                    } label: {
                        Label("Open", systemImage: "safari")
                    }
                    Button {
                        renameText = wiki.name
                        renameTarget = wiki
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    if wiki.isPublished {
                        Button {
                            unpublishTarget = wiki
                            showUnpublish = true
                        } label: {
                            Label("Unpublish", systemImage: "globe.badge.chevron.backward")
                        }
                    } else {
                        Button {
                            publishText = wiki.publicURL ?? ""
                            publishTarget = wiki
                            showPublish = true
                        } label: {
                            Label("Publish", systemImage: "globe")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteTarget = wiki
                        showDelete = true
                    } label: {
                        Label("Delete Wiki", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func wikiIcon(_ wiki: WikiInfo) -> some View {
        let color = Color(hex: wiki.color ?? "#FF9800")
        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [color.opacity(0.8), color],
                                     startPoint: .topLeading,
                                     endPoint: .bottomTrailing))
            Image(systemName: "book.closed.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 40, height: 40)
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        do {
            sections = try await session.api.wikiSections()
            errorMessage = nil
        } catch {
            if sections.isEmpty {
                errorMessage = error.localizedDescription
            } else {
                toast = error.localizedDescription
            }
        }
        isLoading = false
    }

    private func performRename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != target.name else { return }
        Task {
            do {
                try await session.api.renameWiki(id: target.id, name: name)
                await load()
                toast = String(localized: "Wiki renamed.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func performDelete() {
        guard let target = deleteTarget else { return }
        Task {
            do {
                try await session.api.deleteWiki(id: target.id)
                await load()
                toast = String(localized: "Wiki deleted.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func performPublish() {
        guard let target = publishTarget else { return }
        let url = publishText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task {
            do {
                try await session.api.publishWiki(id: target.id, publishURL: url)
                await load()
                toast = String(localized: "Wiki published.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private func performUnpublish() {
        guard let target = unpublishTarget else { return }
        Task {
            do {
                try await session.api.unpublishWiki(id: target.id)
                await load()
                toast = String(localized: "Wiki unpublished.")
            } catch {
                toast = error.localizedDescription
            }
        }
    }
}
