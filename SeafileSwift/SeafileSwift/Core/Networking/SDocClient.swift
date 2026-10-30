import Foundation

final class SDocClient: @unchecked Sendable {
    private let baseURL: URL?
    private let seahubBaseURL: URL?
    private let token: String
    private let session: URLSession

    init(pageOptions: SDocPageOptions, allowUntrusted: Bool) {
        var text = pageOptions.seadocServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        baseURL = URL(string: text)
        seahubBaseURL = pageOptions.seahubBaseURL
        token = pageOptions.seadocAccessToken
        session = NetworkSessionFactory.make(allowUntrusted: allowUntrusted)
    }

    func comments(docUUID: String) async throws -> [SDocComment] {
        let object = try await execute(path: "/api/v1/docs/\(docUUID)/comment/", method: "GET")
        guard let dict = object as? [String: Any] else { throw APIError.invalidResponse }
        let list = dict["comments"] as? [Any] ?? []
        return list.compactMap { item in
            guard let item = item as? [String: Any] else { return nil }
            return SDocComment.parse(item)
        }
    }

    func postComment(docUUID: String, comment: String, author: String, updatedAt: String) async throws {
        let body: [String: Any] = [
            "comment": comment,
            "detail": ["element_id": "0", "comment": comment],
            "author": author,
            "updated_at": updatedAt
        ]
        _ = try await execute(path: "/api/v1/docs/\(docUUID)/comment/",
                              method: "POST",
                              json: body)
    }

    func markResolved(docUUID: String, commentID: Int64) async throws {
        _ = try await execute(path: "/api/v1/docs/\(docUUID)/comment/\(commentID)/",
                              method: "PUT",
                              json: ["resolved": true])
    }

    func deleteComment(docUUID: String, commentID: Int64) async throws {
        _ = try await execute(path: "/api/v1/docs/\(docUUID)/comment/\(commentID)/", method: "DELETE")
    }

    func uploadImage(docUUID: String, data: Data, fileName: String, mimeType: String) async throws -> [String] {
        guard let seahubBaseURL else { throw APIError.invalidServerURL }
        let boundary = "Boundary-\(UInt32.random(in: 0...UInt32.max))"
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n")
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"authorization\"\r\n\r\n")
        body.appendString("Token \(token)\r\n")
        body.appendString("--\(boundary)--\r\n")

        let object = try await execute(base: seahubBaseURL,
                                       path: "/api/v2.1/seadoc/upload-image/\(docUUID)/",
                                       method: "POST",
                                       body: body,
                                       contentType: "multipart/form-data; boundary=\(boundary)")
        guard let dict = object as? [String: Any],
              let paths = dict["relative_path"] as? [String] else {
            throw APIError.invalidResponse
        }
        return paths
    }

    func downloadImageURL(docUUID: String, relativePath: String) -> URL? {
        guard let seahubBaseURL else { return nil }
        var path = relativePath
        while path.hasPrefix("/") { path.removeFirst() }
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return append(path: "/api/v2.1/seadoc/download-image/\(docUUID)/\(encoded)", to: seahubBaseURL)
    }

    private func execute(base: URL? = nil,
                         path: String,
                         method: String,
                         body: Data? = nil,
                         contentType: String? = nil,
                         json: [String: Any]? = nil) async throws -> Any {
        var payload = body
        var type = contentType
        if let json {
            payload = try JSONSerialization.data(withJSONObject: json)
            type = "application/json"
        }
        guard let base = base ?? baseURL,
              let url = append(path: path, to: base) else {
            throw APIError.invalidServerURL
        }

        var attempt = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(APIClient.appVersion, forHTTPHeaderField: "X-Seafile-Client-Version")
            if let type {
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            }
            if !token.isEmpty {
                request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
            }

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                if !(200..<300).contains(http.statusCode) {
                    if (500...599).contains(http.statusCode), attempt < 1 {
                        attempt += 1
                        try await Task.sleep(for: .milliseconds(400))
                        continue
                    }
                    throw APIError.http(status: http.statusCode, message: Self.message(from: data))
                }
                guard !data.isEmpty else { return [:] }
                return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            } catch let error as APIError {
                throw error
            } catch let error as URLError where error.code == .cancelled {
                throw APIError.cancelled
            } catch {
                if attempt < 1, error is URLError {
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(400))
                    continue
                }
                throw APIError.network(error.localizedDescription)
            }
        }
    }

    private func append(path: String, to base: URL) -> URL? {
        var baseText = base.absoluteString
        while baseText.hasSuffix("/") { baseText.removeLast() }
        var suffix = path
        if !suffix.hasPrefix("/") { suffix = "/" + suffix }
        return URL(string: baseText + suffix)
    }

    private static func message(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dict = object as? [String: Any] {
            for key in ["detail", "error", "message", "non_field_errors"] {
                if let text = dict[key] as? String, !text.isEmpty { return text }
                if let list = dict[key] as? [String], let text = list.first, !text.isEmpty { return text }
            }
        }
        return nil
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
