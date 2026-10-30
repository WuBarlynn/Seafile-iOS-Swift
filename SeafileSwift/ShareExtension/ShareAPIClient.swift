import Foundation

struct ShareRepo: Decodable, Identifiable {
    let id: String
    let name: String
    let type: String?
    let encrypted: Bool?
    let permission: String?

    var isEncrypted: Bool { encrypted == true }
    var isWritable: Bool { (permission ?? "rw").lowercased() == "rw" }
}

struct ShareDirent: Decodable, Identifiable {
    let name: String
    let type: String
    let id: String?

    var isDirectory: Bool { type == "dir" }
    var stableID: String { id ?? name }
}

struct ShareStarredDir: Identifiable, Hashable {
    let repoID: String
    let path: String
    let name: String

    var id: String { repoID + "|" + path }
}

enum ShareAPIError: LocalizedError {
    case invalidServer
    case invalidResponse
    case http(Int, String?)
    case emptyUploadLink

    var errorDescription: String? {
        switch self {
        case .invalidServer:
            return String(localized: "The server address is invalid.")
        case .invalidResponse:
            return String(localized: "The server returned an unexpected response.")
        case let .http(code, message):
            if let message, !message.isEmpty { return message }
            return String(format: String(localized: "Server error (HTTP %lld)."), Int64(code))
        case .emptyUploadLink:
            return String(localized: "The server did not provide an upload link.")
        }
    }
}

final class ShareAPIClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let account: SharedAccount
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration,
                                          delegate: self,
                                          delegateQueue: nil)
    private let lock = NSLock()
    private var progressHandler: (@Sendable (Double) -> Void)?

    init(account: SharedAccount) {
        self.account = account
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration = configuration
        super.init()
    }

    func repos() async throws -> [ShareRepo] {
        let data = try await get("api2/repos/")
        let decoder = JSONDecoder()
        return (try? decoder.decode([ShareRepo].self, from: data)) ?? []
    }

    func directories(repoID: String, path: String) async throws -> [ShareDirent] {
        let data = try await get("api2/repos/\(repoID)/dir/",
                                 query: [URLQueryItem(name: "p", value: path)])
        let decoder = JSONDecoder()
        let entries = (try? decoder.decode([ShareDirent].self, from: data)) ?? []
        return entries.filter(\.isDirectory).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func starredDirectories() async throws -> [ShareStarredDir] {
        let data = try await get("api2/starredfiles/")
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { json in
            guard let repoID = json["repo_id"] as? String,
                  let path = json["path"] as? String,
                  (json["is_dir"] as? NSNumber)?.boolValue == true,
                  (json["repo_encrypted"] as? NSNumber)?.boolValue != true else {
                return nil
            }
            let name = (json["obj_name"] as? String) ?? (path as NSString).lastPathComponent
            return ShareStarredDir(repoID: repoID, path: path, name: name)
        }
    }

    func createDirectory(repoID: String, path: String, name: String) async throws {
        guard let url = makeURL("api2/repos/\(repoID)/dir/",
                                query: [URLQueryItem(name: "p", value: path)]) else {
            throw ShareAPIError.invalidServer
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "operation", value: "mkdir"),
                           URLQueryItem(name: "name", value: name)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ShareAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ShareAPIError.http(http.statusCode, Self.errorMessage(from: data))
        }
    }

    func upload(fileURL: URL,
                fileName: String,
                repoID: String,
                directoryPath: String,
                progress: @escaping @Sendable (Double) -> Void) async throws {
        let link = try await uploadLink(repoID: repoID)
        let boundary = "SeafileShare-\(UUID().uuidString)"
        let bodyURL = try multipartBody(fileURL: fileURL,
                                       fileName: fileName,
                                       directoryPath: directoryPath,
                                       boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: link)
        request.httpMethod = "POST"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        setProgressHandler(progress)
        defer { setProgressHandler(nil) }

        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else {
            throw ShareAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ShareAPIError.http(http.statusCode, Self.errorMessage(from: data))
        }
    }

    // MARK: - Requests

    private func uploadLink(repoID: String) async throws -> URL {
        let data = try await get("api2/repos/\(repoID)/upload-link/")
        let text = (try? JSONDecoder().decode(String.self, from: data))
            ?? (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"").union(.whitespacesAndNewlines))
        guard let url = URL(string: text) else { throw ShareAPIError.emptyUploadLink }
        return url
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        guard let url = makeURL(path, query: query) else { throw ShareAPIError.invalidServer }
        var request = URLRequest(url: url)
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ShareAPIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw ShareAPIError.http(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private func makeURL(_ path: String, query: [URLQueryItem]) -> URL? {
        var base = account.serverURL
        if !base.hasSuffix("/") { base += "/" }
        guard var components = URLComponents(string: base + path) else { return nil }
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }

    private func multipartBody(fileURL: URL,
                               fileName: String,
                               directoryPath: String,
                               boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("share-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        var header = ""
        header += "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"parent_dir\"\r\n\r\n"
        header += "\(directoryPath)\r\n"
        header += "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
        header += "Content-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }

        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (object["error_msg"] as? String)
                ?? (object["error"] as? String)
                ?? (object["detail"] as? String)
        }
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func setProgressHandler(_ handler: (@Sendable (Double) -> Void)?) {
        lock.lock()
        progressHandler = handler
        lock.unlock()
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let handler = progressHandler
        lock.unlock()
        handler?(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              account.allowUntrustedCertificate,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
