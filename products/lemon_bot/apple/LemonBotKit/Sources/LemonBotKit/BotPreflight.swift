import Foundation
import Darwin

/// Native implementation of contracts/preflight.md. Phone mode is never inferred from an overlay.
public enum BotOriginUse { case phone, sameMachine }

public enum BotPreflightError: Error, LocalizedError, Equatable {
    case invalidOrigin, loopbackOrigin, tlsRequired, unavailable, wrongService, pairingUnavailable, instanceMismatch, workspaceMismatch, tailscaleRequired
    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: return "Use an exact origin without a trailing slash, credentials, path, query or fragment."
        case .loopbackOrigin: return "A physical iPhone cannot reach this machine-local address. Configure a reachable HTTPS Bot origin."
        case .tlsRequired: return "Pairing requires HTTPS with a normally trusted certificate. Tailscale is not a TLS bypass."
        case .unavailable: return "Cannot reach the Bot API with verified TLS. Check the running backend, Tailscale login, same tailnet, ACL, MagicDNS and certificate."
        case .wrongService: return "This address is not the supported Lemon Bot product API (/v1/setup and /v1/identity). Check the backend and proxy route, not Lemon Web or the operator WebSocket."
        case .pairingUnavailable: return "This Bot backend is not configured for phone pairing. Finish owner setup on the selected running backend."
        case .instanceMismatch: return "The backend identity changed or differs from your configured Bot backend. Keep this connection and repair the intended service; nothing was paired."
        case .workspaceMismatch: return "This is a different Bot workspace. Keep your existing connection and check the selected backend; nothing was paired."
        case .tailscaleRequired: return "Use the backend's exact HTTPS Tailscale MagicDNS origin ending in .ts.net, including its port."
        }
    }
}

public struct BotPairingCapabilities: Codable, Hashable { public var pairing: Bool }
public struct BotSetupDescriptor: Codable, Hashable {
    public var product: String
    public var apiVersion: Int
    public var version: String
    public var setupRequired: Bool
    public var instanceId: String
    public var publicUrl: String
    public var capabilities: BotPairingCapabilities
}
public struct BackendIdentity: Codable, Hashable {
    public var product: String
    public var apiVersion: Int
    public var version: String
    public var instanceId: String
    public var workspaceId: String
    public var publicUrl: String
    public var capabilities: BotPairingCapabilities
}
public struct BotPreflightSession {
    public var token: String
    public var workspaceID: String
    public init(token: String, workspaceID: String) { self.token = token; self.workspaceID = workspaceID }
}
public struct BotPreflightResult: Hashable {
    public var origin: String
    public var setup: BotSetupDescriptor
    /// Nil for the phone's public, credential-free probe: that does not verify workspace identity.
    public var identity: BackendIdentity?
}

public enum BotPreflight {
    public static func validateOrigin(_ value: String, use: BotOriginUse = .phone) throws -> String {
        guard !value.isEmpty, value.utf8.count <= 2048,
              !value.unicodeScalars.contains(where: { $0.value <= 32 || $0.value == 127 || $0 == "\\" }),
              let parts = URLComponents(string: value), let host = parts.host,
              !host.isEmpty, host == host.lowercased(), !host.contains("%"),
              parts.user == nil, parts.password == nil, parts.path.isEmpty,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let scheme = parts.scheme, scheme == scheme.lowercased(),
              value == scheme + "://" + host + (parts.port.map { ":\($0)" } ?? ""),
              !(scheme == "https" && parts.port == 443), !(scheme == "http" && parts.port == 80) else { throw BotPreflightError.invalidOrigin }
        var loopback = false
        if host.hasPrefix("[") {
            let literal = String(host.dropFirst().dropLast())
            var address = in6_addr()
            guard inet_pton(AF_INET6, literal, &address) == 1 else { throw BotPreflightError.invalidOrigin }
            let bytes = withUnsafeBytes(of: &address) { Array($0) }
            loopback = bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] <= 1
                || (bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 255 && bytes[11] == 255 && bytes[12] == 127)
            // WHATWG uses compressed, lowercase hexadecimal IPv6, including mapped IPv4.
            guard literal == canonicalIPv6(bytes) else { throw BotPreflightError.invalidOrigin }
        } else {
            let name = host.hasSuffix(".") ? String(host.dropLast()) : host
            loopback = name == "localhost" || name.hasSuffix(".localhost")
            let labels = name.split(separator: ".", omittingEmptySubsequences: false)
            if let last = labels.last, Int(last) != nil || last.lowercased().hasPrefix("0x") {
                guard labels.count == 4, labels.allSatisfy({ part in
                    guard let number = Int(part), (0...255).contains(number) else { return false }
                    return String(number) == part
                }), !host.hasSuffix(".") else { throw BotPreflightError.invalidOrigin }
                loopback = labels[0] == "127" || name == "0.0.0.0"
            }
            guard name.utf8.count <= 253, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && $0.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 } }) else { throw BotPreflightError.invalidOrigin }
        }
        if use == .phone && loopback { throw BotPreflightError.loopbackOrigin }
        guard scheme == "https" || (use == .sameMachine && loopback && scheme == "http") else { throw BotPreflightError.tlsRequired }
        return value
    }
    private static func canonicalIPv6(_ bytes: [UInt8]) -> String {
        let words = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
        var bestStart = -1, bestCount = 1, start = 0
        while start < 8 {
            if words[start] != 0 { start += 1; continue }
            var end = start
            while end < 8 && words[end] == 0 { end += 1 }
            if end - start > bestCount { bestStart = start; bestCount = end - start }
            start = end
        }
        if bestStart < 0 { return words.map { String($0, radix: 16) }.joined(separator: ":") }
        return words[..<bestStart].map { String($0, radix: 16) }.joined(separator: ":") + "::"
            + words[(bestStart + bestCount)...].map { String($0, radix: 16) }.joined(separator: ":")
    }
    private static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 128 && !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    private static func descriptor(product: String, apiVersion: Int, version: String, instanceID: String) throws {
        guard product == "lemon_bot", apiVersion == 1, identifier(instanceID), !version.isEmpty, version.utf16.count <= 128 else { throw BotPreflightError.wrongService }
    }
    public static func validateSetup(_ value: BotSetupDescriptor, expectedInstanceID: String, use: BotOriginUse = .phone) throws {
        try descriptor(product: value.product, apiVersion: value.apiVersion, version: value.version, instanceID: value.instanceId)
        guard identifier(expectedInstanceID), value.instanceId == expectedInstanceID else { throw BotPreflightError.instanceMismatch }
        _ = try validateOrigin(value.publicUrl, use: use)
        guard !value.setupRequired, value.capabilities.pairing else { throw BotPreflightError.pairingUnavailable }
    }
    public static func validateIdentity(_ value: BackendIdentity, expectedInstanceID: String, workspaceID: String, use: BotOriginUse = .phone) throws {
        try descriptor(product: value.product, apiVersion: value.apiVersion, version: value.version, instanceID: value.instanceId)
        guard identifier(value.workspaceId) else { throw BotPreflightError.wrongService }
        guard identifier(expectedInstanceID), value.instanceId == expectedInstanceID else { throw BotPreflightError.instanceMismatch }
        guard identifier(workspaceID), value.workspaceId == workspaceID else { throw BotPreflightError.workspaceMismatch }
        _ = try validateOrigin(value.publicUrl, use: use)
        guard value.capabilities.pairing else { throw BotPreflightError.pairingUnavailable }
    }
}

