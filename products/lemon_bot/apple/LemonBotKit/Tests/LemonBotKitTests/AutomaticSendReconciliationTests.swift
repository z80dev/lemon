import XCTest
import Foundation
import Network
@testable import LemonBotKit

private final class ReconciliationCredentials: AccountCredentialStore {
    private var values: [StoredAccount] = []
    func load() throws -> [StoredAccount] { values }
    func save(_ account: StoredAccount) throws { values.removeAll { $0.id == account.id }; values.append(account) }
    func remove(_ id: String) throws { values.removeAll { $0.id == id } }
    private var pending: PendingDevicePairing?
    func loadPendingPairing() throws -> PendingDevicePairing? { pending }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws { pending = pairing }
    func removePendingPairing() throws { pending = nil }
}

@MainActor final class AutomaticSendReconciliationTests: XCTestCase {
    private let nonce = "automatic_message_nonce_123456"
    private func store() throws -> LemonBotStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root); TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
        let store = LemonBotStore(keychain: ReconciliationCredentials(), persistence: ClientPersistence(root: root))
        store.account = StoredAccount(id: "automatic", baseURL: URL(string: "https://product.example/v1")!, email: "owner@example.org", displayName: "Owner", token: "session", userID: "owner", workspaceID: "workspace")
        store.transport = try HTTPTransport(baseURL: store.account!.baseURL, token: "session", session: TestHTTPProtocol.session())
        store.connectionState = "online"
        TestHTTPProtocol.requests = []
        return store
    }
    private func receipt(clientNonce: String? = nil, status: String = "accepted", runStatus: String = "running", rejected: Bool = false, effectiveMode: String? = nil, text: String = "Original reviewed text") -> MessageReceipt {
        let nonce = clientNonce ?? self.nonce
        let failure = rejected ? RunError(code: "capability_unavailable", message: "Configure the provider", requestId: "recorded_refusal", retrySafe: true) : nil
        let run = Run(id: "run", revision: 2, createdAtMs: 1, updatedAtMs: 2, conversationId: "chat", botId: "bot", initiatorUserId: "owner", clientNonce: nonce, status: runStatus, error: failure, startedAtMs: rejected ? nil : 2)
        let entry = TranscriptEntry.message(MessageEntry(id: "authored", revision: 1, createdAtMs: 1, updatedAtMs: 1, conversationId: "chat", seq: 1, timestampMs: 1, actor: Actor(kind: "user", id: "owner", displayName: "Owner"), clientNonce: nonce, batchId: "batch", reactions: [], role: "user", text: text, streaming: false, attachmentIds: []))
        return MessageReceipt(entries: [entry], runs: [run], clientNonce: nonce, status: status, delivery: [MessageReceiptDelivery(botId: "bot", requestedMode: "followup", effectiveMode: effectiveMode ?? (rejected ? "rejected" : "started"), runId: run.id)])
    }
    /// The backend's reservation before any target run: the authored entry is recorded, delivery is not.
    private func reservation(clientNonce: String? = nil) -> MessageReceipt {
        var value = receipt(clientNonce: clientNonce, status: "outcome_unknown"); value.runs = []; value.delivery = []
        return value
    }
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
    }
    func testRealtimeRunObservationTriggersAuthoritativeReceiptLookupWithoutResending() async throws {
        let store = try store(), complete = receipt()
        var settled = false
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            XCTAssertEqual(request.url?.path, "/v1/conversations/chat/messages/receipts/\(self.nonce)")
            var current = complete; if !settled { current.status = "outcome_unknown" }
            return (200, [:], try JSONEncoder().encode(current))
        }
        do { let _: MessageReceipt = try await store.mutate("POST", "/conversations/chat/messages", body: ["clientNonce": .string(nonce), "text": .string("Original reviewed text")]); XCTFail("Lost HTTP acknowledgement must initially be uncertain") }
        catch ClientError.outcomeUnknown {}
        XCTAssertEqual(store.pendingIntents.count, 1)
        settled = true
        try await store.apply(RealtimeEvent(seq: "1", payload: .entryUpserted(complete.entries[0]), timestampMs: 1))
        try await store.apply(RealtimeEvent(seq: "2", payload: .runUpserted(complete.runs[0]), timestampMs: 1))
        await waitUntil { store.pendingIntents.isEmpty }
        XCTAssertTrue(store.pendingIntents.isEmpty, "An accepted original receipt must clear the fence automatically.")
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(TestHTTPProtocol.requests.contains { $0.httpMethod == "GET" })
        XCTAssertEqual(store.entries["chat"]?.first?.clientNonce, nonce)
    }
    func testPartialGroupReceiptCannotBeSettledByOneKnownRun() async throws {
        let store = try store(), partial = receipt(status: "outcome_unknown")
        store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
        TestHTTPProtocol.handler = { request in
            if request.url?.path == "/v1/runs" { return (200, [:], try JSONEncoder().encode(Page(items: partial.runs, nextCursor: nil))) }
            XCTAssertEqual(request.url?.path, "/v1/conversations/chat/messages/receipts/\(self.nonce)")
            return (200, [:], try JSONEncoder().encode(partial))
        }
        let resolved = try await store.reconcileMutation(nonce)
        XCTAssertFalse(resolved, "The receipt knows other targets are still unreserved even though one run is running.")
        XCTAssertEqual(store.pendingIntents.count, 1)
    }
    func testReceiptRefusalRemainsVisibleAfterAutomaticFenceResolution() async throws {
        let store = try store(), refused = receipt(runStatus: "failed", rejected: true)
        store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "recorded_refusal")]
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], try JSONEncoder().encode(refused))
        }
        try await store.apply(RealtimeEvent(seq: "1", payload: .runUpserted(refused.runs[0]), timestampMs: 1))
        await waitUntil { store.pendingIntents.isEmpty }
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.runs.first?.status, "failed")
        XCTAssertEqual(store.runs.first?.error?.message, "Configure the provider")
    }
    func testEnvelopeLess502And504ReturnTheAuthoritativeAcceptedReceiptWithoutResending() async throws {
        for status in [502, 504] { try await assertRecoveredSend(status: status) }
    }
    func testTimeoutAndNetworkSwitchReturnTheAuthoritativeAcceptedReceiptWithoutResending() async throws {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cancelled] { try await assertRecoveredSend(error: URLError(code)) }
    }
    func testRelayFailureWithRecordedRefusalKeepsTheActualTargetError() async throws { try await assertRecoveredSend(status: 502, rejected: true) }
    private func assertRecoveredSend(status: Int = 502, error: URLError? = nil, rejected: Bool = false) async throws {
        let store = try store()
        var recorded: MessageReceipt?
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let nonce = try XCTUnwrap(try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))["clientNonce"]?.stringValue)
                recorded = self.receipt(clientNonce: nonce, runStatus: rejected ? "failed" : "succeeded", rejected: rejected)
                if let error { throw error }
                return (status, ["Content-Type": "text/plain"], Data("Remote relay did not return the acknowledgement".utf8))
            }
            let receipt = try XCTUnwrap(recorded)
            XCTAssertEqual(request.url?.path, "/v1/conversations/chat/messages/receipts/\(receipt.clientNonce)")
            return (200, [:], try JSONEncoder().encode(receipt))
        }
        let result = try await store.send(conversationID: "chat", text: "Original reviewed text", attachmentIDs: [])
        XCTAssertEqual(result, recorded)
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertTrue(TestHTTPProtocol.requests.dropFirst().allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(result.delivery.first?.effectiveMode, rejected ? "rejected" : "started")
        XCTAssertEqual(result.runs.first?.error?.message, rejected ? "Configure the provider" : nil)
    }
    func testRealtimeCanSettleAnInFlightMessageBeforeItsLostHTTPAcknowledgement() async throws {
        let store = try store(), started = expectation(description: "Original message POST in flight")
        var held: HeldSendHTTPProtocol?
        HeldSendHTTPProtocol.started = { held = $0; started.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSendHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { HeldSendHTTPProtocol.started = nil; HeldSendHTTPProtocol.receiptResponse = nil; session.invalidateAndCancel() }
        store.transport = try HTTPTransport(baseURL: store.account!.baseURL, session: session)
        let sending = Task { try await store.send(conversationID: "chat", text: "Original reviewed text", attachmentIDs: []) }
        await fulfillment(of: [started], timeout: 5)
        let request = try XCTUnwrap(held)
        let nonce = try XCTUnwrap(try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request.request))["clientNonce"]?.stringValue)
        let recorded = receipt(clientNonce: nonce)
        HeldSendHTTPProtocol.receiptResponse = try JSONEncoder().encode(recorded)
        try await store.apply(RealtimeEvent(seq: "1", payload: .runUpserted(recorded.runs[0]), timestampMs: 1))
        await waitUntil { store.pendingIntents.isEmpty }
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.reconciledMessageReceipts[nonce], recorded)
        request.fail(URLError(.timedOut))
        let result = try await sending.value
        XCTAssertEqual(result, recorded)
        XCTAssertTrue(store.pendingIntents.isEmpty, "Late transport failure must not restore a settled nonce fence.")
    }
    func testForegroundReconciliationSettlesAPersistedMessageUsingOnlyGET() async throws {
        let store = try store(), recorded = receipt()
        store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], try JSONEncoder().encode(recorded))
        }
        await store.reconcilePendingMessages()
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.reconciledMessageReceipts[nonce], recorded)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    func testCaughtUpReconnectRechecksTheOriginalMessageReceipt() async throws {
        let store = try store(), recorded = receipt()
        store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], try JSONEncoder().encode(recorded))
        }
        let ready = expectation(description: "Reconnect socket ready"), acknowledged = expectation(description: "Reconnect caught-up frame acknowledged")
        let server = try AckSocketServer(ready: ready) { _ in acknowledged.fulfill() }
        defer { server.close() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port.rawValue)/realtime")!)
        defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        socket.resume()
        let frame = try JSONDecoder().decode(RealtimeServerFrame.self, from: Data(#"{"type":"caught_up","cursor":"0"}"#.utf8))
        try await store.process(frame, on: socket)
        await fulfillment(of: [acknowledged], timeout: 5)
        await waitUntil { store.pendingIntents.isEmpty }
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.reconciledMessageReceipts[nonce], recorded)
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testMissingOrUnavailableReceiptCannotEraseAnUncertainSend() async throws {
        for status in [404, 503] {
            let store = try store()
            store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
            TestHTTPProtocol.handler = { _ in (status, [:], Data(#"{"error":{"code":"not_found","message":"No authoritative receipt","requestId":"lookup_failed","retrySafe":true}}"#.utf8)) }
            await store.reconcilePendingMessages()
            XCTAssertEqual(store.pendingIntents.count, 1)
            XCTAssertTrue(store.reconciledMessageReceipts.isEmpty)
            XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }
    func testAReceiptForAnotherActorOrNonceCannotReleaseTheFence() async throws {
        for foreignNonce in [false, true] {
            let store = try store()
            store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
            var invalid = receipt()
            if foreignNonce { invalid.clientNonce = "another_message_nonce_123456" } else { invalid.runs[0].initiatorUserId = "another_owner" }
            let data = try JSONEncoder().encode(invalid)
            TestHTTPProtocol.handler = { _ in (200, [:], data) }
            await store.reconcilePendingMessages()
            XCTAssertEqual(store.pendingIntents.count, 1)
            XCTAssertTrue(store.reconciledMessageReceipts.isEmpty)
        }
    }
    func testRecordedReservationReleasesTheUnchangedDraftAndNoLongerHoldsTheNextMessage() async throws {
        let store = try store()
        store.setLocalDraft(conversationID: "chat", text: "Original reviewed text", attachmentIDs: [])
        store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
        var complete = false
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" {
                let next = try XCTUnwrap(try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))["clientNonce"]?.stringValue)
                return (200, [:], try JSONEncoder().encode(self.receipt(clientNonce: next, text: "A newer message")))
            }
            XCTAssertEqual(request.url?.path, "/v1/conversations/chat/messages/receipts/\(self.nonce)")
            return (200, [:], try JSONEncoder().encode(complete ? self.receipt() : self.reservation()))
        }
        await store.reconcilePendingMessages()
        XCTAssertEqual(store.pendingIntents.map(\.state), ["message_recorded"])
        XCTAssertEqual(store.draft(for: "chat").text, "", "The recorded message is in the transcript; the composer no longer holds it.")
        store.setLocalDraft(conversationID: "chat", text: "A newer message", attachmentIDs: [])
        let newer = try await store.send(conversationID: "chat", text: "A newer message", attachmentIDs: [])
        XCTAssertEqual(newer.status, "accepted", "A recorded message with unconfirmed delivery must not trap the next one.")
        XCTAssertEqual(store.draft(for: "chat").text, "")
        XCTAssertEqual(store.pendingIntents.map(\.clientNonce), [nonce], "Only the earlier delivery remains to confirm.")
        store.setLocalDraft(conversationID: "chat", text: "Original reviewed text", attachmentIDs: [])
        complete = true
        await store.reconcilePendingMessages()
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.reconciledMessageReceipts[nonce]?.status, "accepted")
        XCTAssertEqual(store.draft(for: "chat").text, "Original reviewed text", "A settled nonce never clears a later identical draft.")
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testEntryRecordedWhileSendIsInFlightClearsTheInputAndSurvivesALostAcknowledgement() async throws {
        let store = try store(), started = expectation(description: "Original message POST in flight")
        var held: HeldSendHTTPProtocol?
        HeldSendHTTPProtocol.started = { held = $0; started.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSendHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { HeldSendHTTPProtocol.started = nil; HeldSendHTTPProtocol.receiptResponse = nil; session.invalidateAndCancel() }
        store.transport = try HTTPTransport(baseURL: store.account!.baseURL, session: session)
        store.setLocalDraft(conversationID: "chat", text: "Original reviewed text", attachmentIDs: [])
        let sending = Task { try await store.send(conversationID: "chat", text: "Original reviewed text", attachmentIDs: [], clientNonce: self.nonce) }
        await fulfillment(of: [started], timeout: 5)
        let recorded = reservation()
        HeldSendHTTPProtocol.receiptResponse = try JSONEncoder().encode(recorded)
        try await store.apply(RealtimeEvent(seq: "1", payload: .entryUpserted(recorded.entries[0]), timestampMs: 1))
        await waitUntil { store.draft(for: "chat").text.isEmpty }
        XCTAssertEqual(store.draft(for: "chat").text, "", "Send leaves the composer once the server records the message, before delivery answers.")
        XCTAssertEqual(store.pendingIntents.first?.state, "message_recorded")
        store.setLocalDraft(conversationID: "chat", text: "Follow-up thought", attachmentIDs: [])
        try XCTUnwrap(held).fail(URLError(.timedOut))
        do { _ = try await sending.value; XCTFail("A lost acknowledgement is not success") } catch ClientError.outcomeUnknown {}
        XCTAssertEqual(store.pendingIntents.map(\.state), ["message_recorded"], "A lost acknowledgement cannot unrecord the observed message.")
        XCTAssertEqual(store.draft(for: "chat").text, "Follow-up thought")
    }
    func testPreDispatchRefusalAfterATimedOutSendSettlesTheFenceAndKeepsTheActualError() async throws {
        let store = try store(), refused = receipt(runStatus: "failed", rejected: true)
        store.setLocalDraft(conversationID: "chat", text: "Original reviewed text", attachmentIDs: [])
        var failed = false
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" { throw URLError(.timedOut) }
            XCTAssertEqual(request.url?.path, "/v1/conversations/chat/messages/receipts/\(self.nonce)")
            return (200, [:], try JSONEncoder().encode(failed ? refused : self.receipt(status: "outcome_unknown", runStatus: "reserved", effectiveMode: "outcome_unknown")))
        }
        do { _ = try await store.send(conversationID: "chat", text: "Original reviewed text", attachmentIDs: [], clientNonce: nonce); XCTFail("A timed-out send is not confirmed") }
        catch ClientError.outcomeUnknown {}
        XCTAssertEqual(store.pendingIntents.map(\.state), ["message_recorded"])
        XCTAssertEqual(store.draft(for: "chat").text, "")
        failed = true
        try await store.apply(RealtimeEvent(seq: "1", payload: .runUpserted(refused.runs[0]), timestampMs: 1))
        await waitUntil { store.pendingIntents.isEmpty }
        XCTAssertTrue(store.pendingIntents.isEmpty, "A terminal refusal is an authoritative receipt; the fence must not wait forever.")
        XCTAssertEqual(store.reconciledMessageReceipts[nonce]?.delivery.first?.effectiveMode, "rejected")
        XCTAssertEqual(store.runs.first?.error?.message, "Configure the provider")
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    func testUnsettledReceiptIsRecheckedWithoutRealtimeAndWithoutResending() async throws {
        let store = try store(), realtime = URLSession(configuration: .ephemeral)
        defer { realtime.invalidateAndCancel() }
        // A connected (never resumed) socket: rechecks run only while realtime is up but silent about this receipt.
        store.socket = realtime.webSocketTask(with: URL(string: "ws://127.0.0.1:9/realtime")!)
        store.messageRecheckDelays = [.milliseconds(20), .milliseconds(20)]
        store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
        var reads = 0
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            reads += 1
            return (200, [:], try JSONEncoder().encode(reads == 1 ? self.reservation() : self.receipt()))
        }
        await store.reconcilePendingMessages()
        XCTAssertEqual(store.pendingIntents.count, 1)
        await waitUntil { store.pendingIntents.isEmpty }
        XCTAssertTrue(store.pendingIntents.isEmpty, "A delivery that settles without a realtime event is still found by a bounded read.")
        XCTAssertEqual(store.reconciledMessageReceipts[nonce]?.status, "accepted")
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testFinishedRunEventRestartsBoundedRechecksUntilItsDeliverySettles() async throws {
        let store = try store(), realtime = URLSession(configuration: .ephemeral)
        defer { realtime.invalidateAndCancel() }
        store.socket = realtime.webSocketTask(with: URL(string: "ws://127.0.0.1:9/realtime")!)
        store.messageRecheckDelays = [.milliseconds(20)]
        store.pendingIntents = [MutationIntent(clientNonce: nonce, method: "POST", path: "/conversations/chat/messages", state: "outcome_unknown")]
        // The reply finished, but the backend has not yet read the lost acknowledgement's admission receipt.
        let finished = receipt(status: "outcome_unknown", runStatus: "succeeded", effectiveMode: "outcome_unknown")
        var reads = 0
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            reads += 1
            return (200, [:], try JSONEncoder().encode(reads < 4 ? finished : self.receipt(runStatus: "succeeded")))
        }
        await store.reconcilePendingMessages()
        await waitUntil { reads == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads, 2, "Rechecks are bounded; a terminal run with unknown delivery never settles the fence by itself.")
        XCTAssertEqual(store.pendingIntents.map(\.state), ["message_recorded"])
        try await store.apply(RealtimeEvent(seq: "1", payload: .runUpserted(finished.runs[0]), timestampMs: 1))
        await waitUntil { store.pendingIntents.isEmpty }
        XCTAssertTrue(store.pendingIntents.isEmpty, "New run evidence restarts rechecks until the backend settles the delivery.")
        XCTAssertEqual(reads, 4)
        XCTAssertEqual(store.reconciledMessageReceipts[nonce]?.delivery.first?.effectiveMode, "started")
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}
