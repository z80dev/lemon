import Foundation

public enum PairingClientError: Error, LocalizedError {
    case invalidLink, pendingConnection, notReady, expired, denied, wrongCluster, unconfirmed, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .invalidLink: return "That isn't a valid Lemon Bot pairing link. Scan a fresh QR from your Mac. Remote workspaces need an HTTPS address."
        case .pendingConnection: return "Finish or cancel the saved connection request before scanning another QR."
        case .notReady: return "Scan or paste a desktop pairing link before requesting a connection."
        case .expired: return "This request expired. Create a new QR code on your Mac."
        case .denied: return "Your Mac denied this device. Create a new QR code to request a connection again."
        case .wrongCluster: return "The server's workspace or device doesn't match the QR code. Nothing was installed. Scan a fresh QR from your Mac."
        case .unconfirmed: return "We couldn't confirm the connection. Check your saved request before scanning another QR code."
        case .rejected: return "Your Mac couldn't finish connecting this iPhone. Nothing was installed. Check your request."
        }
    }
}

extension PairingLink: CustomStringConvertible, CustomDebugStringConvertible {
    public var backendURL: URL? { URL(string: backendUrl).flatMap { try? HTTPTransport.normalizeBaseURL($0) } }
    public var origin: String { backendUrl }
    public var workspaceID: ID { workspaceId }
    public var description: String { "Lemon Bot pairing link (one-use code redacted)" }
    public var debugDescription: String { description }

    public static func parse(_ raw: String) throws -> PairingLink {
        guard !raw.isEmpty, raw.utf8.count <= 4096,
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: raw), parts.scheme == "lemonbot", parts.host == "pair",
              parts.path.isEmpty || parts.path == "/", parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 4, items.map(\.name).sorted() == ["backend", "cluster", "code", "instance"],
              let backend = items.first(where: { $0.name == "backend" })?.value,
              let instance = items.first(where: { $0.name == "instance" })?.value,
              let workspace = items.first(where: { $0.name == "cluster" })?.value,
              let code = items.first(where: { $0.name == "code" })?.value,
              boundedID(instance), boundedID(workspace), boundedSecret(code),
              backend.utf8.count <= 2048, let url = URL(string: backend),
              let endpoint = URLComponents(url: url, resolvingAgainstBaseURL: false),
              endpoint.path.isEmpty || endpoint.path == "/",
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              let host = endpoint.host, !host.isEmpty, host.utf8.count <= 253,
              !host.contains("%"), !host.contains("\\"), !backend.contains("\\"),
              endpoint.port.map({ (1...65535).contains($0) }) ?? true else { throw PairingClientError.invalidLink }
        _ = try HTTPTransport.normalizeBaseURL(url)
        return PairingLink(backendUrl: try exactOrigin(url), instanceId: instance, workspaceId: workspace, pairCode: code)
    }
    static func boundedID(_ value: String) -> Bool {
        !value.isEmpty && value.utf16.count <= 128 && value.unicodeScalars.allSatisfy { $0.value > 32 && $0 != "/" }
    }
    static func boundedSecret(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    static func exactOrigin(_ url: URL) throws -> String {
        _ = try HTTPTransport.normalizeBaseURL(url)
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PairingClientError.invalidLink }
        parts.path = ""; parts.query = nil; parts.fragment = nil
        guard let origin = parts.string else { throw PairingClientError.invalidLink }
        return origin
    }
}

/// Safe device/cluster preview. One-use QR and claim authority never appear here.
public struct PendingPairingPreview: Hashable {
    public var clusterName: String
    public var origin: String
    public var workspaceID: ID
    public var pairingID: ID?
    public var deviceName: String?
    public var verificationCode: String?
    public var expiresAtMs: TimestampMs?
}

/// Saved only by AccountKeychain, never by the nonsecret workspace cache.
public struct PendingDevicePairing: Codable {
    var link: PairingLink
    var claimNonce: String
    var completionNonce: String
    var installationID: String
    var deviceName: String?
    var appVersion: String?
    var claim: PairingClaimResult?
    var preview: PairingPreviewResult?
    var state: String
    var savedAtMs: TimestampMs
}

