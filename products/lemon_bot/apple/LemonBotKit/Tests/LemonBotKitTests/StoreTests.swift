import XCTest
import Foundation
@testable import LemonBotKit

private final class TestAccountCredentialStore: AccountCredentialStore {
    private var accounts: [StoredAccount]
    var loadError: Error?
    var removeError: Error?
    var pendingPairing: PendingDevicePairing?

    init(accounts: [StoredAccount] = []) { self.accounts = accounts }

    func load() throws -> [StoredAccount] {
        if let loadError { throw loadError }
        return accounts
    }

    func save(_ account: StoredAccount) throws {
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
    }

    func remove(_ id: String) throws {
        if let removeError { throw removeError }
        accounts.removeAll { $0.id == id }
    }
    func loadPendingPairing() throws -> PendingDevicePairing? { pendingPairing }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws { pendingPairing = pairing }
    func removePendingPairing() throws { pendingPairing = nil }
}

@MainActor final class StoreTests: XCTestCase {
    private var roots: [URL] = []
    private func persistence() -> ClientPersistence {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        roots.append(root); return ClientPersistence(root: root)
    }
    private func saved(_ id: String = "account") -> StoredAccount {
        StoredAccount(id: id, baseURL: URL(string: "https://product.example/v1")!, email: "member@example.org", displayName: "Member", token: "session", userID: "resource", workspaceID: "resource")
    }
    private func store(_ persistence: ClientPersistence? = nil, credentials: TestAccountCredentialStore? = nil) throws -> LemonBotStore {
        let store = LemonBotStore(keychain: credentials ?? TestAccountCredentialStore(accounts: [saved()]), persistence: persistence ?? self.persistence())
        store.account = saved(); store.transport = try HTTPTransport(baseURL: saved().baseURL, token: "session", session: TestHTTPProtocol.session())
        addTeardownBlock { TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
        TestHTTPProtocol.requests = []; return store
    }
    private func message(_ text: String, revision: Int = 1) throws -> TranscriptEntry {
        var fixtures = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.entries)
        fixtures[0]["text"] = .string(text); fixtures[0]["runId"] = .string("run"); fixtures[0]["streaming"] = .bool(true); fixtures[0]["revision"] = .number(Double(revision))
        return try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(fixtures[0]))
    }
    func testDraftsAndFilesAreDurableAndAccountBound() throws {
        let persistence = persistence()
        let local = LocalComposerDraft(text: "Unsent", attachmentIDs: ["a"], replyToEntryID: "e", revision: 3)
        try persistence.saveDraft(local, conversationID: "chat", accountID: "a")
        XCTAssertEqual(try persistence.loadDraft(conversationID: "chat", accountID: "a"), local)
        XCTAssertNil(try persistence.loadDraft(conversationID: "chat", accountID: "b"))
        let source = roots[0].appendingPathComponent("selected.bin")
        try Data([0, 1, 2, 3]).write(to: source)
        let staged = try persistence.stageFile(source, conversationID: "chat", accountID: "a")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: staged), Data([0, 1, 2, 3]))
        try persistence.saveDraft(local, conversationID: "chat", accountID: "b")
        try persistence.clear(accountID: "a")
        XCTAssertNil(try persistence.loadDraft(conversationID: "chat", accountID: "a"))
        XCTAssertEqual(try persistence.loadDraft(conversationID: "chat", accountID: "b"), local)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
    func testLocalDraftRetentionReportsFilesystemFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root); try Data("not a directory".utf8).write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try store(ClientPersistence(root: root))
        XCTAssertFalse(store.setLocalDraft(conversationID: "chat", text: "Keep visible", attachmentIDs: []))
        XCTAssertEqual(store.draft(for: "chat").text, "Keep visible")
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 0)
    }
    func testOffsetCheckedDeltasUseUTF16AndFinalUpsertIsAuthoritative() async throws {
        let store = try store()
        store.upsertEntry(try message("🍋"))
        try await store.apply(RealtimeEvent(seq: "1", payload: .entryDelta(RealtimeEntryDelta(conversationId: "resource", entryId: "resource", runId: "run", offset: 2, text: " ready")), timestampMs: 1))
        XCTAssertEqual(store.entries["resource"]?.first?.text, "🍋 ready")
        XCTAssertEqual(TestHTTPProtocol.requests.count, 0)
        var final = try message("Full durable result", revision: 2)
        if case .message(var body) = final { body.streaming = false; final = .message(body) }
        try await store.apply(RealtimeEvent(seq: "2", payload: .entryUpserted(final), timestampMs: 1))
        XCTAssertEqual(store.entries["resource"]?.first?.text, "Full durable result")
        XCTAssertEqual(store.entries["resource"]?.first?.streaming, false)
        store.upsertEntry(try message("Stale preview", revision: 1))
        XCTAssertEqual(store.entries["resource"]?.first?.text, "Full durable result")
    }
    func testMissingOffsetRefetchesInsteadOfConcatenating() async throws {
        let store = try store()
        store.upsertEntry(try message("Partial"))
        let authoritative = try message("Recovered durable text", revision: 2)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/v1/entries/resource")
            return (200, [:], try JSONEncoder().encode(authoritative))
        }
        try await store.apply(RealtimeEvent(seq: "1", payload: .entryDelta(RealtimeEntryDelta(conversationId: "resource", entryId: "resource", runId: "run", offset: 900, text: "must not append")), timestampMs: 1))
        XCTAssertEqual(store.entries["resource"]?.first?.text, "Recovered durable text")
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    func testCursorAndProcessedStatePersistTogetherWithoutRegressing() throws {
        let persistence = persistence(), store = try store(persistence)
        store.snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        store.cursor = "9007199254740993123456"
        store.upsertEntry(try message("Persisted text"))
        try store.commitCursor("9007199254740993123457")
        let cache = try XCTUnwrap(persistence.loadCache("account"))
        XCTAssertEqual(cache.cursor, "9007199254740993123457")
        XCTAssertEqual(cache.entries["resource"]?.first?.text, "Persisted text")
        try store.commitCursor("1")
        XCTAssertEqual(store.cursor, "9007199254740993123457")
    }
    func testFailedCursorPersistenceDoesNotAdvanceResumePoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root); try Data("file".utf8).write(to: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try store(ClientPersistence(root: root))
        store.snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        store.cursor = "10"
        XCTAssertThrowsError(try store.commitCursor("11"))
        XCTAssertEqual(store.cursor, "10")
    }
    func testCursorExpiryReconciliationRetainsLocalDraftAndNeverReplaysIt() async throws {
        let store = try store()
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "Retained, never automatically sent", attachmentIDs: []))
        store.entries["revokedConversation"] = [try message("No longer authorized")]
        store.entries["resource"] = [try message("Stale cached preview")]
        let authoritativeEntry = try message("Authorized durable result", revision: 2)
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        let bot = try XCTUnwrap(events.compactMap { event -> Bot? in
            if case .botUpserted(let value) = event.payload { return value }
            return nil
        }.first)
        let machine = try XCTUnwrap(events.compactMap { event -> Machine? in
            if case .machineUpserted(let value) = event.payload { return value }
            return nil
        }.first)
        let conversation = try XCTUnwrap(events.compactMap { event -> Conversation? in
            if case .conversationUpserted(let value) = event.payload { return value }
            return nil
        }.first)
        let notification = try XCTUnwrap(events.compactMap { event -> BotNotification? in
            if case .notificationUpserted(let value) = event.payload { return value }
            return nil
        }.first)
        func pages<T: Codable & Hashable>(_ items: [T]) throws -> (first: Data, final: Data) {
            let encoder = JSONEncoder()
            return (
                try encoder.encode(Page<T>(items: [], nextCursor: "authorized-next")),
                try encoder.encode(Page(items: items))
            )
        }
        let authorizedPages = [
            "/v1/bots": try pages([bot]),
            "/v1/machines": try pages([machine]),
            "/v1/conversations": try pages([conversation]),
            "/v1/notifications": try pages([notification])
        ]
        let entries = try JSONEncoder().encode(Page(items: [authoritativeEntry]))
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/v1/sync" { return (200, [:], WireFixtures.snapshot) }
            if request.url?.path == "/v1/conversations/resource/entries" { return (200, [:], entries) }
            let path = try XCTUnwrap(request.url?.path)
            let page = try XCTUnwrap(authorizedPages[path], "Only authorized snapshot collections may be requested")
            let cursor = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first(where: { $0.name == "cursor" })?.value
            if let cursor {
                XCTAssertEqual(cursor, "authorized-next")
                return (200, [:], page.final)
            }
            return (200, [:], page.first)
        }
        try await store.recoverExpiredCursor()
        XCTAssertEqual(store.draft(for: "chat").text, "Retained, never automatically sent")
        XCTAssertNil(store.entries["revokedConversation"])
        XCTAssertEqual(store.entries["resource"], [authoritativeEntry])
        XCTAssertEqual(store.bots, [bot])
        XCTAssertEqual(store.machines, [machine])
        XCTAssertEqual(store.conversations, [conversation])
        XCTAssertEqual(store.notifications, [notification])
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(store.cursor, "9007199254740993123456")
    }
    func testOfflineConsequentialActionsAreNeverDispatched() async throws {
        let store = try store(); store.connectionState = "disconnected"
        for (method, path) in [("DELETE", "/bots/b"), ("POST", "/approvals/a/resolve"), ("POST", "/drafts/d/send"), ("POST", "/bots/b/reset")] {
            do { let _: Empty = try await store.mutate(method, path, body: ["revision": .number(1), "confirmationToken": .string("token")]); XCTFail("Offline action should not be dispatched") }
            catch ClientError.offline {}
        }
        XCTAssertEqual(TestHTTPProtocol.requests.count, 0)
    }
    func testTerminalDuplicatesAndExitRemainSeparateFromWorkspaceCursor() async throws {
        let store = try store(); store.terminalSubscriptions.insert("terminal"); store.cursor = "50"
        let unusedSocket = TestHTTPProtocol.session().webSocketTask(with: URL(string: "wss://product.example/v1/realtime")!)
        let output = TerminalOutput(terminalId: "terminal", seq: 1, dataBase64: Data("\u{1b}[31mred".utf8).base64EncodedString())
        try await store.process(.terminalOutput(output), on: unusedSocket)
        try await store.process(.terminalOutput(output), on: unusedSocket)
        XCTAssertEqual(store.terminalFrames["terminal"]?.count, 1)
        XCTAssertEqual(store.cursor, "50")
        try await store.process(.terminalGap(TerminalGap(terminalId: "terminal", earliestSeq: 5, latestSeq: 10)), on: unusedSocket)
        XCTAssertEqual(store.terminalSequences["terminal"], 4)
        try await store.process(.terminalExit(TerminalExit(terminalId: "terminal", code: nil)), on: unusedSocket)
        XCTAssertNil(store.terminalExits["terminal"])
        XCTAssertNotNil(store.terminalExitFrames["terminal"])
        XCTAssertFalse(store.terminalSubscriptions.contains("terminal"))
    }
    func testSignoutClearsOnlyRevokedAccountEvenWhenLogoutIsAlready401() async throws {
        let persistence = persistence()
        let credentials = TestAccountCredentialStore(accounts: [saved(), saved("other")])
        let store = try store(persistence, credentials: credentials)
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "private draft", attachmentIDs: []))
        try persistence.saveDraft(LocalComposerDraft(text: "other account"), conversationID: "chat", accountID: "other")
        store.entries["chat"] = [try message("private transcript")]; store.cursor = "99"
        TestHTTPProtocol.handler = { _ in (401, [:], Data(#"{"error":{"code":"unauthenticated","message":"Session revoked","requestId":"req_logout","retrySafe":true}}"#.utf8)) }
        try await store.signOut()
        XCTAssertNil(store.account); XCTAssertTrue(store.entries.isEmpty); XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.cursor, "0"); XCTAssertEqual(store.connectionState, "disconnected")
        XCTAssertNil(try persistence.loadDraft(conversationID: "chat", accountID: "account"))
        XCTAssertEqual(try persistence.loadDraft(conversationID: "chat", accountID: "other")?.text, "other account")
        XCTAssertEqual(try credentials.load().map(\.id), ["other"])
        XCTAssertEqual(store.accounts.map(\.id), ["other"])
    }

    func testCredentialLoadFailureDoesNotActivateOrInventSavedAccounts() {
        let credentials = TestAccountCredentialStore(accounts: [saved()])
        credentials.loadError = ClientError.keychain(-50)
        let store = LemonBotStore(keychain: credentials, persistence: persistence())
        XCTAssertNil(store.account)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(store.errorMessage, ClientError.keychain(-50).localizedDescription)
    }

    func testSignoutReportsCredentialRemovalFailureWhileClearingRevokedLiveState() async throws {
        let persistence = persistence()
        let credentials = TestAccountCredentialStore(accounts: [saved(), saved("other")])
        credentials.removeError = ClientError.keychain(-50)
        let store = try store(persistence, credentials: credentials)
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "private draft", attachmentIDs: []))
        store.entries["chat"] = [try message("private transcript")]
        TestHTTPProtocol.handler = { _ in (401, [:], Data(#"{"error":{"code":"unauthenticated","message":"Session revoked","requestId":"req_logout","retrySafe":true}}"#.utf8)) }
        do {
            try await store.signOut()
            XCTFail("Credential deletion errors must remain observable")
        } catch ClientError.keychain(let status) {
            XCTAssertEqual(status, -50)
        }
        XCTAssertNil(store.account)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertNil(try persistence.loadDraft(conversationID: "chat", accountID: "account"))
        XCTAssertEqual(Set(try credentials.load().map(\.id)), ["account", "other"])
    }
    func testUnknownMutationNoncePersistsWithoutBodyAndFencesRestart() async throws {
        let persistence = persistence(), first = try store(persistence)
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            let _: MessageReceipt = try await first.mutate("POST", "/conversations/chat/messages", body: ["clientNonce": .string("fixed_intent_123456"), "text": .string("must_not_persist"), "password": .string("never_store_credentials")])
            XCTFail("Expected uncertain outcome")
        } catch ClientError.outcomeUnknown(let nonce) { XCTAssertEqual(nonce, "fixed_intent_123456") }
        await first.reconcilePendingMessages()
        let intents = try persistence.loadMutationIntents(accountID: "account")
        XCTAssertEqual(intents.first?.clientNonce, "fixed_intent_123456")
        XCTAssertEqual(intents.first?.state, "outcome_unknown")
        let journal = String(decoding: try JSONEncoder().encode(intents), as: UTF8.self)
        XCTAssertFalse(journal.contains("must_not_persist")); XCTAssertFalse(journal.contains("never_store_credentials"))
        XCTAssertEqual(try persistence.loadMutationIntents(accountID: "other"), [])
        let restarted = try store(persistence)
        restarted.pendingIntents = intents
        do {
            let _: MessageReceipt = try await restarted.mutate("POST", "/conversations/chat/messages", body: ["text": .string("new intent")])
            XCTFail("Must reconcile the old intent first")
        } catch ClientError.unresolvedMutation(let existing) { XCTAssertEqual(existing.clientNonce, "fixed_intent_123456") }
        XCTAssertEqual(TestHTTPProtocol.requests.count, 0)
    }
    func testSuccessfulUnknownReceiptIsRetainedAndReconciliationReadsOnly() async throws {
        let persistence = persistence(), store = try store(persistence)
        var resource = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events).first { $0["event"]?.stringValue == "run.upserted" }!["payload"]!.objectValue!
        resource["clientNonce"] = .string("fixed_message_123456"); resource["status"] = .string("outcome_unknown")
        resource["conversationId"] = .string("chat")
        let run = try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(resource))
        var authored = try message("Hello")
        if case .message(var value) = authored { value.clientNonce = "fixed_message_123456"; value.conversationId = "chat"; authored = .message(value) }
        let receipt = MessageReceipt(entries: [authored], runs: [run], clientNonce: "fixed_message_123456", status: "outcome_unknown", delivery: [MessageReceiptDelivery(botId: run.botId, requestedMode: "followup", effectiveMode: "outcome_unknown", runId: run.id)])
        var settled = false
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" { return (202, [:], try JSONEncoder().encode(receipt)) }
            XCTAssertEqual(request.url?.path, "/v1/conversations/chat/messages/receipts/fixed_message_123456")
            var reconciled = receipt
            if settled { reconciled.status = "queued"; reconciled.runs[0].status = "queued"; reconciled.delivery[0].effectiveMode = "queued" }
            return (200, [:], try JSONEncoder().encode(reconciled))
        }
        let accepted: MessageReceipt = try await store.mutate("POST", "/conversations/chat/messages", body: ["clientNonce": .string("fixed_message_123456"), "text": .string("Hello")])
        XCTAssertEqual(accepted.status, "outcome_unknown")
        XCTAssertEqual(store.pendingIntents.first?.runID, run.id)
        settled = true
        await store.reconcilePendingMessages()
        XCTAssertEqual(store.reconciledMessageReceipts["fixed_message_123456"]?.status, "queued")
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertTrue(try persistence.loadMutationIntents(accountID: "account").isEmpty)
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(TestHTTPProtocol.requests.dropFirst().allSatisfy { $0.httpMethod == "GET" })
    }
    func testComposerRoutingPersistsWithoutSending() throws {
        let persistence = persistence(), store = try store(persistence)
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "Review this", attachmentIDs: ["a"]))
        XCTAssertTrue(store.setLocalComposerRouting(conversationID: "chat", references: [Reference(kind: "skill", id: "s")], mentions: ["bot"], everyone: true))
        let retained = try XCTUnwrap(persistence.loadDraft(conversationID: "chat", accountID: "account"))
        XCTAssertEqual(retained.text, "Review this"); XCTAssertEqual(retained.references, [Reference(kind: "skill", id: "s")])
        XCTAssertEqual(retained.mentions, ["bot"]); XCTAssertTrue(retained.everyone)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 0)
    }
    func testRemovingDraftFileNeverDeletesExternalOriginal() throws {
        let store = try store()
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "Unsent", attachmentIDs: []))
        let original = roots[0].appendingPathComponent("original.txt")
        try Data("selected content".utf8).write(to: original)
        let retained = try store.stageDraftFile(original, conversationID: "chat")
        try store.removeDraftFile(retained, conversationID: "chat")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        var draft = store.draft(for: "chat"); draft.fileURLs = [original]; store.drafts["chat"] = draft
        try store.removeDraftFile(original, conversationID: "chat")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(store.draft(for: "chat").fileURLs.isEmpty)
    }
    func testTypingExpiresWithoutBecomingDurableWorkspaceState() async throws {
        let store = try store()
        let unused = TestHTTPProtocol.session().webSocketTask(with: URL(string: "wss://product.example/v1/realtime")!)
        let active = RealtimeTyping(conversationId: "chat", userId: "member", active: true, expiresAtMs: Date().timeIntervalSince1970 * 1000 + 5000)
        try await store.process(.typing(active), on: unused)
        XCTAssertEqual(store.typingUsers(in: "chat").map(\.userId), ["member"])
        var expired = active; expired.expiresAtMs = 0
        try await store.process(.typing(expired), on: unused)
        XCTAssertTrue(store.typingUsers(in: "chat").isEmpty)
        XCTAssertEqual(store.cursor, "0")
    }
    func testOwnGroupDeletionRemovesOnlyOwnCachedRoomAndStaging() async throws {
        let persistence = persistence(), store = try store(persistence)
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "Unsent group draft", attachmentIDs: []))
        let source = try XCTUnwrap(roots.last).appendingPathComponent("selected-original.bin")
        try Data([1, 2, 3]).write(to: source)
        let staged = try store.stageDraftFile(source, conversationID: "chat")
        try persistence.saveDraft(LocalComposerDraft(text: "Other account"), conversationID: "chat", accountID: "other")
        var payload = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events).first { $0["event"]?.stringValue == "conversation.upserted" }!["payload"]!.objectValue!
        payload["id"] = .string("chat"); payload["kind"] = .string("group"); payload["botIds"] = .array([.string("owned_bot"), .string("second_owned_bot")])
        let room = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(payload))
        store.conversations = [room]; store.entries["chat"] = [try message("Previously authorized")]; store.selectedConversationID = "chat"
        XCTAssertNotNil(store.entries["chat"])
        XCTAssertEqual(try persistence.loadDraft(conversationID: "chat", accountID: "account")?.text, "Unsent group draft")
        try await store.apply(RealtimeEvent(seq: "1", payload: .conversationDeleted(Deleted(id: "chat", deleted: true)), timestampMs: 1))
        XCTAssertTrue(store.conversations.isEmpty); XCTAssertNil(store.entries["chat"]); XCTAssertNil(store.selectedConversationID)
        XCTAssertNil(try persistence.loadDraft(conversationID: "chat", accountID: "account"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try persistence.loadDraft(conversationID: "chat", accountID: "other")?.text, "Other account")
        XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
    }
    func testDirtyLocalComposerDoesNotAdoptRemoteRevisionSilently() async throws {
        let store = try store()
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "Local edits", attachmentIDs: []))
        let conversation = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events).first { $0.event == "conversation.upserted" }!
        guard case .conversationUpserted(var room) = conversation.payload else { return XCTFail("Missing fixture") }
        room.id = "chat"
        TestHTTPProtocol.handler = { request in
            switch request.url?.lastPathComponent {
            case "entries": return (200, [:], Data(#"{"items":[],"nextCursor":null}"#.utf8))
            case "composer": return (200, [:], try JSONEncoder().encode(ComposerDraft(conversationId: "chat", text: "Changed on another device", attachmentIds: [], replyToEntryId: nil, updatedAtMs: 1, revision: 9)))
            default: return (200, [:], try JSONEncoder().encode(room))
            }
        }
        try await store.openConversation("chat")
        XCTAssertEqual(store.draft(for: "chat").text, "Local edits")
        XCTAssertEqual(store.draft(for: "chat").revision, 1)
    }
    func testPersistedRejectionReconcilesAuthoredEntryAndFailedRunWithoutReplay() async throws {
        let store = try store()
        var failureRun = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events).first { $0["event"]?.stringValue == "run.upserted" }!["payload"]!.objectValue!
        failureRun["id"] = .string("rejected_run"); failureRun["conversationId"] = .string("chat"); failureRun["clientNonce"] = .string("refused_nonce_123456"); failureRun["status"] = .string("failed")
        failureRun["error"] = .object(["code": .string("capability_unavailable"), "message": .string("Configure destination provider"), "requestId": .string("refusal"), "retrySafe": .bool(true)])
        let run = try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(failureRun))
        var entry = try message("Authored text")
        if case .message(var value) = entry { value.id = "authored"; value.conversationId = "chat"; value.clientNonce = "refused_nonce_123456"; entry = .message(value) }
        var settled = false
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (503, [:], Data(#"{"error":{"code":"capability_unavailable","message":"Configure destination provider","requestId":"refusal","retrySafe":true,"details":{"clientNonce":"refused_nonce_123456","entryIds":["authored"],"runIds":["rejected_run"]}}}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/v1/conversations/chat/messages/receipts/refused_nonce_123456")
            return (200, [:], try JSONEncoder().encode(MessageReceipt(entries: [entry], runs: [run], clientNonce: "refused_nonce_123456", status: settled ? "accepted" : "outcome_unknown", delivery: [MessageReceiptDelivery(botId: run.botId, requestedMode: "followup", effectiveMode: "rejected", runId: run.id)])))
        }
        do { let _: MessageReceipt = try await store.mutate("POST", "/conversations/chat/messages", body: ["clientNonce": .string("refused_nonce_123456"), "text": .string("Authored text")]); XCTFail("Expected actual refusal") }
        catch let error as BackendError { XCTAssertEqual(error.failure.code, "capability_unavailable") }
        XCTAssertEqual(store.pendingIntents.first?.state, "recorded_refusal")
        settled = true
        await store.reconcilePendingMessages()
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.reconciledMessageReceipts["refused_nonce_123456"]?.delivery.first?.effectiveMode, "rejected")
        XCTAssertEqual(store.entries["chat"]?.first?.id, "authored")
        XCTAssertEqual(store.runs.first?.status, "failed")
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(TestHTTPProtocol.requests.dropFirst().allSatisfy { $0.httpMethod == "GET" })
    }
    func testTaskNotificationWithExactTaskConversationFetchesAndSelectsItsEntry() async throws {
        let store = try store()
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        guard let botEvent = events.first(where: { $0.event == "bot.upserted" }),
              case .botUpserted(let bot) = botEvent.payload,
              let roomEvent = events.first(where: { $0.event == "conversation.upserted" }),
              case .conversationUpserted(var task) = roomEvent.payload else { return XCTFail("Required resource fixtures missing") }
        task.id = "task_exact"; task.kind = "task"; task.parentConversationId = "main_parent"; task.botIds = [bot.id]
        var entry = try message("Reviewed task result")
        if case .message(var value) = entry { value.conversationId = task.id; value.streaming = false; entry = .message(value) }
        let room = task, targetEntry = entry
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url?.path {
            case "/v1/workspace": return (200, [:], try JSONEncoder().encode(snapshot.workspace))
            case "/v1/bots/resource": return (200, [:], try JSONEncoder().encode(bot))
            case "/v1/conversations/task_exact": return (200, [:], try JSONEncoder().encode(room))
            case "/v1/entries/resource": return (200, [:], try JSONEncoder().encode(targetEntry))
            case "/v1/conversations/task_exact/entries": return (200, [:], try JSONEncoder().encode(Page(items: [targetEntry], nextCursor: nil)))
            case "/v1/conversations/task_exact/composer": return (200, [:], try JSONEncoder().encode(ComposerDraft(conversationId: room.id, text: "", attachmentIds: [], replyToEntryId: nil, updatedAtMs: 1, revision: 1)))
            default: throw URLError(.unsupportedURL)
            }
        }
        let url = try XCTUnwrap(URL(string: "lemonbot://workspace/resource/bot/resource?conversationId=task_exact&taskConversationId=task_exact&entryId=resource"))
        try await store.navigate(url)
        XCTAssertEqual(store.selectedConversationID, "task_exact")
        XCTAssertEqual(store.navigationTarget?.entryID, "resource")
        XCTAssertEqual(store.entries["task_exact"]?.first?.text, "Reviewed task result")
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}

