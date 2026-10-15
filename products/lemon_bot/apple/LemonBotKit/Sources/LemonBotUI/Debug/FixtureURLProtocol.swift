#if DEBUG
import Foundation

/// Serves the fixture workspace over `URLSession` so the real `LemonBotStore`, `HTTPTransport` and views run unmodified.
/// Reads return fixture JSON (unknown reads return an empty page); mutations are refused with the real error envelope,
/// except the two benign client bookkeeping calls a visible conversation makes (mark read, save draft).
final class FixtureURLProtocol: URLProtocol {
    static let host = "fixtures.lemonbot.test"
    /// `LB_FIXTURE_TRACE=1` logs every stubbed request to stderr.
    static let trace = ProcessInfo.processInfo.environment["LB_FIXTURE_TRACE"] != nil
    static var baseURL: URL { URL(string: "https://\(host)")! }
    static func makeSession(controllerDown: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = ["X-LB-Fixture-Controller-Down": controllerDown ? "true" : "false"]
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

    static func respond(to request: URLRequest) -> (Int, Data) {
        let world = FixtureWorld.shared
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return failure(400, code: "validation_failed", message: "Bad fixture URL.") }
        let method = request.httpMethod ?? "GET"
        let segments = components.path.split(separator: "/").map(String.init).dropFirst() // drop "v1"
        let parts = Array(segments)
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        func found(_ value: Any?) -> (Int, Data) { value.map { (200, data($0)) } ?? failure(404, code: "not_found", message: "Fixture resource not found.") }
        func conversation(_ id: String) -> FixtureJSON? { world.conversations.first { $0["id"] as? String == id } }

        if method == "POST", parts.count == 3, parts[0] == "conversations", parts[2] == "read", var value = conversation(parts[1]) {
            value["unreadCount"] = 0; value["revision"] = (value["revision"] as? Int ?? 1) + 1
            return (200, data(value))
        }
        if method == "PUT", parts.count == 3, parts[0] == "conversations", parts[2] == "composer" { return found(world.composer(for: parts[1])) }
        guard method == "GET" else { return failure(409, code: "conflict", message: "This fixture workspace is read-only.") }

        switch parts {
        case ["sync"]: return found(world.snapshot)
        case ["instance"]: return found(world.instance(controllerDown: request.value(forHTTPHeaderField: "X-LB-Fixture-Controller-Down") == "true"))
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
            case ("conversations", "entries"): return found(world.page(world.entries(for: id)))
            case ("conversations", "composer"): return found(world.composer(for: id))
            case ("entries", ""): return found(world.entry(id: id))
            case ("runs", ""): return found(world.runs.first { $0["id"] as? String == id })
            default: break
            }
        }
        return (200, data(world.page([])))
    }
}
#endif
