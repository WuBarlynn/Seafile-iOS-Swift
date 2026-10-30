import SwiftUI

struct ActivitiesView: View {
    @Environment(Session.self) private var session

    @State private var path = NavigationPath()
    @State private var previewTarget: PreviewTarget?
    @State private var batchEvent: ActivityEvent?

    private var activitiesUnavailable: Bool {
        session.serverInfo != nil && !session.activitiesAvailable
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                SeafileBackground()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        content
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable {
                    await session.loadActivities(reset: true)
                }
            }
            .navigationTitle("Activities")
            .task {
                if session.activities.isEmpty && !activitiesUnavailable {
                    await session.loadActivities(reset: true)
                }
            }
            .navigationDestination(for: FolderRoute.self) { route in
                FolderView(repo: route.repo, path: route.path)
            }
            .fullScreenCover(item: $previewTarget) { target in
                PreviewScreen(target: target)
            }
            .sheet(item: $batchEvent) { event in
                ActivityBatchDetailsView(event: event)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if activitiesUnavailable {
            EmptyStateCard(icon: "clock.badge.exclamationmark",
                           title: "Activities are unavailable",
                           message: "Activity history requires a Seafile Professional server.")
                .padding(.top, 12)
        } else if session.isLoadingActivities && session.activities.isEmpty {
            LoadingCard(message: "Loading activities…")
                .padding(.top, 12)
        } else if let error = session.activitiesError, session.activities.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text(LocalizedStringKey(error))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await session.loadActivities(reset: true) }
                }
                .buttonStyle(GlassProminentButtonStyle())
            }
            .frame(maxWidth: .infinity)
            .glassCard(cornerRadius: 24, padding: 22)
        } else if session.activities.isEmpty {
            EmptyStateCard(icon: "clock.arrow.circlepath",
                           title: "No activities yet",
                           message: "Changes in your libraries will appear here.")
                .padding(.top, 12)
        } else {
            ForEach(session.activities) { event in
                ActivityCard(event: event, onOpen: canOpen(event) ? { open(event) } : nil)
                    .onAppear {
                        if event.id == session.activities.last?.id {
                            Task { await session.loadActivities(reset: false) }
                        }
                    }
            }
            if session.isLoadingActivities {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading more…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }
        }
    }

    private func repository(for event: ActivityEvent) -> Repository? {
        if let repoID = event.repoID,
           let repo = session.repositories.first(where: { $0.id == repoID }) {
            return repo
        }
        if let name = event.repoName, !name.isEmpty {
            return session.repositories.first(where: { $0.name == name })
        }
        return nil
    }

    private func eventPath(_ event: ActivityEvent) -> String? {
        if let path = event.path, !path.isEmpty { return path }
        return event.details.first?.path
    }

    private func canOpen(_ event: ActivityEvent) -> Bool {
        let op = event.opType ?? ""
        if ["batch_create", "batch_delete"].contains(op) {
            return !event.details.isEmpty
        }
        guard repository(for: event) != nil else { return false }
        if ["delete", "clean-up-trash"].contains(op) { return false }
        switch event.objType {
        case "repo":
            return true
        case "file", "dir", "draft":
            return eventPath(event)?.isEmpty == false
        default:
            return false
        }
    }

    private func open(_ event: ActivityEvent) {
        if ["batch_create", "batch_delete"].contains(event.opType ?? "") {
            batchEvent = event
            return
        }
        guard let repo = repository(for: event) else { return }
        if event.objType == "repo" {
            path.append(FolderRoute(repo: repo, path: "/"))
            return
        }
        guard let rawPath = eventPath(event), !rawPath.isEmpty else { return }
        let targetPath = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        if event.objType == "dir" {
            path.append(FolderRoute(repo: repo, path: targetPath))
            return
        }
        guard event.objType == "file" || event.objType == "draft" else { return }
        let name = event.name ?? (targetPath as NSString).lastPathComponent
        previewTarget = PreviewTarget(repo: repo,
                                      path: targetPath,
                                      name: name,
                                      size: 0,
                                      modified: event.time,
                                      version: String(event.time?.timeIntervalSince1970 ?? 0))
    }
}

private struct ActivityCard: View {
    let event: ActivityEvent
    var onOpen: (() -> Void)? = nil

    var body: some View {
        Group {
            if let onOpen {
                Button(action: onOpen) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.authorName ?? String(localized: "Someone"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(DisplayFormat.relative(event.time))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(event.summary)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                if let detail = event.detailText, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let repo = event.repoName, !repo.isEmpty {
                    Label(repo, systemImage: "books.vertical")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .glassCard(cornerRadius: 20, padding: 14)
    }

    @ViewBuilder
    private var avatar: some View {
        if let url = event.avatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    fallbackAvatar
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())
        } else {
            fallbackAvatar
        }
    }

    private var fallbackAvatar: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color.seafileAmber, Color.seafileOrange],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
            Text(String((event.authorName ?? "S").prefix(1)).uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 38, height: 38)
    }
}

private struct ActivityBatchDetailsView: View {
    let event: ActivityEvent

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(event.summary)
                                .font(.headline)
                            Text(String(format: String(localized: "%lld items"), event.details.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(cornerRadius: 22, padding: 16)

                        VStack(spacing: 0) {
                            ForEach(event.details) { detail in
                                HStack(spacing: 12) {
                                    Image(systemName: detail.objType == "dir"
                                          ? "folder.fill"
                                          : "doc.fill")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(Color.seafileOrange)
                                        .frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(detail.displayName)
                                            .font(.body.weight(.medium))
                                            .lineLimit(1)
                                        if let path = detail.path, !path.isEmpty {
                                            Text(path)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                if detail.id != event.details.last?.id {
                                    Divider().padding(.leading, 58).opacity(0.5)
                                }
                            }
                        }
                        .glassCard(cornerRadius: 22, padding: 0)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Batch Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
