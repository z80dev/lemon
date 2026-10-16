import Foundation
import Observation

/// Volatile settings state, deliberately outside Codable snapshots, drafts and Keychain.
@MainActor @Observable public final class ProviderSettingsState {
    public internal(set) var machineID: ID?
    public internal(set) var management: ProviderManagement?
    public internal(set) var busy = false
    public internal(set) var message: String?
    public internal(set) var editingProviderID: String?
    public var secret = ""
    public internal(set) var confirmation: Confirmation?
    public internal(set) var deviceLogin: ProviderDeviceLogin?
    public internal(set) var visible = false
    public internal(set) var active = true
    public internal(set) var deviceUnknown = false
    public internal(set) var reviewedUnknownChange = false
    public internal(set) var reviewedUnreachableDeviceLogin = false
    @ObservationIgnored var context = UUID()
    @ObservationIgnored var deviceIntent: DeviceIntent?
    @ObservationIgnored var lastDeviceAction: String?

    public enum Confirmation: Equatable {
        case disconnect(providerID: String, target: ProviderManagement.Target)
        case changeDefault(providerID: String, modelID: String, target: ProviderManagement.Target)
    }
    struct DeviceIntent {
        var loginID: String
        var startNonce: String
        var pollNonce: String
        var cancelNonce: String
        var sessionID: ID?
        var observationDeadline = Date().timeIntervalSince1970 + 900
    }
    public init() {}
    public func clearCredential() { secret = ""; editingProviderID = nil }
    public func cancelConfirmation() { confirmation = nil }
    public func setPresentation(visible: Bool, active: Bool) {
        self.visible = visible; self.active = active
        if !visible || !active { clearCredential(); confirmation = nil; reviewedUnknownChange = false }
    }
    func reset(machineID: ID? = nil) {
        context = UUID(); self.machineID = machineID; management = nil; busy = false; message = nil
        clearCredential(); confirmation = nil; deviceLogin = nil; deviceIntent = nil; deviceUnknown = false
        lastDeviceAction = nil
        reviewedUnknownChange = false
        reviewedUnreachableDeviceLogin = false
    }
    public var nextPollDelay: Double? {
        guard visible, active, !busy, !deviceUnknown, let login = deviceLogin,
              !login.terminal, let intent = deviceIntent,
              Date().timeIntervalSince1970 < intent.observationDeadline else { return nil }
        if login.status == .starting { return 2 }
        guard let expiry = login.expiresAtMs, expiry > Date().timeIntervalSince1970 * 1000,
              let interval = login.pollIntervalMs else { return nil }
        return min(60, max(1, interval / 1000))
    }
}

extension LemonBotStore {
    public var ownedProviderMachines: [Machine] { machines.filter { $0.ownerUserId == account?.userID && $0.status != "revoked" } }
    public var providerBasePath: String {
        if let id = providerSettings.machineID {
            guard let encoded = try? HTTPTransport.pathID(id) else { return "/invalid-provider-target" }
            return "/machines/\(encoded)/providers"
        }
        return "/instance/providers"
    }
    public var providerPendingIntents: [MutationIntent] { pendingIntents.filter { $0.path == providerBasePath || $0.path.hasPrefix(providerBasePath + "/") } }
    public var canManageProviders: Bool {
        member?.role == "owner" && account != nil && connectionState == "online" &&
        (providerSettings.machineID == nil || ownedProviderMachines.contains { $0.id == providerSettings.machineID && $0.status == "online" && $0.nodeId != nil && (try? HTTPTransport.pathID($0.id)) != nil })
    }
    public var canWriteProviders: Bool {
        canManageProviders && providerSettings.management != nil && !providerSettings.busy &&
        !providerSettings.deviceUnknown && providerSettings.deviceLogin?.terminal != false && providerPendingIntents.isEmpty
    }