/// Read-only probes with a ten-second overall deadline, no cookies/cache, no redirects, and at most 16 KiB per descriptor.
/// A supplied session contributes only its URLProtocol classes (a trusted test seam), never TLS/redirect delegates.
public struct BotPreflightClient {
    private let protocolClasses: [AnyClass]?
    public init(session: URLSession? = nil) { protocolClasses = session?.configuration.protocolClasses }
    public func identity(origin: String, token: String, use: BotOriginUse = .phone) async throws -> BackendIdentity {
        _ = try BotPreflight.validateOrigin(origin, use: use)
        let value: BackendIdentity = try await probe(origin: origin, path: "identity", token: token, deadline: Date().addingTimeInterval(10))
        try BotPreflight.validateIdentity(value, expectedInstanceID: value.instanceId, workspaceID: value.workspaceId, use: use)
        return value
    }
    public func preflight(origin: String, expectedInstanceID: String, session: BotPreflightSession? = nil, use: BotOriginUse = .phone) async throws -> BotPreflightResult {
        _ = try BotPreflight.validateOrigin(origin, use: use)
        let deadline = Date().addingTimeInterval(10)
        let setup: BotSetupDescriptor = try await probe(origin: origin, path: "setup", token: nil, deadline: deadline)
        try BotPreflight.validateSetup(setup, expectedInstanceID: expectedInstanceID, use: use)
        var identity: BackendIdentity?
        if let session {
            let value: BackendIdentity = try await probe(origin: origin, path: "identity", token: session.token, deadline: deadline)
            try BotPreflight.validateIdentity(value, expectedInstanceID: expectedInstanceID, workspaceID: session.workspaceID, use: use)
            identity = value
        }
        return BotPreflightResult(origin: origin, setup: setup, identity: identity)
    }
    private func probe<T: Decodable>(origin: String, path: String, token: String?, deadline: Date) async throws -> T {
        let reader = BotDescriptorReader()
        do {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw BotPreflightError.unavailable }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = protocolClasses
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil; configuration.urlCache = nil
            configuration.timeoutIntervalForResource = remaining
            var request = URLRequest(url: URL(string: origin + "/v1/" + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: remaining)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
            let data = try await reader.read(request, configuration: configuration)
            guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw BotPreflightError.wrongService }
            return value
        } catch is CancellationError { throw CancellationError() }
        catch let error as BotPreflightError { throw error }
        catch let error as BackendError { throw error }
        catch { throw BotPreflightError.unavailable }
    }
}

private final class BotDescriptorReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var data = Data()
    func read(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
                session.finishTasksAndInvalidate()
            }
        }, onCancel: { self.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, response.url == dataTask.originalRequest?.url,
           dataTask.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil,
           http.statusCode == 401 || http.statusCode == 403 {
            let forbidden = http.statusCode == 403
            let failure = ErrorEnvelopeError(code: forbidden ? "forbidden" : "unauthenticated", message: "This product session is no longer authorized. Reconnect this device.", requestId: "identity", retrySafe: false)
            completionHandler(.cancel); finish(.failure(BackendError(status: http.statusCode, failure: failure))); return
        }
        // A gateway outage is not evidence of a different service. Preserve the
        // saved identity pin and retry the read-only fence before using its session.
        if let http = response as? HTTPURLResponse,
           response.url == dataTask.originalRequest?.url,
           [502, 503, 504].contains(http.statusCode) {
            completionHandler(.cancel); finish(.failure(BotPreflightError.unavailable)); return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == dataTask.originalRequest?.url,
              http.mimeType?.lowercased() == "application/json", response.expectedContentLength <= 16384 else {
            completionHandler(.cancel); finish(.failure(BotPreflightError.wrongService)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 16384 else { finish(.failure(BotPreflightError.wrongService)); dataTask.cancel(); return }
        data.append(chunk)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.success(data)) }
    }
}
