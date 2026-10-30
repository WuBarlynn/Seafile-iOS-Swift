import SwiftUI
import UIKit

struct WikiWebScreen: View {
    let wiki: WikiInfo
    @Environment(Session.self) private var session
    @Environment(\.openURL) private var openURL

    @State private var progress: Double = 0
    @State private var reloadID = UUID()
    @State private var currentURL: URL?
    @State private var pageTitle: String?
    @State private var shareItem: ShareItem?
    @State private var toast: String?

    var body: some View {
        Group {
            if let url = wiki.webURL(baseURL: session.account.serverURL) {
                ZStack(alignment: .top) {
                    AuthenticatedWebView(baseURL: session.account.serverURL,
                                         initialURL: url,
                                         token: session.api.token,
                                         allowUntrusted: session.account.allowUntrustedCertificate,
                                         progress: $progress,
                                         onPageChanged: { url, title in
                                             currentURL = url
                                             pageTitle = title
                                         },
                                         onDownload: { url, filename, cookies in
                                             downloadAttachment(url, filename: filename, cookies: cookies)
                                         })
                        .id(reloadID)

                    if progress > 0, progress < 1 {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.seafileOrange)
                    }
                }
            } else {
                ContentUnavailableView("Invalid wiki",
                                       systemImage: "book.closed",
                                       description: Text("This wiki does not have a valid web address."))
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(wiki.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    reloadID = UUID()
                    progress = 0
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        copyCurrentLink()
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    if let url = currentURL ?? wiki.webURL(baseURL: session.account.serverURL) {
                        Button {
                            openURL(url)
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .seafileToast($toast)
    }

    private func downloadAttachment(_ url: URL, filename: String?, cookies: [HTTPCookie]) {
        Task {
            do {
                let fileURL = try await Self.download(url: url,
                                                      filename: filename,
                                                      cookies: cookies,
                                                      token: session.api.token)
                shareItem = ShareItem(url: fileURL)
            } catch {
                toast = error.localizedDescription
            }
        }
    }

    private static func download(url: URL,
                                 filename: String?,
                                 cookies: [HTTPCookie],
                                 token: String?) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        if let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let token, !token.isEmpty {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }

        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WikiDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var name = filename ?? url.lastPathComponent
        name = FileNames.sanitized(name)
        if name.isEmpty { name = "attachment" }
        let destination = FileNames.unique(in: directory, name: name)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func copyCurrentLink() {
        guard let url = currentURL ?? wiki.webURL(baseURL: session.account.serverURL) else {
            toast = String(localized: "No share link is available.")
            return
        }
        UIPasteboard.general.string = url.absoluteString
        toast = String(localized: "Link copied.")
    }
}
