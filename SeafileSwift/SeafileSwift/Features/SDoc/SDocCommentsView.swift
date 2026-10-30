import SwiftUI
import PhotosUI
import UIKit

@MainActor
@Observable
final class SDocCommentsModel {
    struct Attachment: Identifiable, Equatable {
        enum State: Equatable {
            case uploading
            case uploaded(URL)
            case failed(String)
        }

        let id = UUID()
        let data: Data
        let fileName: String
        let mimeType: String
        var state: State

        var isReady: Bool {
            if case .uploaded = state { return true }
            return false
        }

        var isUploading: Bool {
            if case .uploading = state { return true }
            return false
        }
    }

    let pageOptions: SDocPageOptions
    let author: String
    let repoID: String
    let currentUserEmail: String
    private let client: SDocClient
    private let api: APIClient

    var comments: [SDocComment] = []
    var isLoading = false
    var hasLoaded = false
    var loadError: String?
    var isPosting = false
    var draft = ""
    var attachments: [Attachment] = []
    var busyIDs: Set<Int64> = []
    var toast: String?
    var mentionUsers: [SDocUser] = []
    var isLoadingMentions = false
    private var mentionUsersLoaded = false

    init(pageOptions: SDocPageOptions,
         author: String,
         repoID: String,
         currentUserEmail: String,
         api: APIClient,
         allowUntrusted: Bool) {
        self.pageOptions = pageOptions
        self.author = author
        self.repoID = repoID
        self.currentUserEmail = currentUserEmail
        self.api = api
        client = SDocClient(pageOptions: pageOptions, allowUntrusted: allowUntrusted)
    }

    var canSend: Bool {
        guard !isPosting else { return false }
        let hasContent = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasContent || !attachments.isEmpty else { return false }
        return attachments.allSatisfy(\.isReady)
    }

    func load() async {
        guard !isLoading else { return }
        if !hasLoaded { isLoading = true }
        defer { isLoading = false }
        do {
            let list = try await client.comments(docUUID: pageOptions.docUUID)
            comments = list.sorted { left, right in
                switch (left.createdAt, right.createdAt) {
                case let (lhs?, rhs?): return lhs < rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default: return left.id < right.id
                }
            }
            hasLoaded = true
            loadError = nil
        } catch {
            if comments.isEmpty {
                loadError = error.localizedDescription
                toast = error.localizedDescription
            }
        }
    }

    func send() async {
        guard !isPosting else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = attachments.compactMap { attachment -> URL? in
            if case .uploaded(let url) = attachment.state { return url }
            return nil
        }
        guard !text.isEmpty || !urls.isEmpty else {
            toast = String(localized: "Content is empty")
            return
        }
        guard urls.count == attachments.count else {
            toast = String(localized: "Please wait until the image upload is complete and try again.")
            return
        }

        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        for url in urls { parts.append("![](\(url.absoluteString))") }
        let comment = parts.joined(separator: "\n\n")

        isPosting = true
        defer { isPosting = false }
        do {
            try await client.postComment(docUUID: pageOptions.docUUID,
                                         comment: comment,
                                         author: author,
                                         updatedAt: Self.timestamp())
            draft = ""
            attachments.removeAll()
            await load()
        } catch {
            toast = error.localizedDescription
        }
    }

