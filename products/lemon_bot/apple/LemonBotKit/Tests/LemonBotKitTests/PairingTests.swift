import XCTest
import Foundation
@testable import LemonBotKit

private final class PairingCredentialStore: AccountCredentialStore {
    var accounts: [StoredAccount] = []
    var pending: PendingDevicePairing?
    func load() throws -> [StoredAccount] { accounts }
    func save(_ account: StoredAccount) throws { accounts.removeAll { $0.id == account.id }; accounts.append(account) }
    func remove(_ id: String) throws { accounts.removeAll { $0.id == id } }
    func loadPendingPairing() throws -> PendingDevicePairing? { pending }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws { pending = pairing }
    func removePendingPairing() throws { pending = nil }
}

@MainActor final class PairingTests: XCTestCase {
    private let code = String(repeating: "A", count: 43)
    private let claimToken = String(repeating: "B", count: 43)
    private let origin = "https://product.example"
    private var deadline: TimestampMs { Date().timeIntervalSince1970 * 1000 + 240_000 }

    override func setUp() { TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil }
    override func tearDown() { TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
    private func persistence() -> ClientPersistence {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return ClientPersistence(root: root)
    }
    private func store(_ credentials: PairingCredentialStore, _ persistence: ClientPersistence) -> LemonBotStore {
        let originalInstallation = UserDefaults.standard.string(forKey: "LemonBot.installationID")
        addTeardownBlock {
            if let originalInstallation { UserDefaults.standard.set(originalInstallation, forKey: "LemonBot.installationID") }
            else { UserDefaults.standard.removeObject(forKey: "LemonBot.installationID") }
        }
        let value = LemonBotStore(keychain: credentials, persistence: persistence)
        value.httpSession = TestHTTPProtocol.session()
        return value
    }
    private func link(backend: String? = nil, workspace: ID = "resource", code: String? = nil) -> String {
        var parts = URLComponents()
        parts.scheme = "lemonbot"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "backend", value: backend ?? origin), URLQueryItem(name: "instance", value: "backend_1"), URLQueryItem(name: "cluster", value: workspace), URLQueryItem(name: "code", value: code ?? self.code)]
        return parts.string!
    }
    private func preview(_ expiry: TimestampMs) -> PairingPreviewResult { PairingPreviewResult(clusterName: "My desktop", backendUrl: origin, expiresAtMs: expiry) }
    private func claim(_ expiry: TimestampMs) -> PairingClaimResult { PairingClaimResult(pairingId: "pairing_1", claimToken: claimToken, verificationCode: "123456", expiresAtMs: expiry, clusterName: "My desktop", backendUrl: origin) }
    private func snapshot() throws -> Snapshot {
        var value = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        value.hasMore.bots = false; value.hasMore.machines = false; value.hasMore.conversations = false; value.hasMore.notifications = false
        return value
    }
    private func auth(_ snapshot: Snapshot) -> (AuthResult, Device) {
        let device = Device(id: "paired_device", revision: 1, createdAtMs: 1, updatedAtMs: 1, userId: snapshot.user.id, platform: "ios", name: "My iPhone", appVersion: "1", pushEnabled: false, lastSeenAtMs: 1)
        let session = AuthSession(id: "paired_session", revision: 1, createdAtMs: 1, updatedAtMs: 1, userId: snapshot.user.id, deviceId: device.id, expiresAtMs: nil, lastSeenAtMs: 1, current: true)
        return (AuthResult(token: "device-bound-product-session", session: session, user: snapshot.user, workspace: snapshot.workspace, member: snapshot.member), device)
    }
    private func installPreview(on store: LemonBotStore, expiry: TimestampMs) async throws {
        let result = preview(expiry)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/pairings/preview")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))
            XCTAssertEqual(body.keys.sorted(), ["pairCode", "workspaceId"])
            return (200, [:], try JSONEncoder().encode(result))
        }
        try store.preparePairing(link())
        XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
        try await store.previewPairing()
        XCTAssertEqual(store.pairingState, "preview_ready")
        XCTAssertEqual(store.pendingPairing?.clusterName, "My desktop")
        XCTAssertEqual(store.pendingPairing?.origin, origin)
    }

    func testPairingParserBoundsExactSingletonsAndTLS() throws {
        let parsed = try PairingLink.parse(link())
        XCTAssertEqual(parsed.workspaceId, "resource")
        XCTAssertEqual(parsed.instanceId, "backend_1")
        XCTAssertThrowsError(try PairingLink.parse(link().replacingOccurrences(of: "&instance=backend_1", with: "")))
        XCTAssertThrowsError(try PairingLink.parse(link() + "&instance=other"))
        XCTAssertEqual(parsed.backendURL?.absoluteString, "https://product.example/v1")
        XCTAssertFalse(parsed.description.contains(code))
        XCTAssertEqual(try PairingLink.parse(link(backend: "http://127.0.0.1:4080")).origin, "http://127.0.0.1:4080")
        for invalid in [link(backend: "http://100.100.100.100"), link(backend: "https://owner:secret@product.example"), link(backend: "https://product.example/v1"), link(backend: "https://product.example?token=secret"), link(workspace: "wrong/cluster"), link(code: "short"), link() + "&code=" + code, link() + "&token=secret", link() + "#fragment", "lemonbot://pair:123?backend=x&cluster=y&code=z", String(repeating: "A", count: 4097)] {
            XCTAssertThrowsError(try PairingLink.parse(invalid))
        }
    }

    func testClaimRequiresVerifiedPreviewAndRetainsOneNonceAcrossRestart() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence()
        let first = store(credentials, persistence)
        try first.preparePairing(link())
        do { try await first.requestPairing(deviceName: "My iPhone", appVersion: "1"); XCTFail("Claim must require a server preview") } catch PairingClientError.notReady {}
        XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
        let expiry = deadline
        try await installPreview(on: first, expiry: expiry)
        let result = claim(expiry)
        var bodies: [JSONObject] = []
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/pairings/claim")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            bodies.append(try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request)))
            if bodies.count == 1 { throw URLError(.timedOut) }
            return (200, [:], try JSONEncoder().encode(result))
        }
        do { try await first.requestPairing(deviceName: "My iPhone", appVersion: "1"); XCTFail("Lost claim response must remain unknown") } catch PairingClientError.unconfirmed {}
        XCTAssertEqual(first.pairingState, "claim_unknown")
        XCTAssertTrue(credentials.accounts.isEmpty)
        let reopened = store(credentials, persistence)
        XCTAssertEqual(reopened.pairingState, "claim_unknown")
        try await reopened.requestPairing(deviceName: "Changed phone name", appVersion: "2")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(reopened.pendingPairing?.verificationCode, "123456")
        XCTAssertEqual(reopened.pairingState, "pending_approval")
        XCTAssertTrue(credentials.accounts.isEmpty)
    }

    func testPendingAndLostCompletionUseSameNonceAndSaveOnlyDeviceSession() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence(), expiry = deadline
        let first = store(credentials, persistence)
        try await installPreview(on: first, expiry: expiry)
        let claimed = claim(expiry)
        TestHTTPProtocol.handler = { _ in (200, [:], try JSONEncoder().encode(claimed)) }
        try await first.requestPairing(deviceName: "My iPhone", appVersion: "1")
        let snapshot = try snapshot(), (auth, device) = auth(snapshot)
        let connected = PairingCompletion.connected(PairingCompletionConnected(auth: auth, device: device))
        var bodies: [JSONObject] = []
        TestHTTPProtocol.handler = { request in
            if request.url?.path == "/v1/sync" {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-bound-product-session")
                return (200, [:], try JSONEncoder().encode(snapshot))
            }
            XCTAssertEqual(request.url?.path, "/v1/pairings/pairing_1/complete")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            bodies.append(try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request)))
            if bodies.count == 1 { return (200, [:], try JSONEncoder().encode(PairingCompletion.pending(PairingCompletionPending(status: "pending", pairingId: "pairing_1", expiresAtMs: expiry)))) }
            if bodies.count == 2 { throw URLError(.timedOut) }
            return (200, [:], try JSONEncoder().encode(connected))
        }
        try await first.completePairing()
        XCTAssertEqual(first.pairingState, "pending_approval")
        XCTAssertTrue(credentials.accounts.isEmpty)
        do { try await first.completePairing(); XCTFail("Lost approved response must remain unknown") } catch PairingClientError.unconfirmed {}
        XCTAssertEqual(first.pairingState, "completion_unknown")
        let reopened = store(credentials, persistence)
        try await reopened.completePairing()
        reopened.stopSocket()
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(bodies[0], bodies[1]); XCTAssertEqual(bodies[1], bodies[2])
        XCTAssertEqual(credentials.accounts.count, 1)
        XCTAssertEqual(credentials.accounts.first?.token, auth.token)
        XCTAssertEqual(credentials.accounts.first?.deviceID, device.id)
        XCTAssertEqual(credentials.accounts.first?.sessionID, auth.session.id)
        XCTAssertNil(credentials.accounts.first?.sessionExpiresAtMs)
        XCTAssertNotNil(credentials.accounts.first?.installationID)
        XCTAssertNil(credentials.pending)
        XCTAssertEqual(reopened.deviceID, device.id)
        XCTAssertEqual(reopened.pairingState, "connected")
    }

    func testClusterMismatchNeverInstallsAuthority() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence(), expiry = deadline
        let store = store(credentials, persistence)
        try await installPreview(on: store, expiry: expiry)
        var wrong = claim(expiry); wrong.backendUrl = "https://another.example"
        TestHTTPProtocol.handler = { _ in (200, [:], try JSONEncoder().encode(wrong)) }
        do { try await store.requestPairing(deviceName: "My iPhone", appVersion: "1"); XCTFail("Reject a different cluster origin") } catch PairingClientError.wrongCluster {}
        XCTAssertTrue(credentials.accounts.isEmpty)
        XCTAssertNil(store.account)
        XCTAssertFalse(store.pairingError?.contains(claimToken) ?? true)
    }

    func testDeniedAndExpiredRemainExplicitWithoutSavedAccount() async throws {
        for status in ["denied", "expired"] {
            TestHTTPProtocol.requests = []
            let credentials = PairingCredentialStore(), persistence = persistence(), expiry = deadline
            let store = store(credentials, persistence)
            try await installPreview(on: store, expiry: expiry)
            let claimed = claim(expiry)
            TestHTTPProtocol.handler = { _ in (200, [:], try JSONEncoder().encode(claimed)) }
            try await store.requestPairing(deviceName: "My iPhone", appVersion: "1")
            let result = PairingCompletion.pending(PairingCompletionPending(status: status, pairingId: claimed.pairingId, expiresAtMs: expiry))
            TestHTTPProtocol.handler = { _ in (200, [:], try JSONEncoder().encode(result)) }
            do { try await store.completePairing(); XCTFail("Expected explicit terminal pairing state") } catch {}
            XCTAssertEqual(store.pairingState, status)
            XCTAssertTrue(credentials.accounts.isEmpty)
            XCTAssertEqual(TestHTTPProtocol.requests.count, 3)
            try store.cancelPairing()
            XCTAssertNil(credentials.pending)
        }
    }

    func testSavedAccountRestoresSelectionOfflineAndRevocationRequiresReconnect() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence()
        var snapshot = try snapshot()
        let events = try JSONDecoder().decode([RealtimeEvent].self, from: WireFixtures.events)
        guard let event = events.first(where: { $0.event == "conversation.upserted" }), case .conversationUpserted(let room) = event.payload else { return XCTFail("Missing conversation fixture") }
        snapshot.conversations = [room]
        let (auth, device) = auth(snapshot)
        let initial = store(credentials, persistence)
        let saved = try initial.saveAuthenticatedAccount(auth, baseURL: URL(string: origin)!, deviceID: device.id, installationID: "durable_installation")
        initial.account = saved; initial.snapshot = snapshot; initial.conversations = [room]; initial.selectedConversationID = room.id
        try initial.persistCache()
        XCTAssertEqual(try persistence.loadSelection(accountID: saved.id)?.botID, room.botIds.first)
        let reopened = store(credentials, persistence)
        TestHTTPProtocol.handler = { request in XCTAssertEqual(request.httpMethod, "GET"); throw URLError(.notConnectedToInternet) }
        do { try await reopened.restoreSavedAccount(); XCTFail("Expected offline sync error") } catch {}
        reopened.stopSocket()
        XCTAssertEqual(reopened.account, saved)
        XCTAssertEqual(reopened.deviceID, device.id)
        XCTAssertEqual(reopened.selectedConversationID, room.id)
        XCTAssertEqual(credentials.accounts.count, 1)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "LemonBot.installationID"), "durable_installation")
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (401, [:], Data(#"{"error":{"code":"unauthenticated","message":"Session revoked","requestId":"req_revoke","retrySafe":false}}"#.utf8))
        }
        do { try await reopened.refresh(); XCTFail("Revoked session must not reconnect") } catch {}
        XCTAssertEqual(reopened.connectionState, "reconnect_required")
        XCTAssertEqual(reopened.selectedConversationID, room.id)
        XCTAssertEqual(credentials.accounts.count, 1)
        XCTAssertNil(reopened.transport)
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testDesktopIssuanceLostReplyReconcilesOriginalNonceAtPublicOrigin() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence(), snapshot = try snapshot()
        let (auth, _) = auth(snapshot)
        let store = store(credentials, persistence)
        let saved = try store.saveAuthenticatedAccount(auth, baseURL: URL(string: "http://127.0.0.1:4080")!, deviceID: nil, installationID: nil)
        store.account = saved; store.transport = try HTTPTransport(baseURL: saved.baseURL, token: saved.token, session: TestHTTPProtocol.session()); store.connectionState = "online"
        let advertised = BotPreflightFixtures.origin
        let pairing = Pairing(id: "pairing_1", revision: 1, createdAtMs: 1, updatedAtMs: 1, workspaceId: snapshot.workspace.id, ownerUserId: snapshot.user.id, clusterName: "My desktop", backendUrl: advertised, status: "waiting", expiresAtMs: deadline)
        let issued = PairingIssued(pairing: pairing, pairUrl: link(backend: advertised, workspace: snapshot.workspace.id))
        var bodies: [JSONObject] = []
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: request.url?.path == "/v1/identity" ? snapshot.workspace.id : nil))
            }
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.path, "/v1/pairings")
            bodies.append(try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request)))
            if bodies.count == 1 { throw URLError(.timedOut) }
            return (200, [:], try JSONEncoder().encode(issued))
        }
        try await store.verifyOwnerPairingOrigin()
        do { try await store.createPairing(); XCTFail("Lost QR response must remain fenced") } catch ClientError.outcomeUnknown {}
        XCTAssertEqual(store.pendingIntents.count, 1)
        XCTAssertNil(store.pairingURL)
        try await store.reconcilePairingIssuance()
        XCTAssertEqual(bodies.count, 2); XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.pairingURL, issued.pairUrl)
        XCTAssertEqual(store.pairings.first?.backendUrl, advertised)
    }
}
