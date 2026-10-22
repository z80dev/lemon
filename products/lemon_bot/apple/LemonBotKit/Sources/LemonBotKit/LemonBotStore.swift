import Foundation
import Observation

@MainActor @Observable public final class LemonBotStore {
    public var account: StoredAccount? {
        didSet {
            if oldValue?.id != account?.id || oldValue?.token != account?.token { providerSettings.reset() }
        }
    }
    public var accounts: [StoredAccount] = []
    public var user: User?
    public var workspace: Workspace?
    public var member: Member? {
        didSet { if member?.role != "owner" { providerSettings.reset() } }
    }
    public var bots: [Bot] = []
    public var machines: [Machine] = [] {
        didSet {
            if let id = providerSettings.machineID,
               !machines.contains(where: { $0.id == id && $0.ownerUserId == account?.userID && $0.status == "online" && $0.nodeId != nil && (providerSettings.management == nil || $0.nodeId == providerSettings.management?.target.nodeId) }) {
                providerSettings.reset(machineID: id)
            }
        }
    }
    public var conversations: [Conversation] = []
    public var sections: [Section] = []
    public var notifications: [BotNotification] = []
    public var runs: [Run] = []
    public var entries: [ID: [TranscriptEntry]] = [:]
    public var drafts: [ID: LocalComposerDraft] = [:]
    public var capabilities: Capabilities?
    public var connectionState = "disconnected"
    public var errorMessage: String?
    public var connectionIssue: ConnectionIssue?
    public var instanceStatus: InstanceStatus?
    public let providerSettings = ProviderSettingsState()
    public internal(set) var nextRetryAt: Date?
    public internal(set) var lastConnectionAttemptAt: Date?
    public var selectedConversationID: ID? {
        didSet {
            guard !restoringSelection, let account else { return }
            do { try persistence.saveSelection(SavedClientSelection(conversationID: selectedConversationID, botID: conversations.first(where: { $0.id == selectedConversationID })?.botIds.first), accountID: account.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    public var deviceID: ID?
    public var terminalFrames: [ID: [TerminalOutput]] = [:]
    public var terminalGaps: [ID: TerminalGap] = [:]
    public var terminalExits: [ID: Int] = [:]
    public var terminalExitFrames: [ID: TerminalExit] = [:]
    public var voiceSession: VoiceSession?
    public var navigationTarget: DeepLinkTarget?
    public var localSettings: ClientLocalSettings?
    public internal(set) var eventVersion: Int = 0
    public internal(set) var cursor: Cursor = "0"
    public internal(set) var latestResources: [String: RealtimePayload] = [:]
    public internal(set) var pendingIntents: [MutationIntent] = []
    public internal(set) var reconciledMessageReceipts: [String: MessageReceipt] = [:]
    public internal(set) var typingByConversation: [ID: [ID: RealtimeTyping]] = [:]
    public internal(set) var pairingLink: PairingLink?
    public internal(set) var pendingPairing: PendingPairingPreview?
    public internal(set) var pairingState = "idle"
    public internal(set) var pairingError: String?
    public internal(set) var pairings: [Pairing] = []
    public internal(set) var pairingURL: String?
    public internal(set) var ownerPairingPreflight: BotPreflightResult?

    @ObservationIgnored let keychain: any AccountCredentialStore
    @ObservationIgnored let persistence: ClientPersistence
    @ObservationIgnored var transport: HTTPTransport?
    @ObservationIgnored var socket: URLSessionWebSocketTask?
    @ObservationIgnored var socketTask: Task<Void, Never>?
    @ObservationIgnored var messageReconciliationTask: Task<Void, Never>?
    @ObservationIgnored var messageReconciliationRequested = false
    @ObservationIgnored var terminalSequences: [ID: Int] = [:]
    @ObservationIgnored var terminalSubscriptions: Set<ID> = []
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var snapshot: Snapshot?
    @ObservationIgnored var foreground = true
    @ObservationIgnored var visibleConversationID: ID?
    @ObservationIgnored var lastServerActivity: UInt64 = 0
    @ObservationIgnored var pairingRecord: PendingDevicePairing?
    @ObservationIgnored var pairingQRID: ID?
    @ObservationIgnored var httpSession: URLSession?
    @ObservationIgnored var restoringSelection = false

    public init(keychain: any AccountCredentialStore = AccountKeychain(), persistence: ClientPersistence = ClientPersistence()) {
        self.keychain = keychain; self.persistence = persistence
        do {
            accounts = try keychain.load()
            if let pending = try keychain.loadPendingPairing() { installPendingPairing(pending) }
        } catch { errorMessage = error.localizedDescription }
    }
    func activeTransport() throws -> HTTPTransport {
        guard account != nil, connectionState != "reconnect_required", let transport else { throw ClientError.signedOut }
        return transport
    }
    func assertGeneration(_ value: UUID) throws { guard value == generation else { throw ClientError.accountChanged } }
    public func read<T: Decodable>(_ path: String, query: [String: String] = [:], as responseType: T.Type = T.self) async throws -> T {
        let current = generation
        let value: T
        do { value = try await activeTransport().read(path, query: query, as: responseType) }
        catch {
            if generation == current, let backend = error as? BackendError, backend.status == 401 { markReconnectRequired() }
            throw error
        }
        try assertGeneration(current)
        return value
    }
    public func mutate<T: Decodable>(_ method: String, _ path: String, body: JSONObject, as responseType: T.Type = T.self) async throws -> T {
        if (method == "DELETE" || body["confirmationToken"] != nil || path.hasSuffix("/resolve") || path.hasSuffix("/send") || path.hasSuffix("/discard") || path.hasSuffix("/reset") || path == "/host-operations" || path.hasPrefix("/pairings")), connectionState != "online" { throw ClientError.offline }
        let current = generation
        let value: T
        do { value = try await journaledMutate(method, path, body: body, as: responseType) }
        catch {
            if generation == current, let backend = error as? BackendError, backend.status == 401 { markReconnectRequired() }
            throw error
        }
        try assertGeneration(current)
        // Authoritative HTTP resources reach the same reducer as websocket upserts; no optimistic successful gates.
        if let value = value as? Bot { upsert(&bots, value, id: { $0.id }, revision: { $0.revision }) }
        if let value = value as? Machine { upsert(&machines, value, id: { $0.id }, revision: { $0.revision }) }
        if let value = value as? Conversation { upsert(&conversations, value, id: { $0.id }, revision: { $0.revision }) }
        if let value = value as? TranscriptEntry { upsertEntry(value) }
        if let value = value as? User { user = value }
        if let value = value as? Workspace { workspace = value }
        if let value = value as? VoiceSession { voiceSession = value }
        if let value = value as? BotNotification { upsert(&notifications, value, id: { $0.id }, revision: { $0.revision }) }
        eventVersion += 1
        return value
    }
    public func upload(fileURL: URL, filename: String? = nil, mime: String, metadata: JSONObject) async throws -> Attachment {
        let current = generation
        let value = try await journaledUpload(fileURL: fileURL, filename: filename, mime: mime, metadata: metadata)
        try assertGeneration(current)
        return value
    }
    public func download(attachmentID: ID) async throws -> URL {
        guard let account else { throw ClientError.signedOut }
        let current = generation
        let ticket: Download = try await read("/attachments/\(HTTPTransport.pathID(attachmentID))/download")
        let destination = persistence.downloadURL(attachmentID, filename: ticket.filename, accountID: account.id)
        let value = try await activeTransport().download(ticket, destination: destination)
        do { try assertGeneration(current) } catch { try? FileManager.default.removeItem(at: value); throw error }
        return value
    }
    public func authenticate(baseURL: URL, path: String, body: JSONObject) async throws {
        guard ["/setup", "/auth/login", "/auth/oidc/complete"].contains(path) else { throw ClientError.invalidPath }
        let client = try HTTPTransport(baseURL: baseURL)
        let auth: AuthResult = try await client.mutate("POST", path, body: body)
        let saved = try saveAuthenticatedAccount(auth, baseURL: client.baseURL, deviceID: auth.session.deviceId, installationID: nil)
        try await restoreAccount(saved)
    }
    func saveAuthenticatedAccount(_ auth: AuthResult, baseURL: URL, deviceID: ID?, installationID: String?, instanceID: String? = nil, route: MachineRoute? = nil) throws -> StoredAccount {
        let normalized = try HTTPTransport.normalizeBaseURL(baseURL)
        let id = ClientPersistence.digest(normalized.absoluteString + "|" + auth.user.id + "|" + auth.workspace.id)
        let saved = StoredAccount(id: id, baseURL: normalized, email: auth.user.email, displayName: auth.user.displayName, token: auth.token, userID: auth.user.id, workspaceID: auth.workspace.id, deviceID: deviceID, sessionID: auth.session.id, sessionExpiresAtMs: auth.session.expiresAtMs, installationID: installationID, instanceID: instanceID ?? accounts.first(where: { $0.id == id })?.instanceID, route: route)
        try keychain.save(saved)
        accounts = try keychain.load()
        try persistence.saveLastAccountID(saved.id)
        return saved
    }
    public func restoreSavedAccount() async throws {
        guard account == nil else { return }
        let preferred = try persistence.loadLastAccountID()
        guard let saved = accounts.first(where: { $0.id == preferred }) ?? accounts.first else { return }
        try await restoreAccount(saved)
    }
    public func restoreAccount(_ saved: StoredAccount) async throws {
        restoringSelection = true
        defer { restoringSelection = false }
        stopSocket()
        generation = UUID()
        clearLiveState()
        account = saved
        transport = try HTTPTransport(baseURL: saved.baseURL, token: saved.token, session: httpSession)
        deviceID = saved.deviceID
        if let installation = saved.installationID { UserDefaults.standard.set(installation, forKey: "LemonBot.installationID") }
        try persistence.saveLastAccountID(saved.id)
        pendingIntents = try persistence.loadMutationIntents(accountID: saved.id).map {
            var value = $0
            if value.state == "in_flight" { value.state = "outcome_unknown" }
            return value
        }
        if let cache = try persistence.loadCache(saved.id) {
            guard cache.snapshot.user.id == saved.userID, cache.snapshot.workspace.id == saved.workspaceID else { throw ClientError.accountChanged }
            install(cache.snapshot)
            let authorizedRooms = Set(conversations.map(\.id))
            entries = cache.entries.filter { authorizedRooms.contains($0.key) }; cursor = cache.cursor
        }
        localSettings = try persistence.loadSettings(accountID: saved.id) ?? ClientLocalSettings(summonShortcut: nil, pushToTalkShortcut: nil, micCuesEnabled: true, selectedBotId: nil, compactCompanionEnabled: false, reducedMotion: "system")
        let selection = try persistence.loadSelection(accountID: saved.id)
        if let id = selection?.conversationID, conversations.contains(where: { $0.id == id }) { selectedConversationID = id }
        else { selectedConversationID = bots.first(where: { $0.id == (selection?.botID ?? localSettings?.selectedBotId) })?.mainConversationId }
        #if os(macOS)
        // An SSH account's base URL is a local tunnel; open it (or close another account's) first.
        await SSHTunnels.shared.activate(saved.route)
        #endif
        do {
            try await refresh()
            if let id = selectedConversationID, conversations.contains(where: { $0.id == id }) { try await openConversation(id) }
            else if let bot = bots.first(where: { $0.id == (selection?.botID ?? localSettings?.selectedBotId) }) { try await openConversation(bot.mainConversationId) }
        } catch {
            if let backend = error as? BackendError, backend.status == 401 || backend.status == 403 { markReconnectRequired() }
            throw error
        }
    }
    public func signOut() async throws {
        providerSettings.clearCredential(); providerSettings.cancelConfirmation()
        guard let signedOut = account else { return }
        var failure: Error?
        do { let _: Empty = try await activeTransport().mutate("POST", "/auth/logout", body: [:]) }
        catch let error as BackendError where error.status == 401 { /* The current session is already authoritatively revoked. */ }
        catch { failure = error }
        if account?.id == signedOut.id {
            stopSocket(); generation = UUID(); clearLiveState(); account = nil; transport = nil
            #if os(macOS)
            SSHTunnels.shared.close()
            #endif
        }
        do { try keychain.remove(signedOut.id) } catch { failure = failure ?? error }
        do { try persistence.clear(accountID: signedOut.id) } catch { failure = failure ?? error }
        do { accounts = try keychain.load() } catch { failure = failure ?? error }
        do { if try persistence.loadLastAccountID() == signedOut.id { try persistence.saveLastAccountID(nil) } } catch { failure = failure ?? error }
        if let failure { throw failure }
    }
    public func registerDevice(platform: String, name: String, push: JSONObject? = nil) async throws {
        let installation = Self.installationID()
        var body: JSONObject = ["installationId": .string(installation), "platform": .string(platform), "name": .string(name), "appVersion": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")]
        if let push { body["push"] = .object(push) }
        let device: Device = try await mutate("POST", "/devices", body: body)
        deviceID = device.id
        if var saved = account {
            saved.deviceID = device.id; saved.installationID = installation
            try keychain.save(saved); accounts = try keychain.load(); account = saved
        }
        startSocket()
    }
    public func saveLocalSettings(_ settings: ClientLocalSettings) throws {
        guard let account else { throw ClientError.signedOut }
        try persistence.saveSettings(settings, accountID: account.id)
        localSettings = settings
    }
    public func refresh() async throws {
        guard connectionState != "reconnect_required" else { throw ClientError.signedOut }
        let current = generation
        stopSocket(); connectionState = "syncing"; lastConnectionAttemptAt = Date(); nextRetryAt = nil
        do { try await synchronize(); try assertGeneration(current); startSocket(identityVerified: true) }
        catch {
            guard generation == current else { throw error }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if connectionState != "reconnect_required" { connectionState = "disconnected" }
            recordConnectionFailure(error)
            if connectionState != "reconnect_required" { startSocket() }
            throw error
        }
    }
    func markReconnectRequired(_ error: Error = ClientError.signedOut) {
        stopSocket(); generation = UUID(); transport = nil
        providerSettings.reset()
        connectionState = "reconnect_required"
        nextRetryAt = nil
        recordConnectionFailure(error)
    }
    /// Read-only identity fence before sync or socket authentication. Never replace an existing pin.
    func verifyConnectionIdentity() async throws {
        guard let saved = account else { throw ClientError.signedOut }
        #if !os(iOS)
        // Existing Mac sign-in is outside phone pairing; verified/paired accounts still enforce their pin.
        guard saved.instanceID != nil else { return }
        #endif
        let current = generation
        // UI/platform tasks can run while public preflight awaits. They must not use
        // a saved session against an unverified endpoint, even for an unrelated request.
        transport = nil
        do {
            let client = BotPreflightClient(session: httpSession)
            let origin = try PairingLink.exactOrigin(saved.baseURL)
            let expected: String
            if let pinned = saved.instanceID { expected = pinned }
            else {
                // Upgrade an old iOS account only against its own authenticated workspace.
                let baseline = try await client.identity(origin: origin, token: saved.token, use: Self.phoneOriginUse)
                try assertGeneration(current)
                try BotPreflight.validateIdentity(baseline, expectedInstanceID: baseline.instanceId, workspaceID: saved.workspaceID, use: Self.phoneOriginUse)
                expected = baseline.instanceId
            }
            _ = try await client.preflight(origin: origin, expectedInstanceID: expected, session: BotPreflightSession(token: saved.token, workspaceID: saved.workspaceID), use: Self.phoneOriginUse)
            try Task.checkCancellation()
            try assertGeneration(current)
            if saved.instanceID == nil {
                var pinned = saved; pinned.instanceID = expected
                try keychain.save(pinned); accounts = try keychain.load(); account = pinned
            }
            transport = try HTTPTransport(baseURL: saved.baseURL, token: saved.token, session: httpSession)
        } catch {
            guard generation == current else { throw error }
            if let preflight = error as? BotPreflightError, preflight != .unavailable { markReconnectRequired(error) }
            else if let backend = error as? BackendError, backend.status == 401 || backend.status == 403 { markReconnectRequired(error) }
            throw error
        }
    }
    func synchronize(identityVerified: Bool = false) async throws {
        let current = generation
        if !identityVerified { try await verifyConnectionIdentity() }
        try assertGeneration(current)
        let value: Snapshot = try await read("/sync")
        guard value.user.id == account?.userID, value.workspace.id == account?.workspaceID else {
            markReconnectRequired(ClientError.accountChanged)
            throw ClientError.accountChanged
        }
        install(value); cursor = try WorkspaceCursor.normalized(value.cursor)
        if value.hasMore.bots { bots = try await allPages("/bots", as: Bot.self) }
        if value.hasMore.machines { machines = try await allPages("/machines", as: Machine.self) }
        if value.hasMore.conversations { conversations = try await allPages("/conversations", as: Conversation.self) }
        if value.hasMore.notifications { notifications = try await allPages("/notifications", as: BotNotification.self) }
        for id in Array(entries.keys) {
            guard conversations.contains(where: { $0.id == id }) else { entries[id] = nil; continue }
            let page: Page<TranscriptEntry> = try await read("/conversations/\(HTTPTransport.pathID(id))/entries", query: ["limit": "200"])
            entries[id] = page.items
        }
        try assertGeneration(current); try persistCache()
        if capabilities?.controlConnected == false {
            if canViewInstance {
                do { _ = try await refreshInstance() }
                catch { try assertGeneration(current) }
            }
            updateControllerIssue()
        } else { connectionIssue = nil }
    }
    public func allPages<T: Codable & Hashable>(_ path: String, query: [String: String] = [:], as: T.Type = T.self) async throws -> [T] {
        var result: [T] = [], next: String?, seen: Set<String> = [], indices: [ID: Int] = [:]
        repeat {
            var q = query; q["limit"] = "200"; if let next { q["cursor"] = next }
            let page: Page<T> = try await read(path, query: q)
            for value in page.items {
                let key: ID?
                if let file = value as? FileInfo { key = file.path }
                else if let status = value as? SpendStatus { key = status.limit.id }
                else if let application = value as? PolicyApplication { key = application.machineId }
                else if let identified = value as? any Identifiable { key = identified.id as? ID }
                else { key = nil }
                if let key, let index = indices[key] { result[index] = value }
                else {
                    if let key { indices[key] = result.count }
                    result.append(value)
                }
            }
            next = page.nextCursor
            if let next, !seen.insert(next).inserted { throw ClientError.invalidCursor }
        } while next != nil
        return result
    }
    private func install(_ value: Snapshot) {
        snapshot = value; user = value.user; workspace = value.workspace; member = value.member; capabilities = value.capabilities
        // Legacy caches may contain previously visible live Team resources. They confer
        // no current owner authority and must not reappear when restoring offline.
        let foreignBots = Set(value.bots.lazy.filter { $0.ownerUserId != value.user.id }.map(\.id))
        bots = value.bots.filter { $0.ownerUserId == value.user.id }; machines = value.machines
        conversations = value.conversations.filter { $0.ownerUserId == value.user.id && !$0.botIds.contains(where: { foreignBots.contains($0) }) }
        sections = value.sections
        notifications = value.notifications.filter { $0.userId == value.user.id && !($0.botId.map { foreignBots.contains($0) } ?? false) }
        runs = value.activeRuns.filter { $0.initiatorUserId == value.user.id && !foreignBots.contains($0.botId) }
    }
    private func clearLiveState() {
        providerSettings.reset()
        connectionState = "disconnected"
        connectionIssue = nil; instanceStatus = nil; nextRetryAt = nil; lastConnectionAttemptAt = nil
        user = nil; workspace = nil; member = nil; capabilities = nil; bots = []; machines = []; conversations = []; sections = []; notifications = []; runs = []
        entries = [:]; drafts = [:]; terminalFrames = [:]; terminalGaps = [:]; terminalExits = [:]; terminalExitFrames = [:]; terminalSequences = [:]; terminalSubscriptions = []
        voiceSession = nil; navigationTarget = nil; localSettings = nil; selectedConversationID = nil; deviceID = nil; snapshot = nil; cursor = "0"; latestResources = [:]; errorMessage = nil
        visibleConversationID = nil
        pendingIntents = []
        messageReconciliationTask?.cancel(); messageReconciliationTask = nil; messageReconciliationRequested = false
        reconciledMessageReceipts = [:]
        pairings = []; pairingURL = nil; pairingQRID = nil
        ownerPairingPreflight = nil
        typingByConversation = [:]
    }
    func persistCache() throws {
        guard let account, var value = snapshot else { return }
        if let user { value.user = user }; if let workspace { value.workspace = workspace }; if let member { value.member = member }; if let capabilities { value.capabilities = capabilities }
        value.bots = bots; value.machines = machines; value.conversations = conversations; value.sections = sections; value.notifications = notifications; value.activeRuns = runs; value.cursor = cursor
        try persistence.saveCache(AccountCache(accountID: account.id, snapshot: value, entries: entries, cursor: cursor))
    }
    /// Loads a conversation. `select: false` is for views that are already showing it: a slow load
    /// must not pull the selection back after the user has moved to another conversation.
    public func openConversation(_ id: ID, select: Bool = true) async throws {
        let value: Conversation = try await read("/conversations/\(HTTPTransport.pathID(id))")
        let page: Page<TranscriptEntry> = try await read("/conversations/\(HTTPTransport.pathID(id))/entries", query: ["limit": "200"])
        upsert(&conversations, value, id: { $0.id }, revision: { $0.revision }); entries[id] = page.items
        if let account, drafts[id] == nil { drafts[id] = try persistence.loadDraft(conversationID: id, accountID: account.id) }
        let server: ComposerDraft = try await read("/conversations/\(HTTPTransport.pathID(id))/composer")
        if drafts[id] == nil { drafts[id] = LocalComposerDraft(text: server.text, attachmentIDs: server.attachmentIds, replyToEntryID: server.replyToEntryId, revision: server.revision) }
        else if let local = drafts[id], local.text == server.text, local.attachmentIDs == server.attachmentIds, local.replyToEntryID == server.replyToEntryId {
            drafts[id]?.revision = server.revision
        }
        if select { selectedConversationID = id }
        try persistCache()
    }
    public func loadOlderEntries(conversationID: ID, cursor: Cursor? = nil) async throws -> Cursor? {
        var query = ["limit": "200"]
        if let cursor { query["cursor"] = cursor }
        else if let first = entries[conversationID]?.first { query["beforeSeq"] = String(first.seq) }
        let page: Page<TranscriptEntry> = try await read("/conversations/\(HTTPTransport.pathID(conversationID))/entries", query: query)
        for entry in page.items { upsertEntry(entry) }; try persistCache(); return page.nextCursor
    }
    public func send(conversationID: ID, text: String, attachmentIDs: [ID], replyTo: ID? = nil, mode: String = "followup", mentions: [ID] = [], everyone: Bool = false, references: [Reference] = [], voiceSessionID: ID? = nil, clientNonce: String = UUID().uuidString) async throws -> MessageReceipt {
        let nonce = clientNonce, current = generation
        var body: JSONObject = ["clientNonce": .string(nonce), "text": .string(text), "attachmentIds": .array(attachmentIDs.map(JSONValue.string)), "mode": .string(mode), "mentions": .array(mentions.map(JSONValue.string)), "everyone": .bool(everyone), "references": try JSONValue.encoding(references)]
        if let replyTo { body["replyToEntryId"] = .string(replyTo) }; if let voiceSessionID { body["voiceSessionId"] = .string(voiceSessionID) }
        var receipt: MessageReceipt
        do { receipt = try await mutate("POST", "/conversations/\(HTTPTransport.pathID(conversationID))/messages", body: body) }
        catch {
            guard pendingIntents.contains(where: { $0.clientNonce == nonce }) || reconciledMessageReceipts[nonce] != nil else { throw error }
            await reconcilePendingMessages()
            try assertGeneration(current)
            guard let recorded = reconciledMessageReceipts[nonce] else { throw error }
            receipt = recorded
        }
        if receipt.status == "outcome_unknown" {
            await reconcilePendingMessages()
            try assertGeneration(current)
            if let recorded = reconciledMessageReceipts[nonce] { receipt = recorded }
        }
        for entry in receipt.entries { upsertEntry(entry) }; for run in receipt.runs { upsert(&runs, run, id: { $0.id }, revision: { $0.revision }) }
        do { try persistCache() } catch { errorMessage = error.localizedDescription }
        return receipt
    }
    /// Read the original actor/conversation/nonce reservation without submitting another message.
    public func messageReceipt(conversationID: ID, clientNonce: String) async throws -> MessageReceipt {
        try await read("/conversations/\(HTTPTransport.pathID(conversationID))/messages/receipts/\(HTTPTransport.pathID(clientNonce))")
    }
    public func draft(for id: ID) -> LocalComposerDraft { drafts[id] ?? LocalComposerDraft() }
    @discardableResult public func setLocalDraft(conversationID: ID, text: String, attachmentIDs: [ID], replyTo: ID? = nil) -> Bool {
        var draft = draft(for: conversationID); draft.text = text; draft.attachmentIDs = attachmentIDs; draft.replyToEntryID = replyTo; drafts[conversationID] = draft
        guard let account else { return false }
        do { try persistence.saveDraft(draft, conversationID: conversationID, accountID: account.id); return true }
        catch { errorMessage = error.localizedDescription; return false }
    }
    public func stageDraftFile(_ url: URL, conversationID: ID) throws -> URL {
        guard let account else { throw ClientError.signedOut }
        let retained = try persistence.stageFile(url, conversationID: conversationID, accountID: account.id)
        var draft = draft(for: conversationID); draft.fileURLs.append(retained); drafts[conversationID] = draft
        try persistence.saveDraft(draft, conversationID: conversationID, accountID: account.id); return retained
    }
    public func saveDraft(conversationID: ID, text: String, attachmentIDs: [ID], replyTo: ID? = nil) async throws {
        guard setLocalDraft(conversationID: conversationID, text: text, attachmentIDs: attachmentIDs, replyTo: replyTo) else {
            throw NSError(domain: "LemonBotDraft", code: 1, userInfo: [NSLocalizedDescriptionKey: errorMessage ?? "Sign in before saving a draft."])
        }
        let current = draft(for: conversationID)
        let value: ComposerDraft = try await mutate("PUT", "/conversations/\(HTTPTransport.pathID(conversationID))/composer", body: ["revision": .number(Double(current.revision)), "text": .string(text), "attachmentIds": .array(attachmentIDs.map(JSONValue.string)), "replyToEntryId": replyTo.map(JSONValue.string) ?? .null])
        drafts[conversationID]?.revision = value.revision
        if let account, let retained = drafts[conversationID] { try persistence.saveDraft(retained, conversationID: conversationID, accountID: account.id) }
    }
    public func acknowledgeNotification(_ id: ID) async throws {
        let values: [BotNotification] = try await allPages("/notifications", as: BotNotification.self)
        guard let notification = values.first(where: { $0.id == id }) else { throw ClientError.invalidDeepLink }
        let _: BotNotification = try await mutate("PATCH", "/notifications/\(HTTPTransport.pathID(id))", body: ["revision": .number(Double(notification.revision)), "read": .bool(true)])
    }
    func upsert<T>(_ collection: inout [T], _ value: T, id: (T) -> ID, revision: (T) -> Int) {
        if let index = collection.firstIndex(where: { id($0) == id(value) }) { if revision(value) >= revision(collection[index]) { collection[index] = value } }
        else { collection.append(value) }
    }
    func upsertEntry(_ value: TranscriptEntry) {
        var list = entries[value.conversationId] ?? []
        upsert(&list, value, id: { $0.id }, revision: { $0.revision }); list.sort { $0.seq < $1.seq }; entries[value.conversationId] = list
    }
}
