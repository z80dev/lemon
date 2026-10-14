import Foundation
import Security

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Codable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object(JSONObject)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode(JSONObject.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var intValue: Int? { if case .number(let v) = self, v.isFinite, v.rounded() == v, v >= Double(Int.min), v < Double(Int.max) { return Int(v) }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var objectValue: JSONObject? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public static func encoding<T: Encodable>(_ value: T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) }
}

/// Decimal comparison deliberately does not convert workspace cursors to machine integers.
public enum WorkspaceCursor {
    public static func normalized(_ value: String) throws -> String {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { throw ClientError.invalidCursor }
        let trimmed = value.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }
    public static func isAfter(_ value: String, _ previous: String) throws -> Bool {
        let a = try normalized(value), b = try normalized(previous)
        return a.count == b.count ? a > b : a.count > b.count
    }
}

public enum ClientError: Error, LocalizedError, CustomStringConvertible {
    case signedOut, insecureEndpoint, invalidPath, invalidCursor, invalidDeepLink, foreignWorkspace
    case accountChanged, offline, invalidBinary, invalidFrame, keychain(OSStatus), http(Int), outcomeUnknown(String)
    case unresolvedMutation(MutationIntent)
    case invalidNonce
    case reauthenticationUnconfirmed
    public var description: String { errorDescription ?? "Lemon Bot client error" }
    public var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in to this backend before continuing."
        case .insecureEndpoint: return "Use HTTPS for a remote backend; HTTP is allowed only on loopback."
        case .invalidPath: return "The product resource path is invalid."
        case .invalidCursor: return "The server sent an invalid workspace cursor."
        case .invalidDeepLink: return "This Lemon Bot link has an unsupported or unsafe destination."
        case .foreignWorkspace: return "Sign in to the saved account for this workspace before opening the link."
        case .accountChanged: return "The active account changed while the request was in flight."
        case .offline: return "Reconnect before authorizing this action. No action has been queued."
        case .invalidBinary: return "The authorized attachment download was incomplete or invalid."
        case .invalidFrame: return "The realtime server sent an invalid frame."
        case .keychain(let status): return "Keychain could not access the saved account (\(status))."
        case .http(let code): return "The backend returned HTTP \(code) without a valid product error."
        case .outcomeUnknown(let nonce): return "outcome_unknown: The action's outcome is not confirmed. Do not resend it. Reconcile the original intent using clientNonce \(nonce)."
        case .unresolvedMutation(let intent):
            if intent.state == "recorded_refusal" { return "The previous message was recorded with rejected targets. Reconcile its saved entries and runs before another submission. Original clientNonce: \(intent.clientNonce). No action was replayed." }
            return "outcome_unknown: Reconcile the previous \(intent.method) \(intent.path) before creating another intent. Original clientNonce: \(intent.clientNonce). No action was replayed."
        case .invalidNonce: return "clientNonce must be a string; the supplied intent identifier was not replaced."
        case .reauthenticationUnconfirmed: return "Reauthentication was not confirmed. No password was automatically retried; request reauthentication explicitly before deleting the account."
        }
    }
}

public struct BackendError: Error, LocalizedError, Hashable, CustomStringConvertible {
    public let status: Int
    public let failure: ErrorEnvelopeError
    public init(status: Int, failure: ErrorEnvelopeError) { self.status = status; self.failure = failure }
    public var description: String { errorDescription ?? failure.code }
    /// Preserve the actual prerequisite and diagnostic request ID; never replace it with a generic provider message.
    public var errorDescription: String? {
        var text = failure.message
        if let details = failure.details, !details.isEmpty {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(details), let diagnostic = String(data: data, encoding: .utf8) {
                text += "\nDetails: " + String(diagnostic.prefix(4096))
            }
        }
        return text + "\nRequest: " + failure.requestId + " (" + failure.code + ")"
    }
}
