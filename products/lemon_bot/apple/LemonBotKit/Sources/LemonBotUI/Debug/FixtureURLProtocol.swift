#if DEBUG
import Foundation

/// Serves the fixture workspace over `URLSession` so the real `LemonBotStore`, `HTTPTransport` and views run unmodified.
/// Reads return fixture JSON (unknown reads return an empty page). Message sends are recorded in memory only,
/// without executing Bot work; other mutations are refused except mark-read and draft bookkeeping.
final class FixtureURLProtocol: URLProtocol {
    static let host = "fixtures.lemonbot.test"
    /// `LB_FIXTURE_TRACE=1` logs every stubbed request to stderr.
    static let trace = ProcessInfo.processInfo.environment["LB_FIXTURE_TRACE"] != nil
    static var baseURL: URL { URL(string: "https://\(host)")! }
    private static let lock = NSLock()
    private final class Messages {
        var entries: [String: [FixtureJSON]] = [:]
        var receipts: [String: FixtureJSON] = [:]
    }
    private static var messages: [String: Messages] = [:]
    static func makeSession() -> URLSession {
        let sessionID = UUID().uuidString
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-LB-Fixture-Session": sessionID]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.respond(to: request)
        if Self.trace { FileHandle.standardError.write(Data("[fixture] \(request.httpMethod ?? "GET") \(request.url?.path ?? "") \(request.url?.query ?? "") -> \(status)\n".utf8)) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
        finished = true
    }
    private var finished = false
    override func stopLoading() {
        if Self.trace, !finished { FileHandle.standardError.write(Data("[fixture] CANCELLED \(request.httpMethod ?? "GET") \(request.url?.path ?? "")\n".utf8)) }
    }

    private static func data(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8) }
    private static func failure(_ status: Int, code: String, message: String) -> (Int, Data) {
        (status, data(["error": ["code": code, "message": message, "requestId": "req_fixture_stub", "retrySafe": false]]))
    }

    private static func messageBody(_ request: URLRequest) throws -> FixtureJSON {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, request.httpBody == nil {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { break }
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard let value = try JSONSerialization.jsonObject(with: body) as? FixtureJSON else { throw URLError(.cannotDecodeRawData) }
        return value
    }

    static func respond(to request: URLRequest) -> (Int, Data) {
        lock.lock(); defer { lock.unlock() }
        let world = FixtureWorld.shared
        let sessionID = request.value(forHTTPHeaderField: "X-LB-Fixture-Session") ?? "direct"
        if messages[sessionID] == nil { messages[sessionID] = Messages() }
        let messages = messages[sessionID]!
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return failure(400, code: "validation_failed", message: "Bad fixture URL.") }
        let method = request.httpMethod ?? "GET"
        let segments = components.path.split(separator: "/").map(String.init).dropFirst() // drop "v1"
        let parts = Array(segments)
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        func found(_ value: Any?) -> (Int, Data) { value.map { (200, data($0)) } ?? failure(404, code: "not_found", message: "Fixture resource not found.") }
        func conversation(_ id: String) -> FixtureJSON? { world.conversations.first { $0["id"] as? String == id } }

        if method == "POST", parts.count == 3, parts[0] == "conversations", parts[2] == "messages", conversation(parts[1]) != nil {
            guard let body = try? messageBody(request), let nonce = body["clientNonce"] as? String, let text = body["text"] as? String else {
                return failure(400, code: "validation_failed", message: "A fixture message needs text and a nonce.")
            }
            let key = parts[1] + "/" + nonce
            if let receipt = messages.receipts[key] { return found(receipt) }
            let seq = (world.entries(for: parts[1]) + (messages.entries[parts[1]] ?? [])).compactMap { $0["seq"] as? Int }.max().map { $0 + 1 } ?? 1
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let entry: FixtureJSON = [
                "id": "entry_FixtureSent_\(UUID().uuidString)", "conversationId": parts[1], "seq": seq,
                "kind": "message", "role": "user", "text": text, "streaming": false,
                "actor": ["kind": "user", "id": LemonBotFixtureID.user, "displayName": "Sam Rivera"],
                "clientNonce": nonce, "attachmentIds": body["attachmentIds"] ?? [String](),
                "replyToEntryId": body["replyToEntryId"] ?? NSNull(), "batchId": NSNull(), "runId": NSNull(), "targetedUserId": NSNull(),
                "timestampMs": now, "createdAtMs": now, "updatedAtMs": now, "revision": 1, "reactions": [FixtureJSON]()
            ]
            messages.entries[parts[1], default: []].append(entry)
            let receipt: FixtureJSON = ["entries": [entry], "runs": [FixtureJSON](), "clientNonce": nonce, "status": "accepted", "delivery": [FixtureJSON]()]
            messages.receipts[key] = receipt
            return found(receipt)
        }
        if method == "POST", parts.count == 3, parts[0] == "conversations", parts[2] == "read", var value = conversation(parts[1]) {
            value["unreadCount"] = 0; value["revision"] = (value["revision"] as? Int ?? 1) + 1
            return (200, data(value))
        }
        if method == "PUT", parts.count == 3, parts[0] == "conversations", parts[2] == "composer" { return found(world.composer(for: parts[1])) }
        guard method == "GET" else { return failure(409, code: "conflict", message: "This fixture workspace is read-only.") }

        switch parts {
        case ["sync"]: return found(world.snapshot)
        case ["me"]: return found(world.user)
        case ["workspace"]: return found(world.workspace)
        case ["bots"]: return found(world.page(world.bots))
        case ["machines"]: return found(world.page(world.machines))
        case ["conversations"]: return found(world.page(world.conversations))
        case ["notifications"]: return found(world.page([]))
        case ["activity"]: return found(world.page(world.activity.filter { query["botId"] == nil || $0["botId"] as? String == query["botId"] }))
        case ["upcoming"]: return found(world.page(world.upcoming.filter { query["botId"] == nil || $0["botId"] as? String == query["botId"] }))
        case ["runs"]:
            return found(world.page(world.runs.filter {
                (query["botId"] == nil || $0["botId"] as? String == query["botId"]) &&
                (query["conversationId"] == nil || $0["conversationId"] as? String == query["conversationId"]) &&
                (query["status"] == nil || $0["status"] as? String == query["status"])
            }))
        default: break
        }
        if parts.count >= 2 {
            let id = parts[1], tail = parts.dropFirst(2).joined(separator: "/")
            switch (parts[0], tail) {
            case ("bots", ""): return found(world.bots.first { $0["id"] as? String == id })
            case ("bots", "overview"): return found(world.overviews[id])
            case ("bots", "ideas"): return found(world.ideas[id])
            case ("bots", "activity"): return found(world.page(world.activity.filter { $0["botId"] as? String == id }))
            case ("machines", ""): return found(world.machines.first { $0["id"] as? String == id })
            case ("conversations", ""): return found(conversation(id))
            case ("conversations", "entries"): return found(world.page(world.entries(for: id) + (messages.entries[id] ?? [])))
            case ("conversations", "composer"): return found(world.composer(for: id))
            case ("entries", ""): return found(world.entry(id: id) ?? messages.entries.values.joined().first { $0["id"] as? String == id })
            case ("runs", ""): return found(world.runs.first { $0["id"] as? String == id })
            default: break
            }
        }
        return (200, data(world.page([])))
    }
}
#endif
