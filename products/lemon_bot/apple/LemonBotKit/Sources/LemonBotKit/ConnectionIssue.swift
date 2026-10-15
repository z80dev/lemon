import Foundation

public struct ConnectionIssue: Equatable, Sendable {
    public enum Layer: Equatable, Sendable {
        case backendUnreachable, backendError(Int), controllerDown, signedOutOrRevoked, offlineDevice
    }
    public let origin: String
    public let email: String
    public let layer: Layer
    public let title: String
    public let reason: String
    public let detail: String
    public let lastAttemptAt: Date
    public var nextRetryAt: Date?

    public static func origin(for url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.path = ""; parts?.query = nil; parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }
    public static func isLoopback(_ url: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "")
    }
    public static func classify(_ error: Error, baseURL: URL, email: String = "", at: Date = Date(), nextRetryAt: Date? = nil) -> ConnectionIssue {
        let host = URLComponents(string: origin(for: baseURL))?.host ?? baseURL.host ?? "this address"
        let address = host + (baseURL.port.map { ":\($0)" } ?? "")
        var layer: Layer = .backendUnreachable
        var title = "Can’t reach Lemon Bot"
        let reason: String
        let status: Int?
        if let backend = error as? BackendError { status = backend.status }
        else if case ClientError.http(let code) = error { status = code }
        else { status = nil }
        if let status {
            layer = .backendError(status)
            if status == 401 || status == 403 {
                layer = .signedOutOrRevoked; title = "Sign in again"
                reason = "This device is no longer authorized. Sign in or reconnect it to your desktop."
            } else if status == 502 || status == 504 {
                reason = "The proxy at \(address) can’t reach the Lemon Bot service behind it."
            } else if status >= 500 {
                reason = "Lemon Bot at \(address) is having a server problem (\(status))."
            } else { reason = "Lemon Bot at \(address) couldn’t complete the request (\(status))." }
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost:
                reason = "Nothing is answering at \(address) — the Lemon Bot service isn’t running or isn’t reachable."
            case .cannotFindHost, .dnsLookupFailed:
                reason = "The address \(host) couldn’t be found. Check the address and your network or Tailscale connection."
            case .timedOut:
                reason = "Lemon Bot at \(address) took too long to answer. Check that the service and your network are available."
            case .notConnectedToInternet, .networkConnectionLost:
                layer = .offlineDevice; title = "Your device is offline"
                reason = "Your network connection is unavailable. Reconnect to your network or Tailscale and try again."
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
                reason = "A secure connection to \(host) couldn’t be verified. Check the server’s HTTPS certificate and this device’s clock."
            case .appTransportSecurityRequiresSecureConnection:
                reason = "This address requires HTTPS. Use your desktop’s secure Lemon Bot address instead."
            default: reason = "The connection to \(address) failed. Check the service and your network, then try again."
            }
        } else if case ClientError.signedOut = error {
            layer = .signedOutOrRevoked; title = "Sign in again"
            reason = "This device is no longer authorized. Sign in or reconnect it to your desktop."
        } else { reason = "Lemon Bot couldn’t finish connecting. Check the details and try again." }
        return ConnectionIssue(origin: origin(for: baseURL), email: email, layer: layer, title: title, reason: reason, detail: String(reflecting: error) + "\n" + error.localizedDescription, lastAttemptAt: at, nextRetryAt: nextRetryAt)
    }
}

public struct DiscoveredBackend: Identifiable, Equatable, Sendable {
    public var id: String { baseURL.absoluteString }
    public let baseURL: URL
    public let version: String
    public let setupRequired: Bool
}

extension LemonBotStore {
    public var canViewInstance: Bool { member?.role == "owner" || member?.role == "admin" }
    public var canControlInstance: Bool { member?.role == "owner" && instanceStatus?.runtime.actions.isEmpty == false }
    public func retryNow() async throws {
        nextRetryAt = nil
        connectionIssue?.nextRetryAt = nil
        try await refresh()
    }
    func recordConnectionFailure(_ error: Error) {
        guard let account else { return }
        connectionIssue = ConnectionIssue.classify(error, baseURL: account.baseURL, email: account.email, at: lastConnectionAttemptAt ?? Date(), nextRetryAt: nextRetryAt)
    }
    func updateControllerIssue() {
        guard let account else { return }
        if capabilities?.controlConnected == false {
            let controller = instanceStatus?.controller
            connectionIssue = ConnectionIssue(origin: ConnectionIssue.origin(for: account.baseURL), email: account.email, layer: .controllerDown, title: "Lemon isn’t connected", reason: "Lemon Bot is reachable, but its link to Lemon is down. Bots can’t work until Lemon reconnects.", detail: [controller?.url, controller?.state.rawValue, controller?.lastError.map { "\($0.code): \($0.message)" }].compactMap { $0 }.joined(separator: "\n"), lastAttemptAt: lastConnectionAttemptAt ?? Date(), nextRetryAt: controller?.nextRetryAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        } else { connectionIssue = nil }
    }
    @discardableResult public func refreshInstance() async throws -> InstanceStatus {
        let status: InstanceStatus = try await read("/instance")
        try Task.checkCancellation()
        instanceStatus = status
        capabilities?.controlConnected = status.controller.state == .connected
        updateControllerIssue()
        return status
    }
    public func reconnectLemonLink() async throws {
        let status: InstanceStatus = try await mutate("POST", "/instance/reconnect", body: [:])
        instanceStatus = status; capabilities?.controlConnected = status.controller.state == .connected; updateControllerIssue()
    }
    public func performRuntimeAction(_ action: RuntimeAction, confirmed: Bool = false) async throws {
        guard canControlInstance, instanceStatus?.runtime.actions.contains(action) == true, action == .start || confirmed else { throw ClientError.offline }
        var body: JSONObject = [:]
        if action != .start { body["confirm"] = .bool(true) }
        let operation: RuntimeOperation = try await mutate("POST", "/instance/runtime/\(action.rawValue)", body: body)
        instanceStatus?.runtime.operation = operation
    }
    public func waitForRuntimeOperation() async throws {
        let current = generation
        while instanceStatus?.runtime.operation?.state == .running {
            try await Task.sleep(for: .seconds(2))
            try assertGeneration(current)
            _ = try await refreshInstance()
        }
        try assertGeneration(current)
        try await retryNow()
    }
    /// Public, credential-free probes; each origin has an independent two-second deadline.
    public func discoverBackends() async -> [DiscoveredBackend] {
        let candidates = accounts.map(\.baseURL) + [URL(string: "http://127.0.0.1:4080")!, URL(string: "http://localhost:4080")!]
        var seen: Set<String> = []
        let urls = candidates.compactMap { try? HTTPTransport.normalizeBaseURL($0) }.filter { seen.insert($0.absoluteString).inserted }
        let session = httpSession
        return await withTaskGroup(of: DiscoveredBackend?.self) { group in
            for url in urls {
                group.addTask {
                    do {
                        let client = try HTTPTransport(baseURL: url, session: session)
                        let setup: SetupStatus = try await client.read("/setup", timeout: 2)
                        return DiscoveredBackend(baseURL: url, version: setup.version, setupRequired: setup.setupRequired)
                    } catch { return nil }
                }
            }
            var found: [DiscoveredBackend] = []
            for await result in group { if let result { found.append(result) } }
            return found.sorted { $0.id < $1.id }
        }
    }
}
