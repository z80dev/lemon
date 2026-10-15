import XCTest
import Foundation
import Network
@testable import LemonBotKit

// Captured from createConversationRoutes POST /messages -> sendMessage -> runtime.submit,
// using backend/test/runtime/fixture.ts's acknowledged chat.send controller seam.
private let acceptedSendReceipt = Data(#"""
{"entries":[{"conversationId":"conversation_k2lyNtKoiUli6pxaSSPHUi6L","seq":1,"timestampMs":1792039422007,"actor":{"kind":"user","id":"alice","displayName":"alice"},"clientNonce":"send_ack_real_nonce_123456","batchId":"batch_0w6J681a7XkuJkdylE0IrJ4J","replyToEntryId":null,"runId":null,"targetedUserId":null,"reactions":[],"id":"entry_5GK2TDtmlqvsc8Vgpa7ctzvX","revision":1,"createdAtMs":1792039422007,"updatedAtMs":1792039422007,"kind":"message","role":"user","text":"Hello from iOS","streaming":false,"attachmentIds":[]}],"runs":[{"id":"run_w31F7BjLpLX4mgRXFw6-pb1B","conversationId":"conversation_k2lyNtKoiUli6pxaSSPHUi6L","botId":"bot_SrWYvSto-EjzdfjsvEB4WCbA","initiatorUserId":"alice","clientNonce":"send_ack_real_nonce_123456","status":"running","error":null,"startedAtMs":1792039422030,"completedAtMs":null,"routineRunId":null,"revision":2,"createdAtMs":1792039422009,"updatedAtMs":1792039422030}],"clientNonce":"send_ack_real_nonce_123456","status":"accepted","delivery":[{"botId":"bot_SrWYvSto-EjzdfjsvEB4WCbA","requestedMode":"followup","effectiveMode":"started","targetRunId":null,"runId":"run_w31F7BjLpLX4mgRXFw6-pb1B"}]}
"""#.utf8)

private final class SendAcknowledgementCredentials: AccountCredentialStore {
    private var accounts: [StoredAccount] = []
    func load() throws -> [StoredAccount] { accounts }
    func save(_ account: StoredAccount) throws { accounts.removeAll { $0.id == account.id }; accounts.append(account) }
    func remove(_ id: String) throws { accounts.removeAll { $0.id == id } }
    private var pending: PendingDevicePairing?
    func loadPendingPairing() throws -> PendingDevicePairing? { pending }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws { pending = pairing }
    func removePendingPairing() throws { pending = nil }
}

private final class PresenceConnections: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NWConnection] = []
    func insert(_ value: NWConnection) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func cancel() { lock.lock(); defer { lock.unlock() }; for value in values { value.cancel() }; values = [] }
}

final class HeldSendHTTPProtocol: URLProtocol {
    static var started: ((HeldSendHTTPProtocol) -> Void)?
    static var receiptResponse: Data?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "POST" else {
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.receiptResponse == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.receiptResponse ?? Data(#"{"error":{"code":"not_found","message":"No authoritative receipt","requestId":"held_receipt","retrySafe":true}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        Self.started?(self)
    }
    override func stopLoading() {}
    func respond() throws {
        var receipt = try JSONDecoder().decode(JSONObject.self, from: acceptedSendReceipt)
        let nonce = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))["clientNonce"]!
        receipt["clientNonce"] = nonce
        for key in ["entries", "runs"] {
            receipt[key] = .array(receipt[key]!.arrayValue!.map { var value = $0.objectValue!; value["clientNonce"] = nonce; return .object(value) })
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try JSONEncoder().encode(receipt))
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: URLError) { client?.urlProtocol(self, didFailWithError: error) }
}

@MainActor
final class SendAcknowledgementTests: XCTestCase {
    override func setUp() { TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil }
    override func tearDown() { TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
    func testRealBackendAcceptedReceiptDecodesWithoutInventingDeliveryFailure() async throws {
        let decoded = try JSONDecoder().decode(MessageReceipt.self, from: acceptedSendReceipt)
        XCTAssertEqual(decoded.status, "accepted")
        XCTAssertEqual(decoded.delivery.map(\.effectiveMode), ["started"])
        XCTAssertNil(decoded.runs.first?.error)
        TestHTTPProtocol.handler = { _ in (202, ["Content-Type": "application/json"], acceptedSendReceipt) }
        let transport = try HTTPTransport(baseURL: XCTUnwrap(URL(string: "https://product.example")), session: TestHTTPProtocol.session())
        let received: MessageReceipt = try await transport.mutate("POST", "/conversations/\(decoded.entries[0].conversationId)/messages", body: ["clientNonce": .string(decoded.clientNonce), "text": .string("Hello from iOS")])
        XCTAssertEqual(received, decoded)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    private func store() throws -> LemonBotStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LemonBotStore(keychain: SendAcknowledgementCredentials(), persistence: ClientPersistence(root: root))
        store.account = StoredAccount(id: "send_ack", baseURL: URL(string: "https://product.example/v1")!, email: "test@example.org", displayName: "Test", token: "session", userID: "alice", workspaceID: "workspace")
        store.transport = try HTTPTransport(baseURL: store.account!.baseURL, token: "session", session: TestHTTPProtocol.session())
        store.connectionState = "online"
        store.snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        return store
    }
    private func stalledSocket(_ session: URLSession) async throws -> URLSessionWebSocketTask {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "Isolated socket listener ready")
        let connected = expectation(description: "Presence connection waits for its remote handshake")
        let connections = PresenceConnections()
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connections.insert(connection)
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in connected.fulfill() }
        }
        listener.start(queue: .global())
        addTeardownBlock { listener.cancel(); connections.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port.rawValue)/realtime")!)
        socket.resume()
        await fulfillment(of: [connected], timeout: 5)
        return socket
    }
    func testReconnectDuringDelayedSendDoesNotPublishObsoletePresenceFailure() async throws {
        let store = try store(), session = URLSession(configuration: .ephemeral)
        defer { store.stopSocket(); session.invalidateAndCancel() }
        let room = try JSONDecoder().decode(MessageReceipt.self, from: acceptedSendReceipt).entries[0].conversationId
        // A held remote handshake keeps the real native presence write in flight until reconnect.
        let departing = try await stalledSocket(session)
        store.socket = departing
        let presence = Task { try await store.setPresence(foreground: true, conversationID: room) }
        while store.visibleConversationID != room { await Task.yield() }
        let started = expectation(description: "Remote message acknowledgement is still in flight")
        var held: HeldSendHTTPProtocol?
        HeldSendHTTPProtocol.started = { held = $0; started.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSendHTTPProtocol.self]
        let http = URLSession(configuration: configuration)
        defer { HeldSendHTTPProtocol.started = nil; http.invalidateAndCancel() }
        store.transport = try HTTPTransport(baseURL: store.account!.baseURL, session: http)
        let sending = Task { try await store.send(conversationID: room, text: "Hello from iOS", attachmentIDs: []) }
        await fulfillment(of: [started], timeout: 5)
        store.stopSocket()
        store.socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:4828/realtime")!)
        store.connectionState = "online"
        var banner: String?
        do { try await presence.value } catch { banner = error.localizedDescription }
        try XCTUnwrap(held).respond()
        let receipt = try await sending.value
        XCTAssertEqual(receipt.status, "accepted")
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(banner, "A cancelled, replaced presence socket must not become the iOS delegate's delivery-error banner.")
        XCTAssertEqual(held?.request.httpMethod, "POST")
    }
    func testCurrentPresenceSocketFailureRemainsObservable() async throws {
        let store = try store(), session = URLSession(configuration: .ephemeral)
        defer { store.stopSocket(); session.invalidateAndCancel() }
        let socket = try await stalledSocket(session)
        store.socket = socket
        let presence = Task { try await store.setPresence(foreground: true, conversationID: "chat") }
        while store.visibleConversationID != "chat" { await Task.yield() }
        socket.cancel(with: .goingAway, reason: nil)
        do { try await presence.value; XCTFail("A failure on the current connection must still be reported.") }
        catch { XCTAssertTrue(error is URLError) }
    }
    func testLostMessageAcknowledgementAfterReconnectRemainsUncertainAndFenced() async throws { try await assertUncertainMessage(.networkConnectionLost) }
    func testBackgroundCancelledMessageAcknowledgementRemainsUncertainAndFenced() async throws { try await assertUncertainMessage(.cancelled) }
    func testSlowMessageAcknowledgementTimeoutRemainsUncertainAndFenced() async throws { try await assertUncertainMessage(.timedOut) }
    private func assertUncertainMessage(_ code: URLError.Code) async throws {
        let store = try store()
        let started = expectation(description: "Message POST awaits its remote acknowledgement")
        var held: HeldSendHTTPProtocol?
        HeldSendHTTPProtocol.started = { held = $0; started.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSendHTTPProtocol.self]
        let http = URLSession(configuration: configuration)
        defer { HeldSendHTTPProtocol.started = nil; http.invalidateAndCancel() }
        store.transport = try HTTPTransport(baseURL: store.account!.baseURL, session: http)
        let sending = Task { try await store.send(conversationID: "chat", text: "Retain this utterance", attachmentIDs: []) }
        await fulfillment(of: [started], timeout: 5)
        store.stopSocket(); store.connectionState = "online"
        let request = try XCTUnwrap(held)
        let nonce = try XCTUnwrap(try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request.request))["clientNonce"]?.stringValue)
        request.fail(URLError(code))
        do { _ = try await sending.value; XCTFail("A lost HTTP acknowledgement must never become success.") }
        catch ClientError.outcomeUnknown(let value) { XCTAssertEqual(value, nonce) }
        XCTAssertEqual(store.pendingIntents.first?.clientNonce, nonce)
        XCTAssertEqual(store.pendingIntents.first?.state, "outcome_unknown")
        do { _ = try await store.send(conversationID: "chat", text: "Do not replay", attachmentIDs: []); XCTFail("Uncertain sends must remain fenced.") }
        catch ClientError.unresolvedMutation(let value) { XCTAssertEqual(value.clientNonce, nonce) }
    }
    func testAccountChangeDuringDelayedSendDoesNotInstallThePreviousAccountsReceipt() async throws {
        let store = try store()
        let started = expectation(description: "Previous account's message acknowledgement is delayed")
        var held: HeldSendHTTPProtocol?
        HeldSendHTTPProtocol.started = { held = $0; started.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldSendHTTPProtocol.self]
        let http = URLSession(configuration: configuration)
        defer { HeldSendHTTPProtocol.started = nil; http.invalidateAndCancel() }
        store.transport = try HTTPTransport(baseURL: store.account!.baseURL, session: http)
        let sending = Task { try await store.send(conversationID: "chat", text: "Previous account's message", attachmentIDs: []) }
        await fulfillment(of: [started], timeout: 5)
        store.stopSocket(); store.generation = UUID()
        try XCTUnwrap(held).respond()
        do { _ = try await sending.value; XCTFail("An old account's receipt must not be installed in the new generation.") }
        catch ClientError.accountChanged {}
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(store.runs.isEmpty)
    }
}