    public func selectProviderTarget(machineID: ID?) async {
        providerSettings.reset(machineID: machineID)
        await reloadProviders()
    }
    private func validProviderContext(_ context: UUID, _ generation: UUID) -> Bool {
        context == providerSettings.context && generation == self.generation && member?.role == "owner"
    }
    private func validateProviderManagement(_ value: ProviderManagement) throws {
        guard !value.target.id.isEmpty, !value.target.hostname.isEmpty else { throw ClientError.invalidFrame }
        if let id = providerSettings.machineID {
            guard let machine = ownedProviderMachines.first(where: { $0.id == id }), let node = machine.nodeId,
                  value.target.nodeId == node else { throw ClientError.invalidFrame }
        } else { guard value.target.nodeId == nil else { throw ClientError.invalidFrame } }
    }
    public func reloadProviders(reviewingUnknownChange: Bool = false) async {
        let state = providerSettings, context = state.context, current = generation
        guard canManageProviders, !state.busy else { return }
        state.busy = true
        state.reviewedUnknownChange = false
        state.reviewedUnreachableDeviceLogin = false
        defer { if validProviderContext(context, current) { state.busy = false } }
        do {
            let result: ProviderManagement = try await read(providerBasePath)
            guard validProviderContext(context, current) else { return }
            try validateProviderManagement(result)
            state.management = result
            state.message = providerPendingIntents.isEmpty ? nil : "The original action is still unconfirmed. This status does not prove it settled. It will not be resubmitted."
            state.reviewedUnknownChange = reviewingUnknownChange && !providerPendingIntents.isEmpty &&
                providerPendingIntents.allSatisfy { !$0.path.contains("/device-login") && $0.resourceIDs == [result.target.id] }
            state.reviewedUnreachableDeviceLogin = reviewingUnknownChange && !providerPendingIntents.isEmpty &&
                providerPendingIntents.allSatisfy {
                    $0.path.contains("/openai_codex/device-login") && $0.resourceIDs == [result.target.id] &&
                    ($0.providerSessionID == nil || $0.providerSessionID != account?.sessionID)
                }
        } catch {
            guard validProviderContext(context, current) else { return }
            state.management = nil
            state.clearCredential(); state.confirmation = nil
            state.message = "Provider status is unavailable. Check the connection, owner access and target capabilities. No empty inventory is inferred."
        }
    }
    /// Explicit permission for a new intent after reviewing status, never a retry or proof
    /// that the previous write settled. Generic/background reads cannot release this fence.
    public func beginNewProviderChangeAfterReview() {
        let state = providerSettings
        guard canManageProviders, !state.busy, state.reviewedUnknownChange, let target = state.management?.target,
              !providerPendingIntents.isEmpty,
              providerPendingIntents.allSatisfy({ !$0.path.contains("/device-login") && $0.resourceIDs == [target.id] }),
              let account else { return }
        for intent in providerPendingIntents { finishIntent((account.id, intent.clientNonce)) }
        state.reviewedUnknownChange = false
        state.message = providerPendingIntents.isEmpty
            ? "The earlier change is still unconfirmed. Only a separately chosen new change can be sent; nothing was retried."
            : "The original operation remains fenced because its reconciliation reference could not be updated."
    }
    /// Retire only the local fence of an unreachable session, never assert settlement
    /// or replay its login. A new login still requires its own explicit authorization.
    public func retireUnreachableProviderDeviceLoginAfterReview() {
        let state = providerSettings
        guard canManageProviders, !state.busy, state.reviewedUnreachableDeviceLogin,
              let target = state.management?.target, let account, !providerPendingIntents.isEmpty,
              providerPendingIntents.allSatisfy({
                  $0.path.contains("/openai_codex/device-login") && $0.resourceIDs == [target.id] &&
                  ($0.providerSessionID == nil || $0.providerSessionID != account.sessionID)
              }) else { return }
        for intent in providerPendingIntents { finishIntent((account.id, intent.clientNonce)) }
        state.reviewedUnreachableDeviceLogin = false
        guard providerPendingIntents.isEmpty else { return }
        state.deviceIntent = nil; state.deviceLogin = nil; state.deviceUnknown = false; state.lastDeviceAction = nil
        state.message = "The previous session's login is still unconfirmed, not settled or revoked. Its local fence was retired without replay. Choose Sign in separately to authorize a new login."
    }
    public func beginProviderCredential(_ providerID: String) {
        let state = providerSettings
        state.clearCredential()
        guard canWriteProviders, state.management?.providers.first(where: { $0.id == providerID })?.methods.contains(.apiKey) == true else { return }
        state.editingProviderID = providerID; state.confirmation = nil
    }
    public func submitProviderCredential() async {
        let state = providerSettings
        let value = state.secret, providerID = state.editingProviderID
        state.clearCredential() // Before validation or the first suspension, on every submit path.
        guard let providerID, canWriteProviders,
              state.management?.providers.first(where: { $0.id == providerID })?.methods.contains(.apiKey) == true,
              !value.isEmpty, value.utf8.count <= 16384, !value.contains("\0") else {
            state.message = "Enter a nonempty API key (at most 16,384 UTF-8 bytes, without NUL)."; return
        }
        await writeProviderManagement("PUT", suffix: "/\(providerID)/api-key", extra: ["value": .string(value)])
    }
    public func requestProviderDisconnect(_ providerID: String) {
        let state = providerSettings
        guard canWriteProviders, let management = state.management, management.providers.contains(where: { $0.id == providerID }) else { return }
        state.clearCredential(); state.confirmation = .disconnect(providerID: providerID, target: management.target)
    }
    public func requestProviderDefault(providerID: String, modelID: String) {
        let state = providerSettings
        guard canWriteProviders, let management = state.management,
              management.providers.contains(where: { $0.id == providerID }), !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.clearCredential(); state.confirmation = .changeDefault(providerID: providerID, modelID: modelID, target: management.target)
    }
    public func confirmProviderChange(_ confirmation: ProviderSettingsState.Confirmation?) async {
        let state = providerSettings
        state.confirmation = nil
        guard canWriteProviders, let confirmation else { return }
        switch confirmation {
        case .disconnect(let providerID, let target):
            guard target == state.management?.target else { return }
            await writeProviderManagement("POST", suffix: "/\(providerID)/disconnect")
        case .changeDefault(let providerID, let modelID, let target):
            guard target == state.management?.target else { return }
            await writeProviderManagement("POST", suffix: "/default", extra: ["providerId": .string(providerID), "modelId": .string(modelID)])
        }
    }
    private func writeProviderManagement(_ method: String, suffix: String, extra: JSONObject = [:]) async {
        let state = providerSettings, context = state.context, current = generation
        guard canWriteProviders, let target = state.management?.target else { return }
        // The provider ID is always selected from metadata, but still encode it as a path component.
        let components = suffix.split(separator: "/")
        guard let encoded = try? components.map({ try HTTPTransport.pathID(String($0)) }).joined(separator: "/") else { return }
        var body = extra; body["targetId"] = .string(target.id)
        state.busy = true; state.message = nil
        defer { if validProviderContext(context, current) { state.busy = false; state.clearCredential() } }
        do {
            let result: ProviderManagement = try await mutate(method, providerBasePath + "/" + encoded, body: body)
            guard validProviderContext(context, current) else { return }
            try validateProviderManagement(result)
            guard result.target == target else { throw ClientError.invalidFrame }
            state.management = result
        } catch {
            guard validProviderContext(context, current) else { return }
            // Never retain or display arbitrary backend errors from a credential mutation.
            state.message = providerPendingIntents.isEmpty ? "The provider action could not be completed. Check status before trying again." : "The action is unconfirmed. Check status; do not submit it again. The original operation remains fenced."
        }
    }

