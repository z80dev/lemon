import Foundation

private func isProviderManagementPath(_ path: String) -> Bool {
    if path == "/instance/providers" || path.hasPrefix("/instance/providers/") { return true }
    return path.hasPrefix("/machines/") && path.split(separator: "/").dropFirst(2).first == "providers"
}

/// Reconciliation metadata, never a replay queue. Request bodies, credentials, confirmation
/// tokens and draft content are deliberately absent from this account-bound file.
public struct MutationIntent: Codable, Hashable, Identifiable {
    public var clientNonce: String
    public var method: String
    public var path: String
    public var resourceIDs: [ID]
    public var runID: ID?
    public var expectedRevision: Int?
    public var startedAtMs: TimestampMs
    public var state: String
    /// Nonsecret initiating session ID; absent in older journals, which must not be replayed.
    public var providerSessionID: ID?
    public var id: String { clientNonce }
    public init(clientNonce: String, method: String, path: String, resourceIDs: [ID] = [], runID: ID? = nil, expectedRevision: Int? = nil, startedAtMs: TimestampMs = Date().timeIntervalSince1970 * 1000, state: String = "in_flight", providerSessionID: ID? = nil) {
        self.clientNonce = clientNonce; self.method = method; self.path = path; self.resourceIDs = resourceIDs; self.runID = runID; self.expectedRevision = expectedRevision; self.startedAtMs = startedAtMs; self.state = state; self.providerSessionID = providerSessionID
    }
    var messageConversationID: ID? {
        guard method == "POST", path.hasPrefix("/conversations/"), path.hasSuffix("/messages") else { return nil }
        let encoded = path.dropFirst("/conversations/".count).dropLast("/messages".count)
        guard !encoded.isEmpty, !encoded.contains("/") else { return nil }
        return String(encoded).removingPercentEncoding
    }
}

