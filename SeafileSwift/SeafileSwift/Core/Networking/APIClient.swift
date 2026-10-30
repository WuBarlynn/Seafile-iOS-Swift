import Foundation

struct ActivityPage {
    let events: [ActivityEvent]
    let hasMore: Bool
    let nextPage: Int
}

struct EncryptedFileDescriptor: Sendable {
    let fileID: String
    let blockIDs: [String]
    let fileSize: Int64?
}

struct SSOSession: Sendable {
    let username: String
    let token: String
}

final class APIClient: @unchecked Sendable {
    static let appVersion = "0.9.0"
    private static let csrfToken = "n8ba38951c9ba66418311a25195e2e380"

    static var platformVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static var deviceName: String { DeviceIdentity.name }
    static var deviceID: String { DeviceIdentity.id }

    let baseURL: URL
    let token: String?
    let allowUntrusted: Bool
    private let session: URLSession

    init(serverURL: URL, token: String?, allowUntrusted: Bool = false) {
        baseURL = Self.normalizedBase(serverURL)
        self.token = token
        self.allowUntrusted = allowUntrusted
        session = NetworkSessionFactory.make(allowUntrusted: allowUntrusted)
    }

    // MARK: - Addresses

    static func serverURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://\(text)" }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/api2", "/api/v2.1", "/api"] where path.lowercased().hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
        }
        components.path = path
        return components.url
    }

    static func normalizedBase(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text) ?? url
    }

    private func makeURL(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        components.user = baseURL.user
        components.password = baseURL.password
        var basePath = baseURL.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = basePath + "/" + path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    // MARK: - Requests

    private func makeRequest(path: String,
                             query: [URLQueryItem] = [],
                             method: String = "GET",
                             form: [String: String]? = nil,
                             headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: makeURL(path: path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.appVersion, forHTTPHeaderField: "X-Seafile-Client-Version")
        request.setValue("ios", forHTTPHeaderField: "X-Seafile-Platform")
        request.setValue(Self.platformVersion, forHTTPHeaderField: "X-Seafile-Platform-Version")
        if let token, !token.isEmpty {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        if let form {
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(Self.formEncoded(form).utf8)
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery ?? ""
    }

    private func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
            return (data, http)
        } catch let error as APIError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw APIError.cancelled
        } catch {
            throw APIError.network(error.localizedDescription)
        }
    }

    private func execute(path: String,
                         query: [URLQueryItem] = [],
                         method: String = "GET",
                         form: [String: String]? = nil,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        let request = makeRequest(path: path, query: query, method: method, form: form, headers: headers)
        let (data, response) = try await data(for: request)
        if !(200..<300).contains(response.statusCode) {
            throw Self.error(for: response, data: data)
        }
        return (data, response)
    }

    private func executeJSON(path: String, method: String, body: [String: Any]) async throws -> Data {
        var request = makeRequest(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await data(for: request)
        if !(200..<300).contains(response.statusCode) {
            throw Self.error(for: response, data: data)
        }
        return data
    }

    private static func error(for response: HTTPURLResponse, data: Data) -> APIError {
        let message = message(from: data)
        switch response.statusCode {
        case 400:
            if response.value(forHTTPHeaderField: "X-Seafile-OTP")?.lowercased() == "required" {
                return .twoFactorRequired
            }
            return .http(status: 400, message: message)
        case 401: return .unauthorized
        case 403: return .forbidden
        case 440: return .repoPasswordRequired
        default: return .http(status: response.statusCode, message: message)
        }
    }

    static func message(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            if let dict = object as? [String: Any] {
                for key in ["error_msg", "error", "detail", "message"] {
                    if let value = dict[key] as? String, !value.isEmpty { return value }
                }
                for key in ["non_field_errors", "errors"] {
                    if let values = dict[key] as? [Any] {
                        let strings = values.compactMap { $0 as? String }.filter { !$0.isEmpty }
                        if !strings.isEmpty { return strings.joined(separator: "\n") }
                    }
                }
            }
            if let value = object as? String, !value.isEmpty, value.count < 500 { return value }
        }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count < 500 else { return nil }
        if text.lowercased().contains("<!doctype") || text.lowercased().contains("<html") { return nil }
        return text
    }

    private func parseJSON(_ data: Data) throws -> Any {
        guard !data.isEmpty else { return [:] }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Authentication

    func login(username: String, password: String, otp: String?, rememberDevice: Bool) async throws -> String {
        var headers: [String: String] = [:]
        if let otp, !otp.isEmpty { headers["X-Seafile-OTP"] = otp }
        if rememberDevice { headers["X-SEAFILE-2FA-TRUST-DEVICE"] = "1" }

        let extendedForm: [String: String] = [
            "username": username,
            "password": password,
            "platform": "ios",
            "platformName": "iphoneos",
            "client_version": Self.appVersion,
            "platform_version": Self.platformVersion,
            "device_id": DeviceIdentity.id,
            "device_name": DeviceIdentity.name
        ]

        var (responseData, response) = try await data(for: makeRequest(path: "api2/auth-token/",
                                                                       method: "POST",
                                                                       form: extendedForm,
                                                                       headers: headers))

        // Some older or misconfigured servers fail on the optional device
        // metadata. Retry with only the credentials before surfacing a 5xx.
        if response.statusCode >= 500 {
            let minimalForm = ["username": username, "password": password]
            (responseData, response) = try await data(for: makeRequest(path: "api2/auth-token/",
                                                                       method: "POST",
                                                                       form: minimalForm,
                                                                       headers: headers))
        }

        if response.statusCode == 400 {
            if response.value(forHTTPHeaderField: "X-Seafile-OTP")?.lowercased() == "required" {
                if let otp, !otp.isEmpty {
                    throw APIError.invalidCredentials
                }
                throw APIError.twoFactorRequired
            }
            if let message = Self.message(from: responseData),
               !message.lowercased().contains("unable to login"),
               !message.lowercased().contains("incorrect password") {
                throw APIError.message(message)
            }
            throw APIError.invalidCredentials
        }
        if !(200..<300).contains(response.statusCode) {
            throw Self.error(for: response, data: responseData)
        }
        guard let dict = try parseJSON(responseData) as? [String: Any], let token = dict["token"] as? String else {
            throw APIError.invalidResponse
        }
        return token
    }

    // MARK: - Single Sign-On

    func clientSSOLink() async throws -> URL {
        let (data, _) = try await execute(path: "api2/client-sso-link/", method: "POST")
        guard let dict = try parseJSON(data) as? [String: Any],
              let string = dict["link"] as? String,
              let url = URL(string: string) else {
            throw APIError.invalidResponse
        }
        return url
    }

    func clientSSOStatus(link: URL) async throws -> SSOSession? {
        let text = link.absoluteString
        guard let range = text.range(of: "client-sso/") else { throw APIError.invalidResponse }
        let tokenPath = String(text[range.upperBound...])
        let (data, _) = try await execute(path: "api2/client-sso-link/" + tokenPath)
        guard let dict = try parseJSON(data) as? [String: Any] else { throw APIError.invalidResponse }

        let status = dict["status"] as? String
        if status == "success" {
            guard let username = dict["username"] as? String,
                  let token = dict["apiToken"] as? String else {
                throw APIError.invalidResponse
            }
            return SSOSession(username: username, token: token)
        }
        if status == "error" {
            throw APIError.message((dict["message"] as? String) ?? "Single sign-on failed.")
        }
        return nil
    }

    // MARK: - Account / server

    func accountInfo() async throws -> AccountInfo {
        let (data, _) = try await execute(path: "api2/account/info/")
        guard let dict = try parseJSON(data) as? [String: Any] else { throw APIError.invalidResponse }
        return AccountInfo(json: dict)
    }

    func serverInfo() async throws -> ServerInfo {
        let (data, _) = try await execute(path: "api2/server-info/")
        guard let info = ServerInfo(json: try parseJSON(data)) else { throw APIError.invalidResponse }
        return info
    }

    func avatarData(username: String) async throws -> Data? {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? username
        let (metadata, _) = try await execute(path: "api2/avatars/user/\(encoded)/resized/80/")
        guard let dict = try parseJSON(metadata) as? [String: Any] else { return nil }
        if (dict["is_default"] as? NSNumber)?.boolValue == true { return nil }
        guard let raw = dict["url"] as? String,
              let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL else { return nil }

        var request = URLRequest(url: url)
        request.setValue("image/*,*/*", forHTTPHeaderField: "Accept")
        if url.host == baseURL.host, let token {
            request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        }
        let (imageData, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else { return nil }
        return imageData
    }

    // MARK: - Libraries

    func repositories() async throws -> [Repository] {
        let (data, _) = try await execute(path: "api/v2.1/repos/")
        let object = try parseJSON(data)
        let raw: [Any]
        if let dict = object as? [String: Any], let list = dict["repos"] as? [Any] {
            raw = list
        } else if let list = object as? [Any] {
            raw = list
        } else {
            throw APIError.invalidResponse
        }
        return raw.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return Repository(json: dict)
        }
        .sorted { NaturalSort.lessThan($0.name, $1.name) }
    }

    func createLibrary(name: String, password: String?) async throws -> Repository? {
        var form = ["name": name, "desc": ""]
        if let password, !password.isEmpty { form["passwd"] = password }
        let (data, _) = try await execute(path: "api2/repos/", method: "POST", form: form)
        guard let dict = try parseJSON(data) as? [String: Any] else { return nil }
        return Repository(json: dict)
    }

    func renameLibrary(id: String, newName: String) async throws {
        _ = try await execute(path: "api2/repos/\(id)/",
                              query: [URLQueryItem(name: "op", value: "rename")],
                              method: "POST",
                              form: ["repo_name": newName])
    }

    func deleteLibrary(id: String) async throws {
        _ = try await execute(path: "api/v2.1/repos/\(id)/", method: "DELETE")
    }

    // MARK: - Browsing

    func dirents(repoID: String, path: String) async throws -> [Dirent] {
        do {
            let (data, _) = try await execute(
                path: "api/v2.1/repos/\(repoID)/dir/",
                query: [
                    URLQueryItem(name: "p", value: path),
                    URLQueryItem(name: "with_thumbnail", value: "true")
                ]
            )
            return try Self.decodeDirents(data, parentPath: path)
        } catch let error as APIError {
            if case let .http(status, _) = error, status == 400 || status == 404 {
                let (data, _) = try await execute(
                    path: "api2/repos/\(repoID)/dir/",
                    query: [URLQueryItem(name: "p", value: path)]
                )
                return try Self.decodeDirents(data, parentPath: path)
            }
            throw error
        }
    }

    private static func decodeDirents(_ data: Data, parentPath: String) throws -> [Dirent] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw APIError.decoding(error.localizedDescription)
        }
        let raw: [Any]
        if let dict = object as? [String: Any], let list = dict["dirent_list"] as? [Any] {
            raw = list
        } else if let list = object as? [Any] {
            raw = list
        } else {
            throw APIError.invalidResponse
        }
        return raw.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return Dirent(json: dict, parentPath: parentPath)
        }
    }

    func createDirectory(repoID: String, parentPath: String, name: String) async throws {
        let fullPath = parentPath == "/" ? "/\(name)" : "\(parentPath)/\(name)"
        _ = try await execute(
            path: "api2/repos/\(repoID)/dir/",
            query: [
                URLQueryItem(name: "p", value: fullPath),
                URLQueryItem(name: "reloaddir", value: "true")
            ],
            method: "POST",
            form: ["operation": "mkdir"]
        )
    }

    func deleteEntries(repoID: String, dirPath: String, names: [String]) async throws {
        guard !names.isEmpty else { return }
        _ = try await execute(
            path: "api2/repos/\(repoID)/fileops/delete/",
            query: [
                URLQueryItem(name: "p", value: dirPath),
                URLQueryItem(name: "reloaddir", value: "true")
            ],
            method: "POST",
            form: ["file_names": names.joined(separator: ":")]
        )
    }

    func renameEntry(repoID: String, path: String, newName: String) async throws {
        _ = try await execute(
            path: "api2/repos/\(repoID)/file/",
            query: [
                URLQueryItem(name: "p", value: path),
                URLQueryItem(name: "reloaddir", value: "true")
            ],
            method: "POST",
            form: ["operation": "rename", "newname": newName]
        )
    }

    func copyEntries(repoID: String,
                     dirPath: String,
                     names: [String],
                     destinationRepoID: String,
                     destinationPath: String) async throws {
        guard !names.isEmpty else { return }
        _ = try await execute(
            path: "api2/repos/\(repoID)/fileops/copy/",
            query: [
                URLQueryItem(name: "p", value: dirPath),
                URLQueryItem(name: "reloaddir", value: "true")
            ],
            method: "POST",
            form: [
                "dst_repo": destinationRepoID,
                "dst_dir": destinationPath,
                "file_names": names.joined(separator: ":")
            ]
        )
    }

    func moveEntries(repoID: String,
                     dirPath: String,
                     names: [String],
                     destinationRepoID: String,
                     destinationPath: String) async throws {
        guard !names.isEmpty else { return }
        _ = try await execute(
            path: "api2/repos/\(repoID)/fileops/move/",
            query: [
                URLQueryItem(name: "p", value: dirPath),
                URLQueryItem(name: "reloaddir", value: "true")
            ],
            method: "POST",
            form: [
                "dst_repo": destinationRepoID,
                "dst_dir": destinationPath,
                "file_names": names.joined(separator: ":")
            ]
        )
    }

    // MARK: - Download

    func downloadLink(repoID: String, path: String) async throws -> URL {
        let (data, _) = try await execute(
            path: "api2/repos/\(repoID)/file/",
            query: [
                URLQueryItem(name: "p", value: path),
                URLQueryItem(name: "reuse", value: "1")
            ]
        )
        let object = try parseJSON(data)
        if let string = object as? String, let url = URL(string: string) { return url }
        if let dict = object as? [String: Any],
           let string = (dict["url"] as? String) ?? (dict["download_link"] as? String),
           let url = URL(string: string) {
            return url
        }
        throw APIError.invalidResponse
    }

    func downloadFile(from url: URL,
                      progress: @escaping @Sendable (Double, Int64, Int64) -> Void,
                      cancellation: TransferCancellationToken? = nil) async throws -> URL {
        let runner = DownloadRunner(allowUntrusted: allowUntrusted,
                                    progress: progress,
                                    cancellation: cancellation)
        return try await runner.download(url: url)
    }

    // MARK: - Encrypted libraries (local decryption)

    func repoEncryptionInfo(repoID: String) async throws -> RepoEncryptionInfo {
        let (data, _) = try await execute(path: "api2/repos/\(repoID)/")
        guard let dict = try parseJSON(data) as? [String: Any],
              let info = RepoEncryptionInfo(json: dict) else {
            throw APIError.invalidResponse
        }
        return info
    }

    func encryptedFileDescriptor(repoID: String, path: String) async throws -> EncryptedFileDescriptor {
        let (data, _) = try await execute(
            path: "api2/repos/\(repoID)/file/",
            query: [
                URLQueryItem(name: "p", value: path),
                URLQueryItem(name: "op", value: "downloadblks")
            ]
        )
        guard let dict = try parseJSON(data) as? [String: Any] else { throw APIError.invalidResponse }
        guard let fileID = (dict["file_id"] as? String) ?? (dict["id"] as? String), !fileID.isEmpty else {
            throw APIError.invalidResponse
        }
        let blocks = (dict["blklist"] as? [Any])?.compactMap { $0 as? String } ?? []
        let size = (dict["file_size"] as? NSNumber)?.int64Value ?? (dict["size"] as? NSNumber)?.int64Value
        return EncryptedFileDescriptor(fileID: fileID, blockIDs: blocks, fileSize: size)
    }

    private func encryptedBlockLink(repoID: String, fileID: String, blockID: String) async throws -> URL {
        let (data, _) = try await execute(
            path: "api2/repos/\(repoID)/files/\(fileID)/blks/\(blockID)/download-link/"
        )
        let object = try parseJSON(data)
        if let string = object as? String, let url = URL(string: string) { return url }
        if let dict = object as? [String: Any],
           let string = (dict["url"] as? String) ?? (dict["download_link"] as? String),
           let url = URL(string: string) {
            return url
        }
        throw APIError.invalidResponse
    }

    private func downloadEncryptedBlockData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 600
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response, data: data)
        }
        return data
    }

    func downloadEncrypted(repoID: String,
                           path: String,
                           key: RepoCryptoKey,
                           progress: @escaping @Sendable (Double, Int64, Int64) -> Void,
                           cancellation: TransferCancellationToken? = nil) async throws -> URL {
        let descriptor = try await encryptedFileDescriptor(repoID: repoID, path: path)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-decrypted-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            throw APIError.invalidResponse
        }

        var completedBytes: Int64 = 0
        let totalBytes = descriptor.fileSize ?? 0
        do {
            for (index, blockID) in descriptor.blockIDs.enumerated() {
                if cancellation?.isCancelled == true {
                    throw CancellationError()
                }
                let link = try await encryptedBlockLink(repoID: repoID,
                                                        fileID: descriptor.fileID,
                                                        blockID: blockID)
                let encrypted = try await downloadEncryptedBlockData(from: link)
                let plain = try SeafCrypto.decrypt(encrypted, with: key)
                try handle.write(contentsOf: plain)
                completedBytes += Int64(plain.count)
                let fraction = Double(index + 1) / Double(descriptor.blockIDs.count)
                progress(fraction, completedBytes, totalBytes > 0 ? totalBytes : completedBytes)
            }
            try handle.close()
            progress(1, completedBytes, totalBytes > 0 ? totalBytes : completedBytes)
            return tempURL
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Upload

    func uploadLink(repoID: String, dirPath: String) async throws -> URL {
        let (data, _) = try await execute(
            path: "api2/repos/\(repoID)/upload-link/",
            query: [URLQueryItem(name: "p", value: dirPath)]
        )
        let object = try parseJSON(data)
        if let string = object as? String, let url = URL(string: string) { return url }
        if let dict = object as? [String: Any], let string = dict["url"] as? String, let url = URL(string: string) {
            return url
        }
        throw APIError.invalidResponse
    }

    func upload(fileURL: URL,
                repoID: String,
                dirPath: String,
                fileName: String,
                replace: Bool,
                progress: @escaping @Sendable (Double, Int64, Int64) -> Void,
                cancellation: TransferCancellationToken? = nil) async throws {
        let link = try await uploadLink(repoID: repoID, dirPath: dirPath)

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
        if let modified = attributes?[.modificationDate] as? Date {
            fields.append(("last_modify", Self.isoFormatter.string(from: modified)))
        }

        let multipart = try MultipartBody(fileURL: fileURL, fileName: fileName, fields: fields)
        defer { multipart.cleanup() }

        var request = URLRequest(url: link)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(multipart.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(multipart.contentLength), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 3600

        let runner = UploadRunner(allowUntrusted: allowUntrusted,
                                  progress: progress,
                                  cancellation: cancellation)
        let (data, response) = try await runner.upload(request: request, fileURL: multipart.fileURL)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response, data: data)
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Encrypted upload (local encryption)

    func uploadEncrypted(fileURL: URL,
                         repoID: String,
                         dirPath: String,
                         fileName: String,
                         replace: Bool,
                         key: RepoCryptoKey,
                         progress: @escaping @Sendable (Double, Int64, Int64) -> Void,
                         cancellation: TransferCancellationToken? = nil) async throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let lastModified = attributes?[.modificationDate] as? Date

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-encrypted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blocks = try Self.encryptBlocks(fileURL: fileURL, outputDir: tempDir, key: key)
        let blockIDs = blocks.map(\.id)
        progress(0.15, 0, fileSize)

        let (infoData, _) = try await execute(
            path: "api2/repos/\(repoID)/upload-blks-link/",
            query: [URLQueryItem(name: "p", value: dirPath)],
            method: "POST",
            form: ["blklist": blockIDs.joined(separator: ",")]
        )
        guard let info = try parseJSON(infoData) as? [String: Any] else { throw APIError.invalidResponse }
        guard let commitString = info["commiturl"] as? String,
              let commitURL = URL(string: commitString, relativeTo: baseURL)?.absoluteURL else {
            throw APIError.invalidResponse
        }

        let missing = (info["blklist"] as? [Any])?.compactMap { $0 as? String }
        let blocksToUpload: [EncryptedBlockFile]
        if let missing {
            let missingSet = Set(missing)
            blocksToUpload = blocks.filter { missingSet.contains($0.id) }
        } else {
            blocksToUpload = blocks
        }

        if !blocksToUpload.isEmpty {
            guard let rawString = info["rawblksurl"] as? String,
                  let rawURL = URL(string: rawString, relativeTo: baseURL)?.absoluteURL else {
                throw APIError.invalidResponse
            }
            for (index, block) in blocksToUpload.enumerated() {
                if cancellation?.isCancelled == true {
                    throw CancellationError()
                }
                try await uploadEncryptedBlock(block, to: rawURL, cancellation: cancellation)
                let fraction = 0.15 + 0.65 * Double(index + 1) / Double(blocksToUpload.count)
                progress(fraction, 0, fileSize)
            }
        }

        if cancellation?.isCancelled == true {
            throw CancellationError()
        }
        try await commitEncryptedUpload(url: commitURL,
                                        dirPath: dirPath,
                                        fileName: fileName,
                                        fileSize: fileSize,
                                        blockIDs: blockIDs,
                                        replace: replace,
                                        lastModified: lastModified,
                                        cancellation: cancellation)
        progress(1, fileSize, fileSize)
    }

    private static func encryptBlocks(fileURL: URL,
                                      outputDir: URL,
                                      key: RepoCryptoKey) throws -> [EncryptedBlockFile] {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        var blocks: [EncryptedBlockFile] = []
        let chunkSize = 2 * 1024 * 1024
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            let encrypted = try SeafCrypto.encrypt(chunk, with: key)
            let blockID = SeafCrypto.sha1Hex(encrypted)
            let blockURL = outputDir.appendingPathComponent(blockID)
            try encrypted.write(to: blockURL, options: .atomic)
            blocks.append(EncryptedBlockFile(id: blockID, url: blockURL))
        }
        return blocks
    }

    private func uploadEncryptedBlock(_ block: EncryptedBlockFile,
                                      to url: URL,
                                      cancellation: TransferCancellationToken?) async throws {
        _ = try await uploadMultipart(url: url,
                                      fields: [("csrfmiddlewaretoken", Self.csrfToken)],
                                      files: [(field: "file", filename: block.id, url: block.url)],
                                      progress: { _, _, _ in },
                                      cancellation: cancellation)
    }

    private func commitEncryptedUpload(url: URL,
                                       dirPath: String,
                                       fileName: String,
                                       fileSize: Int64,
                                       blockIDs: [String],
                                       replace: Bool,
                                       lastModified: Date?,
                                       cancellation: TransferCancellationToken?) async throws {
        let blockJSONData = try JSONSerialization.data(withJSONObject: blockIDs)
        let blockJSON = String(data: blockJSONData, encoding: .utf8) ?? "[]"
        var fields: [(String, String)] = [
            ("csrfmiddlewaretoken", Self.csrfToken),
            ("parent_dir", dirPath),
            ("file_name", fileName),
            ("file_size", String(fileSize)),
            ("blockids", blockJSON)
        ]
        if replace { fields.append(("replace", "1")) }
        if let lastModified {
            fields.append(("last_modify", Self.isoFormatter.string(from: lastModified)))
        }
        _ = try await uploadMultipart(url: url,
                                      fields: fields,
                                      files: [],
                                      progress: { _, _, _ in },
                                      cancellation: cancellation)
    }

    private func uploadMultipart(url: URL,
                                 fields: [(String, String)],
                                 files: [(field: String, filename: String, url: URL)],
                                 progress: @escaping @Sendable (Double, Int64, Int64) -> Void,
                                 cancellation: TransferCancellationToken?) async throws -> (Data, HTTPURLResponse) {
        let payload = try MultipartPayload(fields: fields, files: files)
        defer { payload.cleanup() }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(payload.boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(payload.contentLength), forHTTPHeaderField: "Content-Length")
        request.timeoutInterval = 3600

        let runner = UploadRunner(allowUntrusted: allowUntrusted,
                                  progress: progress,
                                  cancellation: cancellation)
        let (data, response) = try await runner.upload(request: request, fileURL: payload.fileURL)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response, data: data)
        }
        return (data, response)
    }

    // MARK: - Thumbnails

    func thumbnailData(repoID: String, path: String, newAPI: Bool, size: Int = 256) async throws -> Data {
        let request: URLRequest
        if newAPI {
            var filePath = path
            if filePath.hasPrefix("/") { filePath.removeFirst() }
            request = makeRequest(path: "thumbnail/\(repoID)/\(size)/\(filePath)",
                                  headers: ["Accept": "image/*,*/*"])
        } else {
            request = makeRequest(path: "api2/repos/\(repoID)/thumbnail/",
                                  query: [
                                    URLQueryItem(name: "size", value: String(size)),
                                    URLQueryItem(name: "p", value: path)
                                  ],
                                  headers: ["Accept": "image/*,*/*"])
        }
        let (data, response) = try await data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw Self.error(for: response, data: data)
        }
        return data
    }

    // MARK: - SeaDoc

    func createFile(repoID: String, dirPath: String, name: String) async throws {
        let base = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        let fullPath = base + name
        _ = try await execute(path: "api2/repos/\(repoID)/file/",
                              query: [
                                URLQueryItem(name: "p", value: fullPath),
                                URLQueryItem(name: "reloaddir", value: "true")
                              ],
                              method: "POST",
                              form: ["operation": "create"])
    }

    func relatedUsers(repoID: String) async throws -> [SDocUser] {
        let (data, _) = try await execute(path: "api/v2.1/repos/\(repoID)/related-users/")
        let object = try parseJSON(data)
        return SDocUser.list(from: object, keys: ["user_list", "users"])
    }

    func seadocParticipants(docUUID: String) async throws -> [SDocUser] {
        let (data, _) = try await execute(path: "api/v2.1/seadoc/participants/\(docUUID)/")
        let object = try parseJSON(data)
        return SDocUser.list(from: object,
                             keys: ["participant_list", "participants", "user_list", "users"])
    }

    func fileDetail(repoID: String, path: String) async throws -> [String: Any] {
        let (data, _) = try await execute(path: "api2/repos/\(repoID)/file/detail/",
                                          query: [URLQueryItem(name: "p", value: path)])
        guard let dict = try parseJSON(data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return dict
    }

    func metadataConfig(repoID: String) async throws -> [String: Any] {
        let (data, _) = try await execute(path: "api/v2.1/repos/\(repoID)/metadata/")
        guard let dict = try parseJSON(data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return dict
    }

    func metadataRecord(repoID: String, parentDir: String, name: String) async throws -> [String: Any] {
        let (data, _) = try await execute(path: "api/v2.1/repos/\(repoID)/metadata/record/",
                                          query: [
                                            URLQueryItem(name: "parent_dir", value: parentDir),
                                            URLQueryItem(name: "name", value: name),
                                            URLQueryItem(name: "file_name", value: name)
                                          ])
        guard let dict = try parseJSON(data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return dict
    }

    func repoTags(repoID: String) async throws -> [String: Any] {
        let (data, _) = try await execute(path: "api/v2.1/repos/\(repoID)/metadata/tags/",
                                          query: [
                                            URLQueryItem(name: "start", value: "0"),
                                            URLQueryItem(name: "limit", value: "1000")
                                          ])
        guard let dict = try parseJSON(data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return dict
    }

    func updateMetadataRecord(repoID: String, recordID: String, data: [String: Any]) async throws {
        guard !data.isEmpty else { return }
        _ = try await executeJSON(path: "api/v2.1/repos/\(repoID)/metadata/record/",
                                  method: "PUT",
                                  body: ["record_id": recordID, "data": data])
    }

    func updateFileTags(repoID: String, recordID: String, tagIDs: [String]) async throws {
        _ = try await executeJSON(path: "api/v2.1/repos/\(repoID)/metadata/file-tags/",
                                  method: "PUT",
                                  body: ["file_tags_data": [["record_id": recordID, "tags": tagIDs]]])
    }

    // MARK: - Starred

    func starredItems() async throws -> [StarredItem] {
        let (data, _) = try await execute(path: "api/v2.1/starred-items/")
        let object = try parseJSON(data)
        let raw: [Any]
        if let dict = object as? [String: Any], let list = dict["starred_item_list"] as? [Any] {
            raw = list
        } else if let list = object as? [Any] {
            raw = list
        } else {
            throw APIError.invalidResponse
        }
        return raw.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return StarredItem(json: dict)
        }
    }

    func setStarred(_ starred: Bool, repoID: String, path: String) async throws {
        if starred {
            _ = try await execute(path: "api/v2.1/starred-items/",
                                  method: "POST",
                                  form: ["repo_id": repoID, "path": path])
        } else {
            _ = try await execute(path: "api/v2.1/starred-items/",
                                  query: [
                                    URLQueryItem(name: "repo_id", value: repoID),
                                    URLQueryItem(name: "path", value: path)
                                  ],
                                  method: "DELETE")
        }
    }

    // MARK: - Search

    func search(_ keyword: String, repoID: String? = nil) async throws -> [SearchResult] {
        var query = [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "per_page", value: "100")
        ]
        if let repoID {
            query.append(URLQueryItem(name: "search_repo", value: repoID))
        }
        let (data, _) = try await execute(path: "api2/search/", query: query)
        let object = try parseJSON(data)
        guard let dict = object as? [String: Any], let raw = dict["results"] as? [Any] else {
            throw APIError.invalidResponse
        }
        return raw.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return SearchResult(json: dict, repoName: nil)
        }
    }

    // MARK: - Activities

    func activities(page: Int, useNewAPI: Bool) async throws -> ActivityPage {
        if useNewAPI {
            let (data, _) = try await execute(
                path: "api/v2.1/activities/",
                query: [URLQueryItem(name: "page", value: String(page))]
            )
            let object = try parseJSON(data)
            let raw = (object as? [String: Any])?["events"] as? [Any] ?? []
            let events = raw.enumerated().compactMap { index, item in
                ActivityEvent(json: item as? [String: Any] ?? [:], index: index)
            }
            return ActivityPage(events: events, hasMore: raw.count >= 25, nextPage: page + 1)
        } else {
            let offset = max(0, (page - 1) * 25)
            let (data, _) = try await execute(
                path: "api2/events/",
                query: [URLQueryItem(name: "start", value: String(offset))]
            )
            let object = try parseJSON(data)
            let dict = object as? [String: Any]
            let raw = dict?["events"] as? [Any] ?? []
            let events = raw.enumerated().compactMap { index, item in
                ActivityEvent(json: item as? [String: Any] ?? [:], index: index)
            }
            let hasMore = (dict?["more"] as? NSNumber)?.boolValue ?? false
            return ActivityPage(events: events, hasMore: hasMore, nextPage: page + 1)
        }
    }

    // MARK: - Links

    func shareLink(repoID: String, path: String) async throws -> URL? {
        let (data, _) = try await execute(
            path: "api/v2.1/share-links/",
            query: [
                URLQueryItem(name: "repo_id", value: repoID),
                URLQueryItem(name: "path", value: path)
            ]
        )
        let object = try parseJSON(data)
        if let list = object as? [Any] {
            for item in list {
                if let dict = item as? [String: Any], let link = dict["link"] as? String, let url = URL(string: link) {
                    return url
                }
            }
        } else if let dict = object as? [String: Any], let link = dict["link"] as? String, let url = URL(string: link) {
            return url
        }

        let (created, _) = try await execute(
            path: "api/v2.1/share-links/",
            method: "POST",
            form: ["path": path, "repo_id": repoID]
        )
        if let dict = try parseJSON(created) as? [String: Any],
           let link = dict["link"] as? String,
           let url = URL(string: link) {
            return url
        }
        return nil
    }

    // MARK: - Knowledge base / Wiki

    func wikiSections() async throws -> [WikiSection] {
        var v2: Any?
        var v1: Any?
        var lastError: Error?

        do {
            let (data, _) = try await execute(path: "api/v2.1/wikis2/")
            v2 = try parseJSON(data)
        } catch {
            lastError = error
        }
        do {
            let (data, _) = try await execute(path: "api/v2.1/wikis/")
            v1 = try parseJSON(data)
        } catch {
            lastError = error
        }
        guard v2 != nil || v1 != nil else {
            throw lastError ?? APIError.invalidResponse
        }

        var mine: [WikiInfo] = []
        var shared: [WikiInfo] = []
        var groups: [String: [WikiInfo]] = [:]
        var legacy: [WikiInfo] = []

        if let dict = v2 as? [String: Any] {
            for item in dict["wikis"] as? [Any] ?? [] {
                guard let json = item as? [String: Any], let info = WikiInfo(json: json, legacy: false) else { continue }
                if info.type == "shared" {
                    shared.append(info)
                } else {
                    mine.append(info)
                }
            }
            for groupItem in dict["group_wikis"] as? [Any] ?? [] {
                guard let group = groupItem as? [String: Any] else { continue }
                let groupName = (group["group_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Group"
                for item in group["wiki_info"] as? [Any] ?? [] {
                    guard let json = item as? [String: Any],
                          let info = WikiInfo(json: json, legacy: false, groupName: groupName) else { continue }
                    groups[groupName, default: []].append(info)
                }
            }
        }

        if let dict = v1 as? [String: Any] {
            for item in dict["data"] as? [Any] ?? [] {
                guard let json = item as? [String: Any], let info = WikiInfo(json: json, legacy: true) else { continue }
                legacy.append(info)
            }
        }

        return WikiSectionBuilder.sections(mine: mine, shared: shared, groups: groups, legacy: legacy)
    }

    func renameWiki(id: String, name: String) async throws {
        _ = try await execute(path: "api/v2.1/wiki2/\(id)/", method: "PUT", form: ["wiki_name": name])
    }

    func deleteWiki(id: String) async throws {
        _ = try await execute(path: "api/v2.1/wiki2/\(id)/", method: "DELETE")
    }

    func publishWiki(id: String, publishURL: String) async throws {
        _ = try await execute(path: "api/v2.1/wiki2/\(id)/publish/",
                              method: "POST",
                              form: ["publish_url": publishURL])
    }

    func unpublishWiki(id: String) async throws {
        _ = try await execute(path: "api/v2.1/wiki2/\(id)/publish/", method: "DELETE")
    }
}

private enum DeviceIdentity {
    private static let key = "seafile.swift.deviceID"

    static var id: String {
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    static var name: String {
        ProcessInfo.processInfo.hostName
    }
}

// MARK: - Progress / transport helpers

private final class DownloadRunner: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let allowUntrusted: Bool
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void
    private let cancellation: TransferCancellationToken?
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadedFile: URL?
    private var httpResponse: HTTPURLResponse?
    private var failure: Error?
    private var session: URLSession?

    init(allowUntrusted: Bool,
         progress: @escaping @Sendable (Double, Int64, Int64) -> Void,
         cancellation: TransferCancellationToken?) {
        self.allowUntrusted = allowUntrusted
        onProgress = progress
        self.cancellation = cancellation
    }

    func download(url: URL) async throws -> URL {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7200
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            var request = URLRequest(url: url)
            request.timeoutInterval = 7200
            let task = session.downloadTask(with: request)
            cancellation?.onCancel {
                task.cancel()
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        onProgress(fraction, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        httpResponse = downloadTask.response as? HTTPURLResponse
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            downloadedFile = destination
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: APIError.network(error.localizedDescription))
            return
        }
        if let failure {
            continuation.resume(throwing: APIError.network(failure.localizedDescription))
            return
        }
        guard let downloadedFile, let httpResponse else {
            continuation.resume(throwing: APIError.invalidResponse)
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: downloadedFile)
            continuation.resume(throwing: APIError.http(status: httpResponse.statusCode, message: nil))
            return
        }
        continuation.resume(returning: downloadedFile)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = ClientCertificateStore.credential(for: challenge) {
            completionHandler(.useCredential, credential)
        } else if allowUntrusted,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private final class UploadRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowUntrusted: Bool
    private let onProgress: @Sendable (Double, Int64, Int64) -> Void
    private let cancellation: TransferCancellationToken?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var body = Data()
    private var httpResponse: HTTPURLResponse?
    private var session: URLSession?

    init(allowUntrusted: Bool,
         progress: @escaping @Sendable (Double, Int64, Int64) -> Void,
         cancellation: TransferCancellationToken?) {
        self.allowUntrusted = allowUntrusted
        onProgress = progress
        self.cancellation = cancellation
    }

    func upload(request: URLRequest, fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7200
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        defer {
            session.finishTasksAndInvalidate()
            self.session = nil
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let task = session.uploadTask(with: request, fromFile: fileURL)
            cancellation?.onCancel {
                task.cancel()
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let fraction = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend)
            : 0
        onProgress(fraction, totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error {
            continuation.resume(throwing: APIError.network(error.localizedDescription))
            return
        }
        guard let httpResponse = task.response as? HTTPURLResponse else {
            continuation.resume(throwing: APIError.invalidResponse)
            return
        }
        continuation.resume(returning: (body, httpResponse))
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = ClientCertificateStore.credential(for: challenge) {
            completionHandler(.useCredential, credential)
        } else if allowUntrusted,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private struct MultipartBody {
    let boundary = "SeafileBoundary-\(UUID().uuidString)"
    let fileURL: URL
    let contentLength: Int64

    init(fileURL source: URL, fileName: String, fields: [(String, String)]) throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var header = ""
        for (name, value) in fields {
            header += "--\(boundary)\r\n"
            header += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            header += "\(value)\r\n"
        }
        let safeName = fileName.replacingOccurrences(of: "\"", with: "")
        header += "--\(boundary)\r\n"
        header += "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
        header += "Content-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try output.close()
        fileURL = destination
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        contentLength = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private struct EncryptedBlockFile {
    let id: String
    let url: URL
}

private struct MultipartPayload {
    let boundary = "SeafileBoundary-\(UUID().uuidString)"
    let fileURL: URL
    let contentLength: Int64

    init(fields: [(String, String)],
         files: [(field: String, filename: String, url: URL)]) throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("seafile-multipart-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)

        var header = ""
        for (name, value) in fields {
            header += "--\(boundary)\r\n"
            header += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            header += "\(value)\r\n"
        }
        try output.write(contentsOf: Data(header.utf8))

        for file in files {
            let safeName = file.filename.replacingOccurrences(of: "\"", with: "")
            let fileHeader = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(safeName)\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n"
            try output.write(contentsOf: Data(fileHeader.utf8))

            let input = try FileHandle(forReadingFrom: file.url)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try? input.close()
            try output.write(contentsOf: Data("\r\n".utf8))
        }

        try output.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        try output.close()

        fileURL = destination
        let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
        contentLength = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