extension LemonBotStore {
    func installPendingPairing(_ value: PendingDevicePairing) {
        pairingRecord = value
        pairingLink = value.link
        pendingPairing = PendingPairingPreview(clusterName: value.claim?.clusterName ?? value.preview?.clusterName ?? "Check cluster before requesting connection", origin: value.link.origin, workspaceID: value.link.workspaceId, pairingID: value.claim?.pairingId, deviceName: value.deviceName, verificationCode: value.claim?.verificationCode, expiresAtMs: value.claim?.expiresAtMs ?? value.preview?.expiresAtMs)
        pairingState = value.state == "claiming" ? "claim_unknown" : value.state == "completing" ? "completion_unknown" : value.state
        pairingError = nil
    }
    public func preparePairing(_ rawLink: String) throws {
        let link = try PairingLink.parse(rawLink)
        if let record = pairingRecord {
            guard record.link == link else { throw PairingClientError.pendingConnection }
            return
        }
        let record = PendingDevicePairing(link: link, claimNonce: UUID().uuidString, completionNonce: UUID().uuidString, installationID: Self.installationID(), state: "preview", savedAtMs: Date().timeIntervalSince1970 * 1000)
        try keychain.savePendingPairing(record)
        installPendingPairing(record)
    }
    public func previewPairing() async throws {
        guard var record = pairingRecord, record.claim == nil,
              ["preview", "preview_ready"].contains(pairingState), let url = record.link.backendURL else { throw PairingClientError.notReady }
        pairingState = "previewing"; pairingError = nil
        do {
            let result = try await pairingTransport(baseURL: url).previewPairing(PairingPreviewRequest(pairCode: record.link.pairCode, workspaceId: record.link.workspaceId))
            guard pairingRecord?.claimNonce == record.claimNonce,
                  let backend = URL(string: result.backendUrl), try PairingLink.exactOrigin(backend) == record.link.origin,
                  !result.clusterName.isEmpty, result.clusterName.utf8.count <= 240,
                  result.expiresAtMs.isFinite, result.expiresAtMs > Date().timeIntervalSince1970 * 1000 else { throw PairingClientError.wrongCluster }
            record.preview = result; record.state = "preview_ready"
            try keychain.savePendingPairing(record); installPendingPairing(record)
        } catch {
            if pairingRecord?.claimNonce == record.claimNonce {
                record.state = (error as? BackendError)?.failure.code == "expired" ? "expired" : "preview"
                try keychain.savePendingPairing(record); installPendingPairing(record)
                pairingError = record.state == "expired" ? PairingClientError.expired.localizedDescription : "The cluster could not be verified. Check its reachable HTTPS address and preview again; no connection was requested."
            }
            throw errorForPairing(error)
        }
    }
    public func cancelPairing() throws {
        guard !["claiming", "completing", "previewing"].contains(pairingState) else { throw PairingClientError.pendingConnection }
        try keychain.removePendingPairing()
        pairingRecord = nil; pairingLink = nil; pendingPairing = nil; pairingState = "idle"; pairingError = nil
    }
    public func requestPairing(deviceName: String, appVersion: String) async throws {
        guard var record = pairingRecord, record.claim == nil,
              ["preview_ready", "claim_unknown"].contains(pairingState), let preview = record.preview, let url = record.link.backendURL else { throw PairingClientError.notReady }
        guard !deviceName.isEmpty, deviceName.utf8.count <= 120, !appVersion.isEmpty, appVersion.utf8.count <= 64 else { throw PairingClientError.notReady }
        record.deviceName = record.deviceName ?? deviceName
        record.appVersion = record.appVersion ?? appVersion
        record.state = "claiming"
        try keychain.savePendingPairing(record); installPendingPairing(record); pairingState = "claiming"
        let originalNonce = record.claimNonce
        do {
            let client = try pairingTransport(baseURL: url)
            let result: PairingClaimResult = try await client.mutate("POST", "/pairings/claim", body: ["clientNonce": .string(record.claimNonce), "pairCode": .string(record.link.pairCode), "workspaceId": .string(record.link.workspaceId), "installationId": .string(record.installationID), "deviceName": .string(record.deviceName!), "appVersion": .string(record.appVersion!)])
            guard pairingRecord?.claimNonce == originalNonce else { throw PairingClientError.pendingConnection }
            guard let backend = URL(string: result.backendUrl), try PairingLink.exactOrigin(backend) == record.link.origin,
                  PairingLink.boundedID(result.pairingId), PairingLink.boundedSecret(result.claimToken),
                  !result.clusterName.isEmpty, result.clusterName.utf8.count <= 240,
                  result.verificationCode.utf8.count == 6, result.verificationCode.utf8.allSatisfy({ (48...57).contains($0) }),
                  result.expiresAtMs.isFinite, result.expiresAtMs > Date().timeIntervalSince1970 * 1000 else { throw PairingClientError.wrongCluster }
            guard result.clusterName == preview.clusterName, result.expiresAtMs == preview.expiresAtMs else { throw PairingClientError.wrongCluster }
            record.claim = result; record.state = "pending_approval"
            try keychain.savePendingPairing(record); installPendingPairing(record)
        } catch {
            record.state = pairingFailureState(error, unknown: "claim_unknown")
            do { try keychain.savePendingPairing(record); installPendingPairing(record) } catch { pairingState = "claim_unknown" }
            pairingError = safePairingError(error)
            throw errorForPairing(error)
        }
    }
    public func completePairing() async throws {
        guard var record = pairingRecord, let claim = record.claim, let url = record.link.backendURL,
              ["pending_approval", "completion_unknown"].contains(pairingState) else { throw PairingClientError.notReady }
        record.state = "completing"
        try keychain.savePendingPairing(record); installPendingPairing(record); pairingState = "completing"
        let originalNonce = record.claimNonce
        do {
            let client = try pairingTransport(baseURL: url)
            let result: PairingCompletion = try await client.mutate("POST", "/pairings/\(HTTPTransport.pathID(claim.pairingId))/complete", body: ["clientNonce": .string(record.completionNonce), "claimToken": .string(claim.claimToken)])
            guard pairingRecord?.claimNonce == originalNonce else { throw PairingClientError.pendingConnection }
            switch result {
            case .pending(let progress):
                guard progress.pairingId == claim.pairingId, progress.expiresAtMs == claim.expiresAtMs else { throw PairingClientError.wrongCluster }
                record.state = progress.status == "pending" ? "pending_approval" : progress.status
                try keychain.savePendingPairing(record); installPendingPairing(record)
                if progress.status == "denied" { throw PairingClientError.denied }
                if progress.status == "expired" { throw PairingClientError.expired }
            case .connected(let connected):
                let auth = connected.auth
                guard auth.workspace.id == record.link.workspaceId, auth.user.id == auth.session.userId,
                      connected.device.userId == auth.user.id, auth.session.deviceId == connected.device.id,
                      connected.device.platform == "ios", auth.session.expiresAtMs == nil,
                      !auth.token.isEmpty, auth.token.utf8.count <= 4096 else { throw PairingClientError.wrongCluster }
                let saved = try saveAuthenticatedAccount(auth, baseURL: url, deviceID: connected.device.id, installationID: record.installationID)
                try keychain.removePendingPairing()
                pairingRecord = nil; pairingLink = nil; pendingPairing = nil; pairingState = "connected"; pairingError = nil
                // A saved credential is durable even if the subsequent read-only sync loses connectivity.
                do { try await restoreAccount(saved) }
                catch {
                    if connectionState == "reconnect_required" { throw error }
                    errorMessage = "The device credential is saved in Keychain, but initial synchronization failed: " + error.localizedDescription
                }
            }
        } catch {
            if pairingRecord?.claimNonce == originalNonce {
                record.state = pairingFailureState(error, unknown: "completion_unknown")
                do { try keychain.savePendingPairing(record); installPendingPairing(record) } catch { pairingState = "completion_unknown" }
                pairingError = safePairingError(error)
            }
            throw errorForPairing(error)
        }
    }
    public func createPairing() async throws {
        guard connectionState == "online" else { throw ClientError.offline }
        let result: PairingIssued = try await mutate("POST", "/pairings", body: [:])
        try installPairingIssuance(result)
    }
    /// Explicit receipt reconciliation only: the backend replays the original one-use QR.
    public func reconcilePairingIssuance() async throws {
        guard connectionState == "online", let account else { throw ClientError.offline }
        guard let intent = pendingIntents.first(where: { $0.method == "POST" && $0.path == "/pairings" }), intent.state != "in_flight" else { throw PairingClientError.notReady }
        let current = generation
        do {
            let result: PairingIssued = try await activeTransport().mutate("POST", "/pairings", body: ["clientNonce": .string(intent.clientNonce)])
            try assertGeneration(current)
            try installPairingIssuance(result)
            finishIntent((account.id, intent.clientNonce))
        } catch let error as BackendError where error.failure.code == "expired" {
            try assertGeneration(current)
            finishIntent((account.id, intent.clientNonce))
            throw PairingClientError.expired
        }
    }
    private func installPairingIssuance(_ result: PairingIssued) throws {
        guard let account else { throw ClientError.signedOut }
        let link = try PairingLink.parse(result.pairUrl)
        guard result.pairing.ownerUserId == account.userID, result.pairing.workspaceId == account.workspaceID,
              link.workspaceId == account.workspaceID, link.backendURL != nil,
              let endpoint = URL(string: result.pairing.backendUrl),
              try PairingLink.exactOrigin(endpoint) == link.origin,
              result.pairing.status == "waiting" else { throw PairingClientError.wrongCluster }
        pairingURL = result.pairUrl
        pairingQRID = result.pairing.id
        upsert(&pairings, result.pairing, id: { $0.id }, revision: { $0.revision })
    }
    public func refreshPairings() async throws {
        let values: [Pairing] = try await read("/pairings")
        guard let account, values.allSatisfy({ $0.ownerUserId == account.userID && $0.workspaceId == account.workspaceID }) else { throw PairingClientError.wrongCluster }
        pairings = values
        for intent in pendingIntents where intent.path.hasPrefix("/pairings/") {
            let parts = intent.path.split(separator: "/")
            guard parts.count == 3, ["approve", "deny"].contains(String(parts[2])) else { continue }
            let id = String(parts[1]).removingPercentEncoding ?? String(parts[1])
            let value: Pairing = try await read("/pairings/\(HTTPTransport.pathID(id))")
            upsert(&pairings, value, id: { $0.id }, revision: { $0.revision })
            if value.status == "expired" || (parts[2] == "approve" && ["approved", "consumed"].contains(value.status)) || (parts[2] == "deny" && value.status == "denied") { finishIntent((account.id, intent.clientNonce)) }
        }
        if let id = pairingQRID, !pairings.contains(where: { $0.id == id && $0.status == "waiting" && $0.expiresAtMs > Date().timeIntervalSince1970 * 1000 }) { pairingURL = nil }
    }
    public func approvePairing(_ pairing: Pairing) async throws {
        guard connectionState == "online", pairing.status == "pending_approval", let code = pairing.verificationCode,
              pairing.ownerUserId == account?.userID, pairing.workspaceId == account?.workspaceID,
              pairing.expiresAtMs > Date().timeIntervalSince1970 * 1000 else { throw PairingClientError.notReady }
        let value: Pairing = try await mutate("POST", "/pairings/\(HTTPTransport.pathID(pairing.id))/approve", body: ["revision": .number(Double(pairing.revision)), "verificationCode": .string(code)])
        upsert(&pairings, value, id: { $0.id }, revision: { $0.revision }); pairingURL = nil
    }
    public func denyPairing(_ pairing: Pairing) async throws {
        guard connectionState == "online", ["waiting", "pending_approval"].contains(pairing.status),
              pairing.ownerUserId == account?.userID, pairing.workspaceId == account?.workspaceID else { throw PairingClientError.notReady }
        let value: Pairing = try await mutate("POST", "/pairings/\(HTTPTransport.pathID(pairing.id))/deny", body: ["revision": .number(Double(pairing.revision))])
        upsert(&pairings, value, id: { $0.id }, revision: { $0.revision }); pairingURL = nil
    }
    static func installationID() -> String {
        let defaults = UserDefaults.standard
        let key = "LemonBot.installationID"
        if let value = defaults.string(forKey: key) { return value }
        let value = UUID().uuidString; defaults.set(value, forKey: key); return value
    }
    private func pairingTransport(baseURL: URL) throws -> HTTPTransport { try HTTPTransport(baseURL: baseURL, session: httpSession) }
    private func pairingFailureState(_ error: Error, unknown: String) -> String {
        if let safe = error as? PairingClientError {
            if case .denied = safe { return "denied" }
            if case .expired = safe { return "expired" }
        }
        if let backend = error as? BackendError {
            if backend.failure.code == "expired" { return "expired" }
            if backend.failure.code == "forbidden" { return "denied" }
            if backend.failure.code != "outcome_unknown", backend.status < 500 || backend.failure.retrySafe { return "failed" }
        }
        return unknown
    }
    private func errorForPairing(_ error: Error) -> Error {
        if let safe = error as? PairingClientError { return safe }
        if let backend = error as? BackendError {
            if backend.failure.code == "expired" { return PairingClientError.expired }
            if backend.failure.code == "forbidden" { return PairingClientError.denied }
            return PairingClientError.rejected(backend.failure.code)
        }
        if let safe = error as? ClientError, case .keychain = safe { return safe }
        return PairingClientError.unconfirmed
    }
    private func safePairingError(_ error: Error) -> String { errorForPairing(error).localizedDescription }
}