extension LemonBotStore {
    func beginIntent(_ method: String, _ path: String, payload: inout JSONObject) throws -> (String, String)? {
        guard let account else { throw ClientError.signedOut }
        if path == "/auth/reauth" || path.hasSuffix("/preview") { return nil }
        if let existing = pendingIntents.first(where: { $0.method == method && $0.path == path }) { throw ClientError.unresolvedMutation(existing) }
        let nonce: String
        if let provided = payload["clientNonce"] {
            guard let value = provided.stringValue else { throw ClientError.invalidNonce }
            nonce = value
        } else {
            nonce = UUID().uuidString
            payload["clientNonce"] = .string(nonce)
        }
        let providerTarget = isProviderManagementPath(path) ? payload["targetId"]?.stringValue.map { [$0] } ?? [] : []
        let intent = MutationIntent(clientNonce: nonce, method: method, path: path, resourceIDs: providerTarget, expectedRevision: payload["revision"]?.intValue, providerSessionID: path.contains("/providers/openai_codex/device-login") ? account.sessionID : nil)
        var values = pendingIntents; values.append(intent)
        // Persist before the first possible network side effect. Crash/restart cannot silently create a second intent.
        try persistence.saveMutationIntents(values, accountID: account.id)
        pendingIntents = values
        return (account.id, nonce)
    }
    func finishIntent(_ handle: (String, String)?, unknown: ([ID], ID?)? = nil, state: String = "outcome_unknown") {
        guard let (accountID, nonce) = handle else { return }
        do {
            var values: [MutationIntent]
            if account?.id == accountID { values = pendingIntents }
            else { values = try persistence.loadMutationIntents(accountID: accountID) }
            if let unknown, let index = values.firstIndex(where: { $0.clientNonce == nonce }) {
                values[index].state = state
                if !isProviderManagementPath(values[index].path) {
                    values[index].resourceIDs = unknown.0; values[index].runID = unknown.1
                }
            } else { values.removeAll { $0.clientNonce == nonce } }
            try persistence.saveMutationIntents(values, accountID: accountID)
            if account?.id == accountID { pendingIntents = values }
        } catch { if account?.id == accountID { errorMessage = error.localizedDescription } }
    }
    private func unknownResources(_ value: Any) -> ([ID], ID?)? {
        if let v = value as? MessageReceipt, v.status == "outcome_unknown" { return (v.runs.map(\.id) + v.entries.map(\.id), v.runs.first?.id) }
        if let v = value as? Run, v.status == "outcome_unknown" { return ([v.id], v.id) }
        if let v = value as? Draft, v.state == "outcome_unknown" { return ([v.id], v.sendRunId) }
        if let v = value as? HostOperation, v.state == "outcome_unknown" { return ([v.id], nil) }
        if let v = value as? BotResetResult, v.status == "outcome_unknown" { return ([v.bot.id], nil) }
        if let v = value as? MemoryImportResult, v.status == "outcome_unknown" { return (v.items.map(\.id), nil) }
        if let v = value as? SetupRun, v.state == "outcome_unknown" { return ([v.id], nil) }
        if let v = value as? HookReceipt, v.status == "outcome_unknown" { return ([v.routineRun.id], v.routineRun.runId) }
        if let v = value as? SecretRequest, v.gate.state == "outcome_unknown" { return ([v.id], nil) }
        return nil
    }
    func journaledMutate<T: Decodable>(_ method: String, _ path: String, body: JSONObject, as responseType: T.Type, reconcilingProviderNonce: String? = nil) async throws -> T {
        let client = try activeTransport()
        var payload = body
        let handle: (String, String)?
        if let nonce = reconcilingProviderNonce {
            // F-0077 alone defines identical fixed-intent replay as reconciliation.
            // Never extend this exception to keys, defaults or disconnect.
            guard isProviderManagementPath(path), path.contains("/providers/openai_codex/device-login"), let account,
                  let existing = pendingIntents.first(where: { $0.clientNonce == nonce }),
                  existing.path == path, existing.method == method,
                  let sessionID = account.sessionID, existing.providerSessionID == sessionID,
                  payload["clientNonce"]?.stringValue == nonce,
                  let targetID = payload["targetId"]?.stringValue, existing.resourceIDs == [targetID],
                  Set(payload.keys) == Set(["clientNonce", "targetId"]) else { throw ClientError.invalidNonce }
            handle = (account.id, nonce)
        } else { handle = try beginIntent(method, path, payload: &payload) }
        defer { if method == "POST", path.hasSuffix("/messages") { scheduleMessageReconciliation() } }
        do {
            let value: T = try await client.mutate(method, path, body: payload, as: responseType)
            if isProviderManagementPath(path) {
                do {
                    if let management = value as? ProviderManagement {
                        guard management.target.id == payload["targetId"]?.stringValue else { throw ClientError.invalidFrame }
                    }
                    if let login = value as? ProviderDeviceLogin {
                        let parts = path.split(separator: "/").map(String.init)
                        guard let index = parts.firstIndex(of: "device-login"), let nonce = payload["clientNonce"]?.stringValue,
                              let targetID = payload["targetId"]?.stringValue else { throw ClientError.invalidFrame }
                        let loginID = parts.count == index + 1 ? nonce : parts[index + 1].removingPercentEncoding ?? parts[index + 1]
                        try login.validate(loginID: loginID, targetID: targetID)
                    }
                } catch { throw ClientError.outcomeUnknown(payload["clientNonce"]?.stringValue ?? "") }
            }
            finishIntent(handle, unknown: unknownResources(value))
            return value
        } catch {
            if reconcilingProviderNonce != nil {
                // A generic rejection before dispatch says nothing about the original
                // uncertain action. Only a matching device result releases this fence.
                finishIntent(handle, unknown: ([], nil))
            } else if let backend = error as? BackendError, path.hasSuffix("/messages"),
               backend.failure.code != "outcome_unknown",
               backend.failure.details?["clientNonce"]?.stringValue == payload["clientNonce"]?.stringValue,
               let runIDs = backend.failure.details?["runIds"]?.arrayValue?.compactMap(\.stringValue), !runIDs.isEmpty,
               let entryIDs = backend.failure.details?["entryIds"]?.arrayValue?.compactMap(\.stringValue), !entryIDs.isEmpty {
                finishIntent(handle, unknown: (runIDs + entryIDs, runIDs.first), state: "recorded_refusal")
            } else if let backend = error as? BackendError, backend.failure.code == "outcome_unknown" {
                let ids = backend.failure.details?["resourceIds"]?.arrayValue?.compactMap(\.stringValue) ?? []
                finishIntent(handle, unknown: (ids, backend.failure.details?["runId"]?.stringValue))
            } else if let backend = error as? BackendError, backend.status >= 500, !backend.failure.retrySafe,
                      !["capability_unavailable", "machine_offline"].contains(backend.failure.code) {
                finishIntent(handle, unknown: (backend.failure.details?["resourceIds"]?.arrayValue?.compactMap(\.stringValue) ?? [], backend.failure.details?["runId"]?.stringValue))
            } else if let clientError = error as? ClientError, case .outcomeUnknown = clientError { finishIntent(handle, unknown: ([], nil)) }
            else { finishIntent(handle) }
            throw error
        }
    }
    func journaledUpload(fileURL: URL, filename: String?, mime: String, metadata: JSONObject) async throws -> Attachment {
        let client = try activeTransport()
        var payload = metadata
        let handle = try beginIntent("POST", "/attachments", payload: &payload)
        do {
            let value = try await client.upload(fileURL: fileURL, filename: filename, mime: mime, metadata: payload)
            finishIntent(handle); return value
        } catch {
            if let clientError = error as? ClientError, case .outcomeUnknown = clientError { finishIntent(handle, unknown: ([], nil)) }
            else if let backend = error as? BackendError, backend.failure.code == "outcome_unknown" {
                finishIntent(handle, unknown: (backend.failure.details?["resourceIds"]?.arrayValue?.compactMap(\.stringValue) ?? [], nil))
            } else { finishIntent(handle) }
            throw error
        }
    }
    /// Reads only. False means the backend has not supplied enough authoritative state to
    /// release the fence; it is never interpreted as permission to resend the old operation.
    public func reconcileMutation(_ clientNonce: String) async throws -> Bool {
        guard let intent = pendingIntents.first(where: { $0.clientNonce == clientNonce }), let account else { return false }
        let current = generation
        let parts = intent.path.split(separator: "/").map(String.init)
        var resolved = false
        var messageReceipt: MessageReceipt?
        if let conversationID = intent.messageConversationID {
            let receipt = try await self.messageReceipt(conversationID: conversationID, clientNonce: clientNonce)
            guard receipt.clientNonce == clientNonce,
                  receipt.entries.allSatisfy({ $0.clientNonce == clientNonce && $0.conversationId == conversationID }),
                  receipt.runs.allSatisfy({ $0.clientNonce == clientNonce && $0.conversationId == conversationID && $0.initiatorUserId == account.userID }) else { throw ClientError.invalidFrame }
            for entry in receipt.entries { upsertEntry(entry) }
            for run in receipt.runs { upsert(&runs, run, id: { $0.id }, revision: { $0.revision }) }
            let runIDs = Set(receipt.runs.map(\.id))
            resolved = receipt.status != "outcome_unknown" && !receipt.entries.isEmpty
                && receipt.runs.allSatisfy { !["reserved", "outcome_unknown"].contains($0.status) }
                && receipt.delivery.count == runIDs.count && Set(receipt.delivery.map(\.runId)) == runIDs
                && receipt.delivery.allSatisfy { delivery in delivery.effectiveMode != "outcome_unknown" && receipt.runs.contains { $0.id == delivery.runId && $0.botId == delivery.botId } }
            if resolved { messageReceipt = receipt }
        } else if isProviderManagementPath(intent.path), let index = parts.firstIndex(of: "providers") {
            let _: ProviderManagement = try await read("/" + parts.prefix(index + 1).joined(separator: "/"))
            // Generic status is useful for review, never an exact mutation receipt.
            // Device replay remains a separate, explicit fixed-intent action.
            resolved = false
        } else if parts.count >= 2 {
            let base = "/" + parts[0] + "/" + (try HTTPTransport.pathID(parts[1].removingPercentEncoding ?? parts[1]))
            switch parts[0] {
            case "drafts":
                let value: Draft = try await read(base)
                resolved = ["sent", "discarded"].contains(value.state) || (value.state == "editable" && value.revision > (intent.expectedRevision ?? Int.max))
            case "approvals": let value: Approval = try await read(base); resolved = settledGate(value.gate)
            case "questions": let value: Question = try await read(base); resolved = settledGate(value.gate)
            case "human-steps": let value: HumanStep = try await read(base); resolved = settledGate(value.gate)
            case "secret-requests": let value: SecretRequest = try await read(base); resolved = settledGate(value.gate)
            case "pairings":
                let value: Pairing = try await read(base)
                if parts.last == "approve" { resolved = ["approved", "consumed", "expired"].contains(value.status) }
                else if parts.last == "deny" { resolved = ["denied", "expired"].contains(value.status) }
            case "runs":
                let value: Run = try await read(base)
                if parts.last == "cancel" { resolved = ["succeeded", "failed", "cancelled"].contains(value.status) }
                else { resolved = value.status != "outcome_unknown" && value.status != "reserved" }
            default:
                if intent.method == "DELETE" {
                    do { let _: JSONObject = try await read(base) }
                    catch let error as BackendError where error.status == 404 {
                        // ACL invisibility is indistinguishable from deletion. Keep the
                        // original intent fenced without an authoritative operation receipt.
                        resolved = false
                    }
                }
            }
        }
        if !resolved, parts.count == 1, !intent.resourceIDs.isEmpty, let family = parts.first,
           ["bots", "machines", "conversations", "sections", "attachments", "skills", "routines", "host-operations"].contains(family) {
            var inspected = true
            for id in intent.resourceIDs {
                let value: JSONObject = try await read("/\(family)/\(HTTPTransport.pathID(id))")
                inspected = inspected && value["id"]?.stringValue == id && value["state"]?.stringValue != "outcome_unknown" && value["status"]?.stringValue != "outcome_unknown"
            }
            resolved = inspected
        }
        try assertGeneration(current)
        if resolved {
            try persistCache(); finishIntent((account.id, clientNonce))
            guard !pendingIntents.contains(where: { $0.clientNonce == clientNonce }) else { return false }
            if let messageReceipt { reconciledMessageReceipts[clientNonce] = messageReceipt }
        }
        return resolved
    }
    /// Only GETs the original message reservation. Neither reconnect nor foreground replays a send.
    public func reconcilePendingMessages() async {
        scheduleMessageReconciliation()
        await messageReconciliationTask?.value
    }
    func scheduleMessageReconciliation(clientNonce: String? = nil) {
        guard account != nil, connectionState != "reconnect_required",
              pendingIntents.contains(where: { $0.messageConversationID != nil && (clientNonce == nil || $0.clientNonce == clientNonce) }) else { return }
        messageReconciliationRequested = true
        guard messageReconciliationTask == nil else { return }
        let current = generation
        messageReconciliationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == current { self.messageReconciliationTask = nil } }
            repeat {
                self.messageReconciliationRequested = false
                let nonces = self.pendingIntents.filter { $0.messageConversationID != nil }.map(\.clientNonce)
                for nonce in nonces {
                    guard !Task.isCancelled, self.generation == current else { return }
                    do { _ = try await self.reconcileMutation(nonce) }
                    catch {
                        // A failed observation proves neither acceptance nor failure. Retain the original fence.
                        guard !Task.isCancelled, self.generation == current, self.connectionState != "reconnect_required" else { return }
                    }
                }
            } while self.messageReconciliationRequested
        }
    }
    private func settledGate(_ gate: Gate) -> Bool { !["pending", "submitted", "outcome_unknown"].contains(gate.state) }
    @discardableResult public func setLocalComposerRouting(conversationID: ID, references: [Reference], mentions: [ID], everyone: Bool) -> Bool {
        guard let account else { return false }
        var value = draft(for: conversationID)
        value.references = references; value.mentions = mentions; value.everyone = everyone
        drafts[conversationID] = value
        do { try persistence.saveDraft(value, conversationID: conversationID, accountID: account.id); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    public func removeDraftFile(_ url: URL, conversationID: ID) throws {
        guard let account else { throw ClientError.signedOut }
        var value = draft(for: conversationID)
        guard value.fileURLs.contains(url) else { return }
        value.fileURLs.removeAll { $0 == url }
        try persistence.saveDraft(value, conversationID: conversationID, accountID: account.id)
        drafts[conversationID] = value
        // Only the account/conversation staging directory is eligible for deletion.
        try persistence.removeStagedFile(url, conversationID: conversationID, accountID: account.id)
    }
}
