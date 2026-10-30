import SwiftUI

struct PhotoSyncLibraryPicker: View {
    let selectedRepoID: String?
    let onSelect: (Repository) -> Void

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    private var sections: [RepositorySection] {
        session.repositorySections.compactMap { section in
            let repositories = section.repositories.filter { !$0.encrypted && !$0.isReadOnly }
            guard !repositories.isEmpty else { return nil }
            return RepositorySection(id: section.id,
                                     title: section.title,
                                     repositories: repositories)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if sections.isEmpty {
                            EmptyStateCard(icon: "folder.badge.questionmark",
                                           title: "No available libraries",
                                           message: String(localized: "Create or join a writable library first."))
                                .padding(.top, 20)
                        } else {
                            ForEach(sections) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionHeader(title: section.title,
                                                  subtitle: "\(section.repositories.count)")
                                    VStack(spacing: 8) {
                                        ForEach(section.repositories) { repository in
                                            Button {
                                                onSelect(repository)
                                                dismiss()
                                            } label: {
                                                row(for: repository)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Choose Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(for repository: Repository) -> some View {
        HStack(spacing: 12) {
            FileIconTile(kind: .folder, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(repository.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(repository.ownerName ?? String(localized: "Library"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if repository.id == selectedRepoID {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.seafileOrange)
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .glassCard(cornerRadius: 20, padding: 14)
        .contentShape(Rectangle())
    }
}
