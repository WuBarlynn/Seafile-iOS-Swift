import Foundation

struct FPRepo: Decodable, Sendable {
    let id: String
    let name: String
    let type: String?
    let encrypted: Bool?
    let permission: String?

    var isEncrypted: Bool { encrypted == true }
    var isWritable: Bool { (permission ?? "rw").lowercased() == "rw" }
}

struct FPDirent: Decodable, Sendable {
    let name: String
    let type: String
    let id: String?
    let size: Int64?
    let mtime: Int64?
    let permission: String?

    var isDirectory: Bool { type == "dir" }
}

enum FPAPIError: LocalizedError {
    case invalidServer
    case invalidResponse
    case http(Int, String?)
    case noUploadLink

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "The server address is invalid."
        case .invalidResponse: return "The server returned an unexpected response."
        case let .http(code, message): return message ?? "Server error (HTTP \(code))."
        case .noUploadLink: return "The server did not provide an upload link."
        }
    }
}

final class FileProviderAPI: NSObject, URLSessionDelegate, @unchecked Sendable {
    let account: SharedAccount
    private let configuration: URLSessionConfiguration
    private lazy var session = URLSession(configuration: configuration,
                                          delegate: self,
                                          delegateQueue: nil)

    init(account: SharedAccount) {
        self.account = account
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        self.configuration = configuration
        super.init()
    }

    // MARK: - Reads

    func repos() async throws -> [FPRepo] {
        let data = try await get("api2/repos/")
        return (try? JSONDecoder().decode([FPRepo].self, from: data)) ?? []
    }

    func dirents(repoID: String, path: String) async throws -> [FPDirent] {
        let data = try await get("api2/repos/\(repoID)/dir/",
                                 query: [URLQueryItem(name: "p", value: path)])
        let entries = (try? JSONDecoder().decode([FPDirent].self, from: data)) ?? []
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func thumbnail(repoID: String, path: String, size: Int) async throws -> Data? {
        let data = try await get("api2/repos/\(repoID)/thumbnail/",
                                 query: [URLQueryItem(name: "p", value: path),
                                         URLQueryItem(name: "size", value: "\(size)")])
        return data.isEmpty ? nil : data
    }

    func downloadLink(repoID: String, path: String) async throws -> URL {
        let data = try await get("api2/repos/\(repoID)/file/",
                                 query: [URLQueryItem(name: "p", value: path),
                                         URLQueryItem(name: "reuse", value: "1")])
        let object = try? JSONSerialization.jsonObject(with: data)
        if let string = object as? String, let url = URL(string: string) { return url }
        if let dict = object as? [String: Any],
           let string = (dict["url"] as? String) ?? (dict["download_link"] as? String),
           let url = URL(string: string) {
            return url
        }
        throw FPAPIError.invalidResponse
    }

    func download(from url: URL) async throws -> URL {
        let (fileURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse else { throw FPAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw FPAPIError.http(http.statusCode, nil)
        }
        return fileURL
    }

    // MARK: - Writes

    func upload(fileURL: URL,
                fileName: String,
                repoID: String,
                dirPath: String,
                replace: Bool,
                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let link = try await uploadLink(repoID: repoID, dirPath: dirPath)
        let boundary = "SeafileFP-\(UUID().uuidString)"
        var fields: [(String, String)] = [
            ("parent_dir", dirPath),
            ("file_name", fileName),
            ("csrfmiddlewaretoken", "n8ba38951c9ba66418311a25195e2e380")
        ]
        if replace { fields.append(("replace", "1")) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = (attributes?[.size] as? NSNumber)?.int64Value {
            fields.append(("file_size", String(size)))
        }
        let bodyURL = try multipartBody(fileURL: fileURL,
                                       fileName: fileName,
                                       fields: fields,
                                       boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: link)
        request.httpMethod = "POST"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3600

        let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        guard let http = response as? HTTPURLResponse else { throw FPAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw FPAPIError.http(http.statusCode, Self.errorMessage(from: data))
        }
    }

    func createDirectory(repoID: String, parentPath: String, name: String) async throws {
        let fullPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        _ = try await postForm("api2/repos/\(repoID)/dir/",
                               query: [URLQueryItem(name: "p", value: fullPath),
                                       URLQueryItem(name: "reloaddir", value: "true")],
                               fields: ["operation": "mkdir"])
    }

    func rename(repoID: String, path: String, newName: String) async throws {
        _ = try await postForm("api2/repos/\(repoID)/file/",
                               query: [URLQueryItem(name: "p", value: path),
                                       URLQueryItem(name: "reloaddir", value: "true")],
                               fields: ["operation": "rename", "newname": newName])
    }

    func move(repoID: String, path: String, destinationRepoID: String, destinationPath: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        _ = try await postForm("api2/repos/\(repoID)/fileops/move/",
                               query: [URLQueryItem(name: "p", value: parent.isEmpty ? "/" : parent),
                                       URLQueryItem(name: "reloaddir", value: "true")],
                               fields: ["dst_repo": destinationRepoID,
                                        "dst_dir": destinationPath,
                                        "file_names": name])
    }

    func delete(repoID: String, path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        _ = try await postForm("api2/repos/\(repoID)/fileops/delete/",
                               query: [URLQueryItem(name: "p", value: parent.isEmpty ? "/" : parent),
                                       URLQueryItem(name: "reloaddir", value: "true")],
                               fields: ["file_names": name])
    }

    // MARK: - Requests

    private func uploadLink(repoID: String, dirPath: String) async throws -> URL {
        let data = try await get("api2/repos/\(repoID)/upload-link/",
                                 query: [URLQueryItem(name: "p", value: dirPath)])
        let object = try? JSONSerialization.jsonObject(with: data)
        if let string = object as? String, let url = URL(string: string) { return url }
        if let dict = object as? [String: Any],
           let string = dict["url"] as? String, let url = URL(string: string) {
            return url
        }
        throw FPAPIError.noUploadLink
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var request = URLRequest(url: try makeURL(path, query: query))
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FPAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw FPAPIError.http(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private func postForm(_ path: String,
                          query: [URLQueryItem],
                          fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: try makeURL(path, query: query))
        request.httpMethod = "POST"
        request.setValue("Token \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FPAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw FPAPIError.http(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private func makeURL(_ path: String, query: [URLQueryItem]) throws -> URL {
        var base = account.serverURL
        if !base.hasSuffix("/") { base += "/" }
        guard var components = URLComponents(string: base + path) else { throw FPAPIError.invalidServer }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw FPAPIError.invalidServer }
        return url
    }

    private func multipartBody(fileURL: URL,
                               fileName: String,
                               fields: [(String, String)],
                               boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fp-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        var header = ""
        for (name, value) in fields {
            header += "--\(boundary)\r\n"
            header += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            header += "\(value)\r\n"
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
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
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (object["error_msg"] as? String)
            ?? (object["error"] as? String)
            ?? (object["detail"] as? String)
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
