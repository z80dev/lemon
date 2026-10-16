import Foundation

public struct ProviderManagement: Codable, Hashable {
    public struct Target: Codable, Hashable {
        public var id: String
        public var nodeId: ID?
        public var hostname: String
        public init(id: String, nodeId: ID?, hostname: String) { self.id = id; self.nodeId = nodeId; self.hostname = hostname }
    }
    public struct Default: Codable, Hashable {
        public var providerId: String?
        public var modelId: String?
        public init(providerId: String?, modelId: String?) { self.providerId = providerId; self.modelId = modelId }
    }
    public var target: Target
    public var `default`: Default
    public var providers: [ManagedProvider]
    public init(target: Target, default value: Default, providers: [ManagedProvider]) { self.target = target; self.default = value; self.providers = providers }
}

public struct ManagedProvider: Codable, Hashable, Identifiable {
    public enum Method: String, Codable { case apiKey = "api_key", deviceCode = "device_code", unsupported }
    public enum Status: String, Codable {
        case ready, needsLogin = "needs_login", expired, configured
        public var label: String {
            switch self { case .ready: "Ready"; case .needsLogin: "Needs login"; case .expired: "Expired"; case .configured: "Configured" }
        }
    }
    public struct Validation: Codable, Hashable {
        public enum Kind: String, Codable { case resolver }
        public var atMs: TimestampMs
        public var kind: Kind
        public var ready: Bool
        public init(atMs: TimestampMs, kind: Kind = .resolver, ready: Bool) { self.atMs = atMs; self.kind = kind; self.ready = ready }
    }
    public enum ConfigurationOverride: String, Codable { case projectConfiguration = "project_configuration", credentialPool = "credential_pool", externalSecretSource = "external_secret_source" }
    public var id: String
    public var displayName: String
    public var methods: [Method]
    public var configured: Bool
    public var status: Status
    public var lastValidation: Validation?
    public var environmentOverrides: [String]
    public var configurationOverrides: [ConfigurationOverride]
    public init(id: String, displayName: String, methods: [Method], configured: Bool, status: Status, lastValidation: Validation? = nil, environmentOverrides: [String] = [], configurationOverrides: [ConfigurationOverride] = []) {
        self.id = id; self.displayName = displayName; self.methods = methods; self.configured = configured; self.status = status; self.lastValidation = lastValidation; self.environmentOverrides = environmentOverrides; self.configurationOverrides = configurationOverrides
    }
}

/// In-memory presentation only. Never include device codes or URLs in account caches or receipts.
public struct ProviderDeviceLogin: Decodable, Hashable {
    public enum Status: String, Decodable {
        case starting, pending, completed, denied, expired, cancelled, lost, failed
        public var label: String {
            switch self {
            case .starting: "Starting"
            case .pending: "Waiting for sign-in"
            case .completed: "Sign-in completed"
            case .denied: "Sign-in denied"
            case .expired: "Sign-in expired"
            case .cancelled: "Sign-in cancelled"
            case .lost: "Sign-in no longer available"
            case .failed: "Sign-in failed"
            }
        }
    }
    public var loginId: String
    public var targetId: String
    public var providerId: String
    public var status: Status
    public var verificationUrl: String?
    public var userCode: String?
    public var expiresAtMs: TimestampMs?
    public var pollIntervalMs: Double?
    public var terminal: Bool { status != .starting && status != .pending }
    public var browserURL: URL? {
        guard let verificationUrl, verificationUrl == "https://auth.openai.com/codex/device" else { return nil }
        return URL(string: verificationUrl)
    }
    public func validate(loginID: String, targetID: String) throws {
        guard loginId == loginID, targetId == targetID, providerId == "openai_codex" else { throw ClientError.invalidFrame }
        if status == .pending {
            guard browserURL != nil, let code = userCode, (1...64).contains(code.utf8.count),
                  code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }),
                  let expiry = expiresAtMs, expiry.isFinite, expiry > 0,
                  let interval = pollIntervalMs, interval.isFinite, (1000...60000).contains(interval) else { throw ClientError.invalidFrame }
        } else {
            guard verificationUrl == nil, userCode == nil, expiresAtMs == nil, pollIntervalMs == nil else { throw ClientError.invalidFrame }
        }
    }
}
