import Foundation

extension LemonBotStore {
    public var issuedPairing: Pairing? { pairings.first { $0.id == pairingQRID } }
    /// Resolve only the configured account's advertised origin. Never discover or replace its backend.
    /// Re-run this before every owner mutation; the first authenticated baseline pins upgraded accounts.
    public func verifyOwnerPairingOrigin(_ candidate: String? = nil) async throws {
        guard let saved = account else { throw ClientError.signedOut }
        let current = generation
        do {
            let client = BotPreflightClient(session: httpSession)
            let baselineOrigin = try PairingLink.exactOrigin(saved.baseURL)
            let baseline = try await client.identity(origin: baselineOrigin, token: saved.token, use: .sameMachine)
            try assertGeneration(current)
            try BotPreflight.validateIdentity(baseline, expectedInstanceID: saved.instanceID ?? baseline.instanceId, workspaceID: saved.workspaceID, use: .sameMachine)
            let origin = try BotPreflight.validateOrigin(candidate ?? baseline.publicUrl)
            guard URLComponents(string: origin)?.host?.hasSuffix(".ts.net") == true else { throw BotPreflightError.tailscaleRequired }
            // The backend, not this UI, issues the QR. Verify the exact origin it will advertise.
            guard origin == baseline.publicUrl else { throw BotPreflightError.invalidOrigin }
            let result = try await client.preflight(origin: origin, expectedInstanceID: baseline.instanceId, session: BotPreflightSession(token: saved.token, workspaceID: saved.workspaceID))
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
        try await verifyOwnerPairingOrigin(origin)
        try await refreshPairings()
    }
    func requireOwnerPairingPreflight() async throws {
        guard let ready = ownerPairingPreflight, let account,
              ready.identity?.workspaceId == account.workspaceID,
              ready.identity?.instanceId == account.instanceID else { throw PairingClientError.notReady }
        try await verifyOwnerPairingOrigin(ready.origin)
    }
}

public enum OwnerPairingProgress {
    /// Do not poll indefinitely or treat approval as a completed phone connection.
    public static func shouldObserve(_ pairings: [Pairing], now: Date = Date()) -> Bool {
        pairings.contains { ["waiting", "pending_approval", "approved"].contains($0.status) && $0.expiresAtMs > now.timeIntervalSince1970 * 1000 }
    }
}
