import Foundation

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
    public var id: String { clientNonce }
    public init(clientNonce: String, method: String, path: String, resourceIDs: [ID] = [], runID: ID? = nil, expectedRevision: Int? = nil, startedAtMs: TimestampMs = Date().timeIntervalSince1970 * 1000, state: String = "in_flight") {
        self.clientNonce = clientNonce; self.method = method; self.path = path; self.resourceIDs = resourceIDs; self.runID = runID; self.expectedRevision = expectedRevision; self.startedAtMs = startedAtMs; self.state = state
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
        let intent = MutationIntent(clientNonce: nonce, method: method, path: path, expectedRevision: payload["revision"]?.intValue)
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
                values[index].state = state; values[index].resourceIDs = unknown.0; values[index].runID = unknown.1
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
    func journaledMutate<T: Decodable>(_ method: String, _ path: String, body: JSONObject, as: T.Type) async throws -> T {
        let client = try activeTransport()
        var payload = body
        let handle = try beginIntent(method, path, payload: &payload)
        do {
            let value: T = try await client.mutate(method, path, body: payload, as: as)
            finishIntent(handle, unknown: unknownResources(value))
            return value
        } catch {
            if let backend = error as? BackendError, path.hasSuffix("/messages"),
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
        if parts.first == "conversations", parts.last == "messages" {
            let values: [Run] = try await allPages("/runs", query: ["clientNonce": clientNonce], as: Run.self)
            for value in values { upsert(&runs, value, id: { $0.id }, revision: { $0.revision }) }
            resolved = !values.isEmpty && values.allSatisfy { $0.status != "outcome_unknown" && $0.status != "reserved" }
            if resolved {
                let runIDs = Set(values.map(\.id))
                for id in intent.resourceIDs where !runIDs.contains(id) {
                    let entry: TranscriptEntry = try await read("/entries/\(HTTPTransport.pathID(id))")
                    guard entry.clientNonce == clientNonce, entry.conversationId == (parts[1].removingPercentEncoding ?? parts[1]) else { throw ClientError.invalidFrame }
                    upsertEntry(entry)
                }
            }
        } else if parts.first == "conversations", parts.last == "leave", parts.count == 3 {
            let id = parts[1].removingPercentEncoding ?? parts[1]
            do {
                let value: Conversation = try await read("/conversations/\(HTTPTransport.pathID(id))")
                resolved = !value.humanUserIds.contains(account.userID)
            } catch let error as BackendError where error.status == 404 {
                // Private-resource 404 also means invisible; it is not a leave receipt.
                resolved = false
            }
            if resolved { clearConversationAccess(id) }
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
            case "consents": let value: ConnectorConsent = try await read(base); resolved = settledGate(value.gate)
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
        if resolved { try persistCache(); finishIntent((account.id, clientNonce)) }
        return resolved
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
