import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct HTTPTransport {
    public let baseURL: URL
    public let token: String?
    public let session: URLSession
    public init(baseURL: URL, token: String? = nil, session: URLSession? = nil) throws {
        self.baseURL = try Self.normalizeBaseURL(baseURL)
        self.token = token
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 45
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
    }
    public static func normalizeBaseURL(_ url: URL) throws -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil,
              c.scheme == "https" || (c.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())) else { throw ClientError.insecureEndpoint }
        guard c.path == "" || c.path == "/" || c.path == "/v1" || c.path == "/v1/" else { throw ClientError.invalidPath }
        c.path = "/v1"
        guard let normalized = c.url else { throw ClientError.invalidPath }
        return normalized
    }
    public static func pathID(_ id: ID) throws -> String {
        guard !id.isEmpty, !id.contains("/"), !id.contains("\\"), !id.contains(where: { $0.isNewline || $0.asciiValue.map({ $0 < 32 }) == true }) else { throw ClientError.invalidPath }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) else { throw ClientError.invalidPath }
        return encoded
    }
    public func url(_ path: String, query: [String: String] = [:]) throws -> URL {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              let decoded = path.removingPercentEncoding,
              !decoded.contains("\\"), !path.lowercased().contains("%2f"),
              !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw ClientError.invalidPath }
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = decoded.hasPrefix("/hooks/") ? decoded : baseURL.path + decoded
        c.queryItems = query.isEmpty ? nil : query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw ClientError.invalidPath }
        return url
    }
    private func request(_ method: String, _ path: String, query: [String: String] = [:]) throws -> URLRequest {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func validate(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidBinary }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) { throw BackendError(status: http.statusCode, failure: envelope.error) }
            throw ClientError.http(http.statusCode)
        }
    }
    public func read<T: Decodable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> T {
        let (data, response) = try await session.data(for: request("GET", path, query: query))
        try validate(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }
    /// One attempt only. Caller retains the nonce and reconciles an uncertain outcome instead of resubmitting.
    public func mutate<T: Decodable>(_ method: String, _ path: String, body: JSONObject, as: T.Type = T.self) async throws -> T {
        guard ["POST", "PATCH", "PUT", "DELETE"].contains(method) else { throw ClientError.invalidPath }
        var payload = body
        if path != "/auth/reauth", payload["clientNonce"] == nil { payload["clientNonce"] = .string(UUID().uuidString) }
        let uncertainty: ClientError
        if path == "/auth/reauth" { uncertainty = .reauthenticationUnconfirmed }
        else {
            guard let nonce = payload["clientNonce"]?.stringValue else { throw ClientError.invalidNonce }
            uncertainty = .outcomeUnknown(nonce)
        }
        var request = try request(method, path)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch { throw uncertainty }
        do { try validate(result.0, result.1) }
        catch let error as BackendError { throw error }
        catch { throw uncertainty }
        do { return try JSONDecoder().decode(T.self, from: result.0) }
        catch { throw uncertainty }
    }
    public func upload(fileURL: URL, filename: String? = nil, mime: String, metadata: JSONObject) async throws -> Attachment {
        let filename = filename ?? fileURL.lastPathComponent
        guard !filename.isEmpty, !filename.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\"" || $0 == "\\" }), !mime.contains(where: { $0.isNewline }) else { throw ClientError.invalidPath }
        var payload = metadata
        if payload["clientNonce"] == nil { payload["clientNonce"] = .string(UUID().uuidString) }
        let boundary = "lemonbot-" + UUID().uuidString
        let multipart = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: multipart.path, contents: nil) else { throw ClientError.invalidBinary }
        defer { try? FileManager.default.removeItem(at: multipart) }
        let output = try FileHandle(forWritingTo: multipart)
        do {
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n".utf8))
            try output.write(contentsOf: JSONEncoder().encode(payload))
            try output.write(contentsOf: Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk) }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.close()
        } catch { try? output.close(); throw error }
        var request = try request("POST", "/attachments")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let result: (Data, URLResponse)
        do { result = try await session.upload(for: request, fromFile: multipart) }
        catch { throw ClientError.outcomeUnknown(payload["clientNonce"]?.stringValue ?? "upload") }
        do { try validate(result.0, result.1) }
        catch let error as BackendError { throw error }
        catch { throw ClientError.outcomeUnknown(payload["clientNonce"]?.stringValue ?? "upload") }
        do { return try JSONDecoder().decode(Attachment.self, from: result.0) }
        catch { throw ClientError.outcomeUnknown(payload["clientNonce"]?.stringValue ?? "upload") }
    }
    public func download(_ ticket: Download, destination: URL) async throws -> URL {
        guard let url = URL(string: ticket.url), url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/v1/downloads/"), ticket.expiresAtMs > Date().timeIntervalSince1970 * 1000 else { throw ClientError.invalidBinary }
        var request = URLRequest(url: url)
        request.setValue(ticket.mime, forHTTPHeaderField: "Accept")
        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidBinary }
        if !(200..<300).contains(http.statusCode) {
            try validate(Data(contentsOf: temporary), response)
        }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard size == ticket.size else { throw ClientError.invalidBinary }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
