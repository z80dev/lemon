import Foundation

/// The web pairing screen's exact loopback hosts, never LAN addresses or localhost aliases.
public enum OwnerPairingAddress {
    public static func isSimulatorOrigin(_ value: String) -> Bool {
        guard (try? BotPreflight.validateOrigin(value, use: .sameMachine)) != nil,
              let parts = URLComponents(string: value), parts.scheme == "http" else { return false }
        return ["localhost", "127.0.0.1", "[::1]"].contains(parts.host ?? "")
    }

    public static func validate(_ value: String, forSimulator: Bool = false) throws -> BotOriginUse {
        #if DEBUG
        if forSimulator && isSimulatorOrigin(value) { return .sameMachine }
        #endif
        _ = try BotPreflight.validateOrigin(value)
        guard URLComponents(string: value)?.host?.hasSuffix(".ts.net") == true else { throw BotPreflightError.tailscaleRequired }
        return .phone
    }
}

extension LemonBotStore {
    public var issuedPairing: Pairing? { pairings.first { $0.id == pairingQRID } }
    /// Resolve only the configured account's advertised origin. Never discover or replace its backend.
    /// Re-run this before every owner mutation; the first authenticated baseline pins upgraded accounts.
    public func verifyOwnerPairingOrigin(_ candidate: String? = nil, forSimulator: Bool = false) async throws {
        guard let saved = account else { throw ClientError.signedOut }
        let current = generation
        do {
            let client = BotPreflightClient(session: httpSession)
            let baselineOrigin = try PairingLink.exactOrigin(saved.baseURL)
            let baseline = try await client.identity(origin: baselineOrigin, token: saved.token, use: .sameMachine)
            try assertGeneration(current)
            try BotPreflight.validateIdentity(baseline, expectedInstanceID: saved.instanceID ?? baseline.instanceId, workspaceID: saved.workspaceID, use: .sameMachine)
            let origin = candidate ?? baseline.publicUrl
            let use = try OwnerPairingAddress.validate(origin, forSimulator: forSimulator)
            // The backend, not this UI, issues the QR. Verify the exact origin it will advertise.
            guard origin == baseline.publicUrl else { throw BotPreflightError.invalidOrigin }
            let result = try await client.preflight(origin: origin, expectedInstanceID: baseline.instanceId, session: BotPreflightSession(token: saved.token, workspaceID: saved.workspaceID), use: use)
            try assertGeneration(current)
            guard result.setup.publicUrl == origin, result.identity?.publicUrl == origin else { throw BotPreflightError.invalidOrigin }
            guard var latest = account, latest.id == saved.id else { throw ClientError.accountChanged }
            if let pinned = latest.instanceID, pinned != baseline.instanceId { throw BotPreflightError.instanceMismatch }
            if latest.instanceID == nil {
                latest.instanceID = baseline.instanceId
                try keychain.save(latest)
                accounts = try keychain.load(); account = latest
            }
            ownerPairingPreflight = result
        } catch {
            // Hide (but retain) the original QR during a failed check; explicit readiness can restore it, never mint another.
            if generation == current { ownerPairingPreflight = nil }
            throw error
        }
    }
    /// A foreground-only, bounded polling fallback supplements existing authenticated realtime.
    public func refreshOwnerPairingStatus() async throws {
        guard let origin = ownerPairingPreflight?.origin else { throw PairingClientError.notReady }
        try await verifyOwnerPairingOrigin(origin, forSimulator: OwnerPairingAddress.isSimulatorOrigin(origin))
        try await refreshPairings()
    }
    func requireOwnerPairingPreflight() async throws {
        guard let ready = ownerPairingPreflight, let account,
              ready.identity?.workspaceId == account.workspaceID,
              ready.identity?.instanceId == account.instanceID else { throw PairingClientError.notReady }
        try await verifyOwnerPairingOrigin(ready.origin, forSimulator: OwnerPairingAddress.isSimulatorOrigin(ready.origin))
    }
}

public enum OwnerPairingProgress {
    /// Reverification must not reveal a retained QR for a different advertised address.
    public static func activeLink(_ value: String?, pairing: Pairing?, verifiedOrigin: String?, now: Date = Date()) -> String? {
        guard let value, let parsed = try? PairingLink.parse(value),
              parsed.origin == verifiedOrigin, let pairing, pairing.status == "waiting",
              pairing.expiresAtMs > now.timeIntervalSince1970 * 1000,
              pairing.backendUrl == parsed.origin else { return nil }
        return value
    }
    /// Do not poll indefinitely or treat approval as a completed phone connection.
    public static func shouldObserve(_ pairings: [Pairing], now: Date = Date()) -> Bool {
        pairings.contains { ["waiting", "pending_approval", "approved"].contains($0.status) && $0.expiresAtMs > now.timeIntervalSince1970 * 1000 }
    }
}
