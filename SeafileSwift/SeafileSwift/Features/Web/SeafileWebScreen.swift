import SwiftUI

enum SeafileWebURL {
    static func library(baseURL: URL, repoID: String) -> URL? {
        build(baseURL: baseURL, path: "/lib/\(repoID)/")
    }

    static func file(baseURL: URL, repoID: String, path: String) -> URL? {
        build(baseURL: baseURL, path: "/lib/\(repoID)/file\(path)")
    }

    private static func build(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + path
        return components.url
    }
}

struct WebScreenRequest: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    var isSDoc: Bool = false
    var repoID: String?
    var path: String?
    var useDesktopUserAgent: Bool = false

    init(title: String,
         url: URL,
         isSDoc: Bool = false,
         repoID: String? = nil,
         path: String? = nil,
         useDesktopUserAgent: Bool = false) {
        self.title = title
        self.url = url
        self.isSDoc = isSDoc
        self.repoID = repoID
        self.path = path
        self.useDesktopUserAgent = useDesktopUserAgent
    }
}

struct SeafileWebScreen: View {
    let title: String
    let initialURL: URL
    var useDesktopUserAgent: Bool = false

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var progress: Double = 0
    @State private var reloadID = UUID()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AuthenticatedWebView(baseURL: session.account.serverURL,
                                     initialURL: initialURL,
                                     token: session.api.token,
                                     allowUntrusted: session.account.allowUntrustedCertificate,
                                     preferMobileLogin: true,
                                     useEphemeralStore: true,
                                     useDesktopUserAgent: useDesktopUserAgent,
                                     progress: $progress)
                    .id(reloadID)

                if progress > 0, progress < 1 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.seafileOrange)
                }
            }
            .background(Color(.systemBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadID = UUID()
                        progress = 0
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