extension StoreTests {
    func testInvisibleResourceDoesNotProveUnknownDeletionCompleted() async throws {
        let store = try store()
        let intent = MutationIntent(clientNonce: "delete_fenced_123456", method: "DELETE", path: "/bots/private_bot", expectedRevision: 2, state: "outcome_unknown")
        store.pendingIntents = [intent]
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (404, [:], Data(#"{"error":{"code":"not_found","message":"Not found or invisible.","requestId":"req_acl","retrySafe":true}}"#.utf8))
        }
        let resolved = try await store.reconcileMutation(intent.clientNonce)
        XCTAssertFalse(resolved)
        XCTAssertEqual(store.pendingIntents, [intent])
    }

    func testUnrelatedRevisionDoesNotReleaseOriginalMutationFence() async throws {
        let store = try store()
        let intent = MutationIntent(clientNonce: "edit_fenced_123456", method: "PATCH", path: "/bots/resource", expectedRevision: 2, state: "outcome_unknown")
        store.pendingIntents = [intent]
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], Data(#"{"id":"resource","revision":99}"#.utf8))
        }
        let resolved = try await store.reconcileMutation(intent.clientNonce)
        XCTAssertFalse(resolved)
        XCTAssertEqual(store.pendingIntents, [intent])
    }

    func testUnknownStopRequiresObservedTerminalRunBeforeReleasingFence() async throws {
        let store = try store()
        let intent = MutationIntent(clientNonce: "stop_fenced_123456", method: "POST", path: "/runs/resource/cancel", state: "outcome_unknown")
        store.pendingIntents = [intent]
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        guard let event = events.first(where: { $0.event == "run.upserted" }), case .runUpserted(var run) = event.payload else { return XCTFail("Run fixture missing") }
        run.status = "running"
        let active = run
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], try JSONEncoder().encode(active))
        }
        let stillUnknown = try await store.reconcileMutation(intent.clientNonce)
        XCTAssertFalse(stillUnknown)
        XCTAssertEqual(store.pendingIntents, [intent])
        run.status = "cancelled"
        let cancelled = run
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], try JSONEncoder().encode(cancelled))
        }
        let verifiedTerminal = try await store.reconcileMutation(intent.clientNonce)
        XCTAssertTrue(verifiedTerminal)
        XCTAssertTrue(store.pendingIntents.isEmpty)
    }
}
