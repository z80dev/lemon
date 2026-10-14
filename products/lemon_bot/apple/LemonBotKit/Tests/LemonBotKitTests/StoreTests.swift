import XCTest
import Foundation
@testable import LemonBotKit

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
    private func store(_ persistence: ClientPersistence? = nil) throws -> LemonBotStore {
        let store = LemonBotStore(keychain: AccountKeychain(service: "LemonBotTests." + UUID().uuidString), persistence: persistence ?? self.persistence())
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
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/v1/sync")
            return (200, [:], WireFixtures.snapshot)
        }
        try await store.recoverExpiredCursor()
        XCTAssertEqual(store.draft(for: "chat").text, "Retained, never automatically sent")
        XCTAssertNil(store.entries["revokedConversation"])
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
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
        let persistence = persistence(), store = try store(persistence)
        XCTAssertTrue(store.setLocalDraft(conversationID: "chat", text: "private draft", attachmentIDs: []))
        try persistence.saveDraft(LocalComposerDraft(text: "other account"), conversationID: "chat", accountID: "other")
        store.entries["chat"] = [try message("private transcript")]; store.cursor = "99"
        TestHTTPProtocol.handler = { _ in (401, [:], Data(#"{"error":{"code":"unauthenticated","message":"Session revoked","requestId":"req_logout","retrySafe":true}}"#.utf8)) }
        try await store.signOut()
        XCTAssertNil(store.account); XCTAssertTrue(store.entries.isEmpty); XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertEqual(store.cursor, "0"); XCTAssertEqual(store.connectionState, "disconnected")
        XCTAssertNil(try persistence.loadDraft(conversationID: "chat", accountID: "account"))
        XCTAssertEqual(try persistence.loadDraft(conversationID: "chat", accountID: "other")?.text, "other account")
    }
    func testUnknownMutationNoncePersistsWithoutBodyAndFencesRestart() async throws {
        let persistence = persistence(), first = try store(persistence)
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            let _: MessageReceipt = try await first.mutate("POST", "/conversations/chat/messages", body: ["clientNonce": .string("fixed_intent_123456"), "text": .string("must_not_persist"), "password": .string("never_store_credentials")])
            XCTFail("Expected uncertain outcome")
        } catch ClientError.outcomeUnknown(let nonce) { XCTAssertEqual(nonce, "fixed_intent_123456") }
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
        let run = try JSONDecoder().decode(Run.self, from: JSONEncoder().encode(resource))
        let receipt = MessageReceipt(entries: [], runs: [run], clientNonce: "fixed_message_123456", status: "outcome_unknown", delivery: [])
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" { return (202, [:], try JSONEncoder().encode(receipt)) }
            XCTAssertEqual(request.url?.path, "/v1/runs")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clientNonce" })?.value, "fixed_message_123456")
            var reconciled = run; reconciled.status = "queued"
            return (200, [:], try JSONEncoder().encode(Page(items: [reconciled], nextCursor: nil)))
        }
        let accepted: MessageReceipt = try await store.mutate("POST", "/conversations/chat/messages", body: ["clientNonce": .string("fixed_message_123456"), "text": .string("Hello")])
        XCTAssertEqual(accepted.status, "outcome_unknown")
        XCTAssertEqual(store.pendingIntents.first?.runID, run.id)
        let resolved = try await store.reconcileMutation("fixed_message_123456")
        XCTAssertTrue(resolved)
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertTrue(try persistence.loadMutationIntents(accountID: "account").isEmpty)
        XCTAssertEqual(TestHTTPProtocol.requests.map(\.httpMethod), ["POST", "GET"])
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
    func testOwnGroupLeaveRemovesOnlyOwnCachedRoomAndOtherMemberRefreshes() async throws {
        let store = try store()
        var payload = try JSONDecoder().decode([JSONObject].self, from: WireFixtures.events).first { $0["event"]?.stringValue == "conversation.upserted" }!["payload"]!.objectValue!
        payload["id"] = .string("chat"); payload["kind"] = .string("group"); payload["humanUserIds"] = .array([.string("resource"), .string("other")])
        let room = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(payload))
        store.conversations = [room]; store.entries["chat"] = [try message("Previously authorized")]; store.selectedConversationID = "chat"
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            var updated = room; updated.humanUserIds = ["resource"]; updated.revision += 1
            return (200, [:], try JSONEncoder().encode(updated))
        }
        try await store.apply(RealtimeEvent(seq: "1", payload: .conversationLeft(RealtimeConversationLeft(conversationId: "chat", userId: "other")), timestampMs: 1))
        XCTAssertEqual(store.conversations.first?.humanUserIds, ["resource"])
        XCTAssertNotNil(store.entries["chat"])
        try await store.apply(RealtimeEvent(seq: "2", payload: .conversationLeft(RealtimeConversationLeft(conversationId: "chat", userId: "resource")), timestampMs: 1))
        XCTAssertTrue(store.conversations.isEmpty); XCTAssertNil(store.entries["chat"]); XCTAssertNil(store.selectedConversationID)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
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
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (503, [:], Data(#"{"error":{"code":"capability_unavailable","message":"Configure destination provider","requestId":"refusal","retrySafe":true,"details":{"clientNonce":"refused_nonce_123456","entryIds":["authored"],"runIds":["rejected_run"]}}}"#.utf8))
            }
            if request.url?.path == "/v1/runs" { return (200, [:], try JSONEncoder().encode(Page(items: [run], nextCursor: nil))) }
            XCTAssertEqual(request.url?.path, "/v1/entries/authored")
            return (200, [:], try JSONEncoder().encode(entry))
        }
        do { let _: MessageReceipt = try await store.mutate("POST", "/conversations/chat/messages", body: ["clientNonce": .string("refused_nonce_123456"), "text": .string("Authored text")]); XCTFail("Expected actual refusal") }
        catch let error as BackendError { XCTAssertEqual(error.failure.code, "capability_unavailable") }
        XCTAssertEqual(store.pendingIntents.first?.state, "recorded_refusal")
        let resolved = try await store.reconcileMutation("refused_nonce_123456")
        XCTAssertTrue(resolved); XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.entries["chat"]?.first?.id, "authored")
        XCTAssertEqual(store.runs.first?.status, "failed")
        XCTAssertEqual(TestHTTPProtocol.requests.map(\.httpMethod), ["POST", "GET", "GET"])
    }
}
