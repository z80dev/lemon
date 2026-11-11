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
    public var readiness: ModelReadiness?
    public var detected: [DetectedLogin]
    public init(target: Target, default value: Default, providers: [ManagedProvider], readiness: ModelReadiness? = nil, detected: [DetectedLogin] = []) {
        self.target = target; self.default = value; self.providers = providers; self.readiness = readiness; self.detected = detected
    }
    private enum CodingKeys: String, CodingKey { case target, `default`, providers, readiness, detected }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        target = try values.decode(Target.self, forKey: .target)
        self.default = try values.decode(Default.self, forKey: .default)
        providers = try values.decode([ManagedProvider].self, forKey: .providers)
        readiness = try values.decodeIfPresent(ModelReadiness.self, forKey: .readiness)
        detected = try values.decodeIfPresent([DetectedLogin].self, forKey: .detected) ?? []
    }
}

public struct ModelReadiness: Codable, Hashable {
    public enum State: String, Codable { case verified, saved, actionRequired = "action_required", notConfigured = "not_configured" }
    public enum Reason: String, Codable {
        case credentialMissing = "credential_missing", credentialExpired = "credential_expired", credentialRejected = "credential_rejected"
        case modelUnavailable = "model_unavailable", providerUnreachable = "provider_unreachable", checkUnavailable = "check_unavailable"
        case checkFailed = "check_failed", noDefault = "no_default", modelProviderMismatch = "model_provider_mismatch"
    }
    public enum Check: String, Codable { case codexDiscovery = "codex_discovery", modelsEndpoint = "models_endpoint" }
    public var state: State
    public var providerId: String?
    public var modelId: String?
    public var check: Check?
    public var reason: Reason?
    public var availableModelIds: [String]?
    public var suggestedModelId: String?
    public var checkedAtMs: TimestampMs?
}

public struct DetectedLogin: Codable, Hashable {
    public enum Source: String, Codable { case codexCLI = "codex_cli", environment }
    public var source: Source
    public var providerId: String
    public var variable: String?
}

public struct ProviderCheckResult: Codable, Hashable {
    public var management: ProviderManagement
    public var readiness: ModelReadiness
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
