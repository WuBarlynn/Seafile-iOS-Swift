import SwiftUI

struct SearchView: View {
    var repoID: String? = nil
    var repoName: String? = nil

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var hasSearched = false
    @State private var previewTarget: PreviewTarget?
    @State private var path = NavigationPath()

    private var searchUnavailable: Bool {
        repoID == nil && session.serverInfo != nil && !session.searchEnabled
    }

    private var title: String {
        guard let repoName else { return String(localized: "Search") }
        return String(format: String(localized: "Search in %@"), repoName)
    }

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
            }
            .navigationTitle(title)
            .searchable(text: $query,
                        prompt: repoID == nil
                            ? Text("Search files and folders")
                            : Text("Search this library"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onSubmit(of: .search) {
                Task { await runSearch() }
            }
            .onChange(of: query) { _, newValue in
                if newValue.isEmpty {
                    results = []
                    hasSearched = false
                    errorMessage = nil
                }
            }
            .navigationDestination(for: FolderRoute.self) { route in
                FolderView(repo: route.repo, path: route.path)
            }
            .fullScreenCover(item: $previewTarget) { target in
                PreviewScreen(target: target)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if searchUnavailable {
            EmptyStateCard(icon: "magnifyingglass",
                           title: "Server search is not available",
                           message: "Global file search requires a Seafile Professional server with the file search feature enabled.")
                .padding(.top, 12)
        } else if isSearching {
            LoadingCard(message: "Searching…")
                .padding(.top, 12)
        } else if let errorMessage {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text(LocalizedStringKey(errorMessage))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") { Task { await runSearch() } }
                    .buttonStyle(GlassProminentButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 24, padding: 22)
        } else if !hasSearched {
            EmptyStateCard(icon: "text.magnifyingglass",
                           title: repoID == nil
                               ? String(localized: "Find anything")
                               : String(localized: "Search this library"),
                           message: repoID == nil
                               ? String(localized: "Search across all your libraries by file name and content.")
                               : String(localized: "Search the files and folders in this library."))
                .padding(.top, 12)
        } else if results.isEmpty {
            EmptyStateCard(icon: "questionmark.folder",
                           title: "No results",
                           message: "No files matched “\(query)”.")
                .padding(.top, 12)
        } else {
            SectionHeader(title: String(localized: "\(results.count) results"), subtitle: "“\(query)”")
            VStack(spacing: 0) {
                ForEach(results) { result in
                    resultRow(result)
                    if result.id != results.last?.id {
                        Divider().padding(.leading, 66).opacity(0.5)
                    }
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SearchResult) -> some View {
        let repo = repository(for: result)
        Button {
            if result.isDirectory {
                path.append(FolderRoute(repo: repo, path: result.path))
            } else {
                previewTarget = PreviewTarget(searchResult: result, repo: repo)
            }
        } label: {
            HStack(spacing: 12) {
                FileIconTile(kind: FileKind.of(name: result.name, isDirectory: result.isDirectory), size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(result.repoName ?? repo.name)
                        Text("·")
                        Text(result.parentPath)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func repository(for result: SearchResult) -> Repository {
        session.repositories.first(where: { $0.id == result.repoID })
            ?? Repository(id: result.repoID, name: result.repoName ?? "Library")
    }

    private func runSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !searchUnavailable, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        hasSearched = true
        do {
            let found = try await session.api.search(keyword, repoID: repoID)
            results = found.map { item in
                var copy = item
                copy.repoName = session.repoName(for: item.repoID) ?? item.repoName
                return copy
            }
        } catch {
            results = []
            errorMessage = error.localizedDescription
        }
        isSearching = false
    }
}