    public func startProviderDeviceLogin() async {
        let state = providerSettings
        state.clearCredential()
        guard canWriteProviders, state.management?.providers.first(where: { $0.id == "openai_codex" })?.methods.contains(.deviceCode) == true,
              state.deviceLogin == nil || state.deviceLogin?.terminal == true else { return }
        guard let sessionID = account?.sessionID, !sessionID.isEmpty else {
            state.message = "Reconnect to establish a session before starting device login."; return
        }
        let nonce = UUID().uuidString
        state.deviceLogin = nil; state.deviceUnknown = false
        state.deviceIntent = .init(loginID: nonce, startNonce: nonce, pollNonce: UUID().uuidString, cancelNonce: UUID().uuidString, sessionID: sessionID)
        await performProviderDeviceAction("start")
    }
    public func pollProviderDeviceLogin() async {
        guard providerSettings.nextPollDelay != nil else { return }
        await performProviderDeviceAction("poll")
    }
    public func cancelProviderDeviceLogin() async {
        providerSettings.clearCredential()
        guard !providerSettings.deviceUnknown, providerSettings.deviceLogin?.terminal == false else { return }
        await performProviderDeviceAction("cancel")
    }
    /// Explicit reconciliation only. The safe journal supplies the exact original route/target/nonce.
    public func reconcileProviderDeviceLogin() async {
        let state = providerSettings
        guard canManageProviders, !state.busy, let target = state.management?.target else { return }
        guard let intent = providerPendingIntents.first(where: { $0.path.contains("/openai_codex/device-login") }) else {
            if state.deviceUnknown, let action = state.lastDeviceAction { await performProviderDeviceAction(action) }
            else if state.deviceIntent != nil, state.deviceLogin?.terminal == false { await performProviderDeviceAction("poll") }
            return
        }
        guard intent.resourceIDs == [target.id] else { return }
        guard let sessionID = account?.sessionID, intent.providerSessionID == sessionID else {
            state.message = "This login belongs to an earlier or unidentified session and cannot be replayed. Check status, then explicitly retire its local fence before choosing a new login. The old operation remains unconfirmed."
            return
        }
        let parts = intent.path.split(separator: "/").map(String.init)
        guard let index = parts.firstIndex(of: "device-login") else { return }
        let loginID = parts.count == index + 1 ? intent.clientNonce : parts[index + 1].removingPercentEncoding ?? parts[index + 1]
        if state.deviceIntent?.loginID != loginID {
            state.deviceIntent = .init(loginID: loginID, startNonce: loginID, pollNonce: UUID().uuidString, cancelNonce: UUID().uuidString, sessionID: sessionID)
        }
        if parts.last == "poll" { state.deviceIntent?.pollNonce = intent.clientNonce }
        if parts.last == "cancel" { state.deviceIntent?.cancelNonce = intent.clientNonce }
        await performProviderDeviceAction(parts.last == "poll" ? "poll" : parts.last == "cancel" ? "cancel" : "start", reconciling: intent)
    }
    private func performProviderDeviceAction(_ action: String, reconciling: MutationIntent? = nil) async {
        let state = providerSettings, context = state.context, current = generation
        guard canManageProviders, !state.busy, let target = state.management?.target, let intent = state.deviceIntent,
              let sessionID = account?.sessionID, intent.sessionID == sessionID,
              reconciling != nil || providerPendingIntents.isEmpty else { return }
        let nonce = action == "start" ? intent.startNonce : action == "poll" ? intent.pollNonce : intent.cancelNonce
        guard let loginID = try? HTTPTransport.pathID(intent.loginID) else { return }
        let path = providerBasePath + "/openai_codex/device-login" + (action == "start" ? "" : "/\(loginID)/\(action)")
        let body: JSONObject = ["clientNonce": .string(nonce), "targetId": .string(target.id)]
        state.busy = true; state.message = nil
        state.lastDeviceAction = action
        do {
            let result: ProviderDeviceLogin
            if let reconciling {
                result = try await journaledMutate("POST", path, body: body, as: ProviderDeviceLogin.self, reconcilingProviderNonce: reconciling.clientNonce)
                try assertGeneration(current)
            } else { result = try await mutate("POST", path, body: body) }
            guard validProviderContext(context, current) else { return }
            try result.validate(loginID: intent.loginID, targetID: target.id)
            state.deviceLogin = result; state.deviceUnknown = false; state.busy = false
            if let expiry = result.expiresAtMs { state.deviceIntent?.observationDeadline = expiry / 1000 }
            if result.terminal { await reloadProviders() }
        } catch {
            if generation == current, let backend = error as? BackendError, backend.status == 401 { markReconnectRequired(); return }
            guard validProviderContext(context, current) else { return }
            state.busy = false; state.deviceUnknown = true
            state.clearCredential(); state.confirmation = nil
            state.message = "Device login has no confirmed result. Automatic checks stopped. Check status explicitly to reconcile the original fixed operation; no new login is started."
        }
    }
}