    func addImage(data: Data) {
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9) else {
            toast = String(localized: "Could not read the selected image.")
            return
        }
        let attachment = Attachment(data: jpeg,
                                    fileName: "IMG_\(UUID().uuidString).jpg",
                                    mimeType: "image/jpeg",
                                    state: .uploading)
        attachments.append(attachment)
        Task { await upload(attachment.id) }
    }

    func retry(_ id: UUID) {
        Task { await upload(id) }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    private func upload(_ id: UUID) async {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = attachments[index]
        attachments[index].state = .uploading
        do {
            let paths = try await client.uploadImage(docUUID: pageOptions.docUUID,
                                                     data: attachment.data,
                                                     fileName: attachment.fileName,
                                                     mimeType: attachment.mimeType)
            guard let path = paths.first(where: { !$0.isEmpty }),
                  let url = client.downloadImageURL(docUUID: pageOptions.docUUID, relativePath: path) else {
                throw APIError.invalidResponse
            }
            guard let current = attachments.firstIndex(where: { $0.id == id }) else { return }
            attachments[current].state = .uploaded(url)
        } catch {
            guard let current = attachments.firstIndex(where: { $0.id == id }) else { return }
            attachments[current].state = .failed(error.localizedDescription)
        }
    }

    func markResolved(_ comment: SDocComment) async {
        guard !busyIDs.contains(comment.id) else { return }
        busyIDs.insert(comment.id)
        defer { busyIDs.remove(comment.id) }
        do {
            try await client.markResolved(docUUID: pageOptions.docUUID, commentID: comment.id)
            if let index = comments.firstIndex(where: { $0.id == comment.id }) {
                comments[index].isResolved = true
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    func delete(_ comment: SDocComment) async {
        guard !busyIDs.contains(comment.id) else { return }
        busyIDs.insert(comment.id)
        defer { busyIDs.remove(comment.id) }
        do {
            try await client.deleteComment(docUUID: pageOptions.docUUID, commentID: comment.id)
            comments.removeAll { $0.id == comment.id }
        } catch {
            toast = error.localizedDescription
        }
    }

    struct MentionToken {
        let range: Range<String.Index>
        let query: String
    }

    var activeMentionToken: MentionToken? {
        let text = draft
        guard !text.isEmpty else { return nil }
        var index = text.endIndex
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character == "@" {
                if previous > text.startIndex {
                    let before = text[text.index(before: previous)]
                    guard before.isWhitespace || before.isNewline else { return nil }
                }
                let start = text.index(after: previous)
                return MentionToken(range: previous..<text.endIndex,
                                    query: String(text[start..<text.endIndex]))
            }
            if character.isWhitespace || character.isNewline { return nil }
            index = previous
        }
        return nil
    }

    var mentionSuggestions: [SDocUser] {
        guard let token = activeMentionToken else { return [] }
        let query = token.query.lowercased()
        let filtered = query.isEmpty ? mentionUsers : mentionUsers.filter { user in
            user.name.lowercased().contains(query) || user.email.lowercased().contains(query)
        }
        return Array(filtered.prefix(6))
    }

    var isMentionPickerVisible: Bool {
        activeMentionToken != nil && (!mentionUsers.isEmpty || isLoadingMentions)
    }

    func loadMentionUsersIfNeeded() async {
        guard !mentionUsersLoaded, !isLoadingMentions else { return }
        isLoadingMentions = true
        defer { isLoadingMentions = false }

        async let relatedResult = try? api.relatedUsers(repoID: repoID)
        async let participantsResult = try? api.seadocParticipants(docUUID: pageOptions.docUUID)
        let (related, participants) = await (relatedResult, participantsResult)

        mentionUsers = mergeMentionUsers(related: related ?? [], participants: participants ?? [])
        mentionUsersLoaded = true
        if related == nil && participants == nil {
            toast = String(localized: "Could not load members.")
        }
    }

    func insertMention(_ user: SDocUser) {
        guard let token = activeMentionToken else { return }
        draft.replaceSubrange(token.range, with: "@\(user.displayName) ")
    }

    private func mergeMentionUsers(related: [SDocUser], participants: [SDocUser]) -> [SDocUser] {
        let current = currentUserEmail.lowercased()
        let latest = pageOptions.latestContributor.lowercased()

        var participantMap: [String: SDocUser] = [:]
        for user in participants {
            let key = user.email.lowercased()
            guard !key.isEmpty, key != current else { continue }
            participantMap[key] = user
        }

        var sticky: SDocUser?
        var collaborators: [SDocUser] = []
        for user in related {
            let key = user.email.lowercased()
            guard !key.isEmpty, key != current, participantMap[key] == nil else { continue }
            if !latest.isEmpty, key == latest, sticky == nil {
                sticky = user
            } else {
                collaborators.append(user)
            }
        }

        collaborators.sort {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let sortedParticipants = participantMap.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        var result: [SDocUser] = []
        if let sticky { result.append(sticky) }
        result.append(contentsOf: sortedParticipants)
        result.append(contentsOf: collaborators)
        return result
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}

struct SDocCommentsView: View {
    let pageOptions: SDocPageOptions
    let documentTitle: String
    let repoID: String
    let account: Account
    let api: APIClient

    @Environment(\.dismiss) private var dismiss
    @State private var model: SDocCommentsModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: SDocImagePreviewItem?
    @FocusState private var inputFocused: Bool

    init(pageOptions: SDocPageOptions,
         documentTitle: String,
         repoID: String,
         account: Account,
         api: APIClient) {
        self.pageOptions = pageOptions
        self.documentTitle = documentTitle
        self.repoID = repoID
        self.account = account
        self.api = api
        _model = State(initialValue: SDocCommentsModel(pageOptions: pageOptions,
                                                       author: account.email ?? account.username,
                                                       repoID: repoID,
                                                       currentUserEmail: account.email ?? account.username,
                                                       api: api,
                                                       allowUntrusted: api.allowUntrusted))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if model.isLoading && !model.hasLoaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.loadError, model.comments.isEmpty {
                    ContentUnavailableView {
                        Label("Could not load comments", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await model.load() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.seafileOrange)
                    }
                } else if model.comments.isEmpty && model.hasLoaded {
                    ContentUnavailableView {
                        Label("No comments", systemImage: "bubble.left.and.bubble.right")
                    }
                } else {
                    commentsList
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(documentTitle.isEmpty ? String(localized: "Comments") : documentTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .seafileToast($model.toast)
            .task { await model.load() }
        }
        .fullScreenCover(item: $previewImage) { item in
            SDocImagePreviewScreen(url: item.url,
                                   token: api.token,
                                   allowUntrusted: api.allowUntrusted)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.addImage(data: data)
                }
                pickerItem = nil
            }
        }
        .onChange(of: model.draft) { _, _ in
            guard model.activeMentionToken != nil else { return }
            Task { await model.loadMentionUsersIfNeeded() }
        }
    }

    private var commentsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(model.comments) { comment in
                        SDocCommentRow(comment: comment,
                                       token: api.token,
                                       allowUntrusted: api.allowUntrusted,
                                       isBusy: model.busyIDs.contains(comment.id),
                                       imageURL: imageURL,
                                       onResolve: { Task { await model.markResolved(comment) } },
                                       onDelete: { Task { await model.delete(comment) } },
                                       onImageTap: { url in
                                           previewImage = SDocImagePreviewItem(url: url)
                                       })
                            .id(comment.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .refreshable { await model.load() }
            .onChange(of: model.comments.last?.id) { _, newValue in
                guard let newValue else { return }
                withAnimation(.smooth) { proxy.scrollTo(newValue, anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if model.isMentionPickerVisible {
                mentionPicker
            }
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.attachments) { attachment in
                            attachmentThumbnail(attachment)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.seafileOrange)
                        .frame(width: 36, height: 36)
                }
                TextField("Add a comment…", text: $model.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                Button {
                    Task { await model.send() }
                } label: {
                    if model.isPosting {
                        ProgressView()
                            .frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(model.canSend ? Color.seafileOrange : Color.secondary.opacity(0.5))
                    }
                }
                .disabled(!model.canSend)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var mentionPicker: some View {
        Group {
            if model.mentionSuggestions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.mentionSuggestions.enumerated()), id: \.offset) { index, user in
                            Button {
                                model.insertMention(user)
                                inputFocused = true
                            } label: {
                                HStack(spacing: 10) {
                                    mentionAvatar(user)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(user.displayName)
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        if !user.name.isEmpty, !user.email.isEmpty {
                                            Text(user.email)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                            if index < model.mentionSuggestions.count - 1 {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func mentionAvatar(_ user: SDocUser) -> some View {
        if let raw = user.avatarURL, let url = imageURL(raw) {
            RemoteImage(url: url, token: api.token, allowUntrusted: api.allowUntrusted)
                .frame(width: 32, height: 32)
                .clipShape(Circle())
        } else {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color.seafileAmber, Color.seafileOrange],
                                             startPoint: .topLeading,
                                             endPoint: .bottomTrailing))
                Text(String(user.displayName.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
        }
    }

    @ViewBuilder
    private func attachmentThumbnail(_ attachment: SDocCommentsModel.Attachment) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            switch attachment.state {
            case .uploading:
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.35))
                    .frame(width: 64, height: 64)
                    .overlay { ProgressView().tint(.white) }
            case .failed:
                Button {
                    model.retry(attachment.id)
                } label: {
                    Text("Retry")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.red, in: Capsule())
                }
                .frame(width: 64, height: 64)
                .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            case .uploaded:
                EmptyView()
            }
            Button {
                model.removeAttachment(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.7))
            }
            .offset(x: 6, y: -6)
        }
        .frame(width: 64, height: 64)
    }

    private func imageURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        guard let base = pageOptions.seahubBaseURL else { return nil }
        return URL(string: raw, relativeTo: base)?.absoluteURL
    }
}

private struct SDocCommentRow: View {
    let comment: SDocComment
    let token: String?
    let allowUntrusted: Bool
    let isBusy: Bool
    let imageURL: (String) -> URL?
    let onResolve: () -> Void
    let onDelete: () -> Void
    let onImageTap: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(comment.author.isEmpty ? String(localized: "Unknown") : comment.author)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if comment.isResolved {
                            Label("Resolved", systemImage: "checkmark.circle.fill")
                                .labelStyle(.titleAndIcon)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.green)
                        }
                        Spacer(minLength: 4)
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Menu {
                            if !comment.isResolved {
                                Button {
                                    onResolve()
                                } label: {
                                    Label("Mark resolved", systemImage: "checkmark.circle")
                                }
                            }
                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 24)
                                .contentShape(Rectangle())
                        }
                    }
                    Text(comment.displayTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(comment.content.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .text(let value):
                        Text(attributed(value))
                            .font(.subheadline)
                            .textSelection(.enabled)
                    case .image(let raw):
                        if let url = imageURL(raw) {
                            RemoteImage(url: url,
                                        token: token,
                                        allowUntrusted: allowUntrusted,
                                        contentMode: .fit)
                                .frame(maxWidth: 240, maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .onTapGesture { onImageTap(url) }
                        }
                    }
                }
            }
            .padding(.leading, 42)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(comment.isResolved ? 0.78 : 1)
    }

    private var avatar: some View {
        Group {
            if let raw = comment.avatarURL, let url = imageURL(raw) {
                RemoteImage(url: url, token: token, allowUntrusted: allowUntrusted)
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
            } else {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color.seafileAmber, Color.seafileOrange],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                    Text(initial)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
            }
        }
    }

    private var initial: String {
        let source = comment.author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = source.first else { return "?" }
        return String(first).uppercased()
    }

    private func attributed(_ value: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
    }
}

private struct SDocImagePreviewItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SDocImagePreviewScreen: View {
    let url: URL
    let token: String?
    let allowUntrusted: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteImage(url: url, token: token, allowUntrusted: allowUntrusted, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 44)
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(16)
        }
    }
}
