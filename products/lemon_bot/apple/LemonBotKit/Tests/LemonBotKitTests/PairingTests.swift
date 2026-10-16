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
    private func handle(_ action: @escaping (URLRequest) throws -> (Int, [String: String], Data)) {
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "product.example")
            if request.url?.path == "/v1/setup" || request.url?.path == "/v1/identity" {
                XCTAssertEqual(request.httpMethod, "GET")
                let identity = request.url?.path == "/v1/identity"
                if identity { XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-bound-product-session") }
                else { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")) }
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: identity ? "resource" : nil, overrides: ["publicUrl": self.origin]))
            }
            return try action(request)
        }
    }
    private func installPreview(on store: LemonBotStore, expiry: TimestampMs) async throws {
        let result = preview(expiry)
        handle { request in
            XCTAssertEqual(request.url?.path, "/v1/pairings/preview")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))
            XCTAssertEqual(body.keys.sorted(), ["pairCode", "workspaceId"])
            return (200, [:], try JSONEncoder().encode(result))
        }
        let requestCount = TestHTTPProtocol.requests.count
        try store.preparePairing(link())
        XCTAssertEqual(TestHTTPProtocol.requests.count, requestCount)
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
        for noncanonical in ["https://product.example/", "https://product.example:443", "https://PRODUCT.example", "https://127.1"] {
            XCTAssertThrowsError(try PairingLink.parse(link(backend: noncanonical)))
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
        handle { request in
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
        handle { _ in (200, [:], try JSONEncoder().encode(claimed)) }
        try await first.requestPairing(deviceName: "My iPhone", appVersion: "1")
        let snapshot = try snapshot(), (auth, device) = auth(snapshot)
        let connected = PairingCompletion.connected(PairingCompletionConnected(auth: auth, device: device))
        var bodies: [JSONObject] = []
        handle { request in
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
        XCTAssertEqual(credentials.accounts.first?.instanceID, "backend_1")
        XCTAssertNil(credentials.pending)
        XCTAssertEqual(reopened.deviceID, device.id)
        XCTAssertEqual(reopened.pairingState, "connected")
    }

    func testClusterMismatchNeverInstallsAuthority() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence(), expiry = deadline
        let store = store(credentials, persistence)
        try await installPreview(on: store, expiry: expiry)
        var wrong = claim(expiry); wrong.backendUrl = "https://another.example"
        handle { _ in (200, [:], try JSONEncoder().encode(wrong)) }
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
            handle { _ in (200, [:], try JSONEncoder().encode(claimed)) }
            try await store.requestPairing(deviceName: "My iPhone", appVersion: "1")
            let result = PairingCompletion.pending(PairingCompletionPending(status: status, pairingId: claimed.pairingId, expiresAtMs: expiry))
            handle { _ in (200, [:], try JSONEncoder().encode(result)) }
            do { try await store.completePairing(); XCTFail("Expected explicit terminal pairing state") } catch {}
            XCTAssertEqual(store.pairingState, status)
            XCTAssertTrue(credentials.accounts.isEmpty)
            XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 3)
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

    func testPublicDescriptorMismatchPreventsPreviewAndClaim() async throws {
        for changes in [["instanceId": "backend_B"], ["product": "operator"]] {
            let credentials = PairingCredentialStore()
            let client = store(credentials, persistence())
            try client.preparePairing(link())
            TestHTTPProtocol.requests = []
            TestHTTPProtocol.handler = { request in
                XCTAssertEqual(request.url?.path, "/v1/setup")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: changes))
            }
            do { try await client.previewPairing(); XCTFail("Foreign setup cannot authorize pairing") } catch {}
            XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/setup"])
            XCTAssertTrue(credentials.accounts.isEmpty)
        }
        let credentials = PairingCredentialStore()
        let client = store(credentials, persistence())
        try await installPreview(on: client, expiry: deadline)
        TestHTTPProtocol.requests = []
        TestHTTPProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["instanceId": "backend_B"]))
        }
        do { try await client.requestPairing(deviceName: "Phone", appVersion: "1"); XCTFail("Changed descriptor must prevent claim") } catch {}
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/setup"])
        XCTAssertTrue(credentials.accounts.isEmpty)
    }

    func testExpiredPreviewCannotSendClaim() async throws {
        let credentials = PairingCredentialStore()
        let client = store(credentials, persistence())
        try await installPreview(on: client, expiry: deadline)
        var record = try XCTUnwrap(client.pairingRecord)
        record.preview?.expiresAtMs = Date().timeIntervalSince1970 * 1000 - 1
        client.installPendingPairing(record)
        TestHTTPProtocol.requests = []
        handle { _ in XCTFail("Expired preview cannot claim"); throw URLError(.cancelled) }
        do { try await client.requestPairing(deviceName: "Phone", appVersion: "1"); XCTFail("Expiry must be explicit") } catch {}
        XCTAssertFalse(TestHTTPProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(client.pairingState, "expired")
        XCTAssertTrue(credentials.accounts.isEmpty)
    }

    func testPhoneObservationPredicate() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(PhonePairingProgress.shouldObserve(state: "pending_approval", expiresAtMs: 1_000_001, now: now))
        let expiries: [TimestampMs?] = [nil, 999_999, 1_000_000, .nan, .infinity]
        for expiry in expiries {
            XCTAssertFalse(PhonePairingProgress.shouldObserve(state: "pending_approval", expiresAtMs: expiry, now: now))
        }
        for state in ["preview_ready", "claim_unknown", "claiming", "completing", "completion_unknown", "connected", "denied", "expired"] {
            XCTAssertFalse(PhonePairingProgress.shouldObserve(state: state, expiresAtMs: 1_000_001, now: now))
        }
    }

    func testObservationUsesOneSavedNonceAndUnknownStopsAutomaticChecks() async throws {
        let credentials = PairingCredentialStore(), expiry = deadline
        let client = store(credentials, persistence())
        try await installPreview(on: client, expiry: expiry)
        let claimed = claim(expiry)
        handle { _ in (200, [:], try JSONEncoder().encode(claimed)) }
        try await client.requestPairing(deviceName: "Phone", appVersion: "1")
        let nonce = try XCTUnwrap(credentials.pending?.completionNonce)
        var bodies: [JSONObject] = []
        handle { request in
            XCTAssertEqual(request.url?.path, "/v1/pairings/pairing_1/complete")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))
            XCTAssertEqual(body["clientNonce"], .string(nonce))
            XCTAssertEqual(body.keys.sorted(), ["claimToken", "clientNonce"])
            bodies.append(body)
            if bodies.count == 2 { throw URLError(.timedOut) }
            return (200, [:], try JSONEncoder().encode(PairingCompletion.pending(PairingCompletionPending(status: "pending", pairingId: claimed.pairingId, expiresAtMs: expiry))))
        }
        try await client.observePhonePairing()
        XCTAssertEqual(bodies.count, 1)
        do { try await client.observePhonePairing(); XCTFail("Lost response stays unknown") } catch {}
        XCTAssertEqual(client.pairingState, "completion_unknown")
        let count = TestHTTPProtocol.requests.count
        do { try await client.observePhonePairing(); XCTFail("Unknown observation is fenced") } catch PairingClientError.notReady {}
        XCTAssertEqual(TestHTTPProtocol.requests.count, count)
        try await client.completePairing()
        XCTAssertEqual(bodies.count, 3)
        XCTAssertTrue(bodies.allSatisfy { $0 == bodies[0] })
        XCTAssertTrue(credentials.accounts.isEmpty)
    }

    func testCompletionIdentityMismatchNeverSavesAuthority() async throws {
        for changes in [["instanceId": "backend_B"], ["workspaceId": "workspace_B"]] {
            let credentials = PairingCredentialStore(), expiry = deadline
            let client = store(credentials, persistence())
            try await installPreview(on: client, expiry: expiry)
            let claimed = claim(expiry)
            handle { _ in (200, [:], try JSONEncoder().encode(claimed)) }
            try await client.requestPairing(deviceName: "Phone", appVersion: "1")
            let (auth, device) = auth(try snapshot())
            let connected = PairingCompletion.connected(PairingCompletionConnected(auth: auth, device: device))
            TestHTTPProtocol.requests = []
            TestHTTPProtocol.handler = { request in
                switch request.url?.path {
                case "/v1/setup":
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                    return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["publicUrl": self.origin]))
                case "/v1/pairings/pairing_1/complete":
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                    return (200, [:], try JSONEncoder().encode(connected))
                case "/v1/identity":
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(auth.token)")
                    return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: "resource", overrides: changes))
                default: XCTFail("Mismatch must prevent sync"); throw URLError(.cancelled)
                }
            }
            do { try await client.completePairing(); XCTFail("Foreign identity cannot be installed") } catch {}
            XCTAssertTrue(credentials.accounts.isEmpty)
            XCTAssertNil(client.account)
            XCTAssertNotNil(credentials.pending)
            XCTAssertEqual(TestHTTPProtocol.requests.last?.url?.path, "/v1/identity")
        }
    }

    func testTwoBackendOriginsCannotRetargetPendingQR() async throws {
        let credentials = PairingCredentialStore()
        let client = store(credentials, persistence())
        try client.preparePairing(link())
        let originalNonce = client.pairingRecord?.claimNonce
        let backendB = link(backend: "https://backend-b.example", workspace: "workspace_B").replacingOccurrences(of: "instance=backend_1", with: "instance=backend_B")
        XCTAssertThrowsError(try client.preparePairing(backendB))
        XCTAssertEqual(client.pairingRecord?.claimNonce, originalNonce)
        XCTAssertEqual(client.pendingPairing?.origin, origin)
        TestHTTPProtocol.requests = []
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "product.example")
            XCTAssertEqual(request.url?.path, "/v1/setup")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["instanceId": "backend_B", "publicUrl": "https://backend-b.example"]))
        }
        do { try await client.previewPairing(); XCTFail("QR A cannot authorize backend B") } catch {}
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertTrue(credentials.accounts.isEmpty)
        XCTAssertNil(client.account)
    }

    func testTwoBackendsKeepAccountsSeparateAndRejectForeignCompletion() async throws {
        let credentialsA = PairingCredentialStore(), credentialsB = PairingCredentialStore(), expiry = deadline
        let phoneA = store(credentialsA, persistence()), phoneB = store(credentialsB, persistence())
        let originB = "https://backend-b.example"
        var workspaceB = try snapshot(); workspaceB.workspace.id = "workspace_B"
        var (authB, deviceB) = auth(workspaceB); authB.token = "backend-b-device-session"
        let connectedB = PairingCompletion.connected(PairingCompletionConnected(auth: authB, device: deviceB))
        let qrB = link(backend: originB, workspace: workspaceB.workspace.id).replacingOccurrences(of: "instance=backend_1", with: "instance=backend_B")
        TestHTTPProtocol.handler = { request in
            let isB = request.url?.host == "backend-b.example"
            XCTAssertTrue(isB || request.url?.host == "product.example")
            let origin = isB ? originB : self.origin
            let instance = isB ? "backend_B" : "backend_1"
            switch request.url?.path {
            case "/v1/setup":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["instanceId": instance, "publicUrl": origin]))
            case "/v1/pairings/preview":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, [:], try JSONEncoder().encode(PairingPreviewResult(clusterName: isB ? "Desktop B" : "Desktop A", backendUrl: origin, expiresAtMs: expiry)))
            case "/v1/pairings/claim":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, [:], try JSONEncoder().encode(PairingClaimResult(pairingId: "pairing_1", claimToken: self.claimToken, verificationCode: "123456", expiresAtMs: expiry, clusterName: isB ? "Desktop B" : "Desktop A", backendUrl: origin)))
            case "/v1/pairings/pairing_1/complete":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                // Even a well-formed completion from the other real workspace is not QR A's authority.
                return (200, [:], try JSONEncoder().encode(connectedB))
            case "/v1/identity":
                XCTAssertTrue(isB, "Foreign workspace auth must never be sent to backend A")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer backend-b-device-session")
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: workspaceB.workspace.id, overrides: ["instanceId": instance, "publicUrl": origin]))
            case "/v1/sync":
                XCTAssertTrue(isB)
                return (200, [:], try JSONEncoder().encode(workspaceB))
            default: XCTFail("Unexpected product route"); throw URLError(.cancelled)
            }
        }
        try phoneA.preparePairing(link()); try phoneB.preparePairing(qrB)
        try await phoneA.previewPairing(); try await phoneB.previewPairing()
        try await phoneA.requestPairing(deviceName: "Phone A", appVersion: "1")
        try await phoneB.requestPairing(deviceName: "Phone B", appVersion: "1")
        do { try await phoneA.completePairing(); XCTFail("Backend B authority must not install for QR A") } catch PairingClientError.wrongCluster {}
        try await phoneB.observePhonePairing()
        phoneB.stopSocket()
        XCTAssertNil(phoneA.account)
        XCTAssertTrue(credentialsA.accounts.isEmpty)
        XCTAssertEqual(phoneB.account?.workspaceID, "workspace_B")
        XCTAssertEqual(credentialsB.accounts.first?.instanceID, "backend_B")
        XCTAssertEqual(credentialsB.accounts.count, 1)
        XCTAssertTrue(TestHTTPProtocol.requests.filter { $0.url?.host == "product.example" }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testPinnedRelaunchAndRefreshFailClosedWithoutReplayingFences() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence()
        let baseline = try snapshot(), (auth, device) = auth(baseline)
        let initial = store(credentials, persistence)
        var saved = try initial.saveAuthenticatedAccount(auth, baseURL: URL(string: origin)!, deviceID: device.id, installationID: "installation")
        saved.instanceID = "backend_1"
        try credentials.save(saved)
        initial.account = saved; initial.snapshot = baseline
        initial.pendingIntents = [MutationIntent(clientNonce: "fenced_message_nonce", method: "POST", path: "/conversations/resource/messages", state: "outcome_unknown"), MutationIntent(clientNonce: "fenced_approval_nonce", method: "POST", path: "/approvals/resource/resolve", state: "outcome_unknown")]
        try initial.persistCache()
        try persistence.saveMutationIntents(initial.pendingIntents, accountID: saved.id)
        let reopened = store(credentials, persistence)
        TestHTTPProtocol.requests = []
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url?.path {
            case "/v1/setup":
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["publicUrl": self.origin]))
            case "/v1/identity":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(auth.token)")
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: baseline.workspace.id, overrides: ["instanceId": "backend_B"]))
            default: XCTFail("Foreign identity must prevent sync and authority"); throw URLError(.cancelled)
            }
        }
        do { try await reopened.restoreSavedAccount(); XCTFail("Pinned restore must reject changed instance") } catch {}
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/setup", "/v1/identity"])
        XCTAssertEqual(reopened.connectionState, "reconnect_required")
        XCTAssertEqual(reopened.snapshot?.workspace.id, baseline.workspace.id)
        XCTAssertEqual(reopened.pendingIntents.map(\.clientNonce).sorted(), ["fenced_approval_nonce", "fenced_message_nonce"])
        XCTAssertNil(reopened.transport)
        TestHTTPProtocol.requests = []
        do { try await reopened.refresh(); XCTFail("Refresh must not bypass the pin") } catch {}
        XCTAssertFalse(TestHTTPProtocol.requests.contains { $0.httpMethod != "GET" || $0.url?.path == "/v1/sync" })
        XCTAssertEqual(reopened.pendingIntents.count, 2)
        XCTAssertEqual(credentials.accounts.first?.instanceID, "backend_1")
        reopened.stopSocket()
    }
    func testPinnedRelaunchAndNetworkRecoveryReadOnlyKeepSameWorkspaceAndFences() async throws {
        let credentials = PairingCredentialStore(), persistence = persistence()
        let baseline = try snapshot(), (auth, device) = auth(baseline)
        let initial = store(credentials, persistence)
        let saved = try initial.saveAuthenticatedAccount(auth, baseURL: URL(string: origin)!, deviceID: device.id, installationID: "installation", instanceID: "backend_1")
        initial.account = saved; initial.snapshot = baseline
        let fences = [MutationIntent(clientNonce: "message_nonce", method: "POST", path: "/conversations/resource/messages", state: "outcome_unknown"), MutationIntent(clientNonce: "approval_nonce", method: "POST", path: "/pairings/resource/approve", state: "outcome_unknown")]
        try initial.persistCache()
        try persistence.saveMutationIntents(fences, accountID: saved.id)
        let reopened = store(credentials, persistence)
        TestHTTPProtocol.requests = []
        handle { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/sync")
            return (200, [:], try JSONEncoder().encode(baseline))
        }
        try await reopened.restoreSavedAccount()
        reopened.stopSocket()
        XCTAssertEqual(reopened.account?.instanceID, "backend_1")
        XCTAssertEqual(reopened.workspace?.id, saved.workspaceID)
        XCTAssertEqual(reopened.pendingIntents, fences)
        XCTAssertEqual(Array(TestHTTPProtocol.requests.prefix(3)).map { $0.url!.path }, ["/v1/setup", "/v1/identity", "/v1/sync"])
        TestHTTPProtocol.handler = { request in XCTAssertEqual(request.httpMethod, "GET"); throw URLError(.networkConnectionLost) }
        do { try await reopened.refresh(); XCTFail("Network loss cannot report successful sync") } catch {}
        reopened.stopSocket()
        XCTAssertEqual(reopened.workspace?.id, saved.workspaceID)
        XCTAssertEqual(reopened.pendingIntents, fences)
        handle { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/v1/sync")
            return (200, [:], try JSONEncoder().encode(baseline))
        }
        try await reopened.refresh()
        reopened.stopSocket()
        XCTAssertEqual(reopened.workspace?.id, saved.workspaceID)
        XCTAssertEqual(reopened.pendingIntents, fences)
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(credentials.accounts.count, 1)
    }

    func testPinnedRestoreRecoversFromTransientPreflightWithoutMutationReplay() async throws {
        for status in [502, 503, 504] {
            for failedPath in ["/v1/setup", "/v1/identity"] {
                let credentials = PairingCredentialStore(), persistence = persistence()
                let baseline = try snapshot(), (auth, device) = auth(baseline)
                let initial = store(credentials, persistence)
                let saved = try initial.saveAuthenticatedAccount(auth, baseURL: URL(string: origin)!, deviceID: device.id, installationID: "installation", instanceID: "backend_1")
                initial.account = saved; initial.snapshot = baseline
                let fences = [MutationIntent(clientNonce: "message_nonce", method: "POST", path: "/conversations/resource/messages", state: "outcome_unknown"), MutationIntent(clientNonce: "approval_nonce", method: "POST", path: "/pairings/resource/approve", state: "outcome_unknown")]
                try initial.persistCache()
                try persistence.saveMutationIntents(fences, accountID: saved.id)
                let reopened = store(credentials, persistence)
                TestHTTPProtocol.requests = []
                TestHTTPProtocol.handler = { request in
                    XCTAssertEqual(request.httpMethod, "GET")
                    if request.url?.path == failedPath { return (status, ["Content-Type": "text/html"], Data()) }
                    XCTAssertEqual(request.url?.path, "/v1/setup")
                    return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["publicUrl": self.origin]))
                }
                do { try await reopened.restoreSavedAccount(); XCTFail("Outage must not report success") }
                catch { XCTAssertEqual(error as? BotPreflightError, .unavailable) }
                reopened.stopSocket()
                XCTAssertNotEqual(reopened.connectionState, "reconnect_required")
                XCTAssertNil(reopened.transport)
                XCTAssertFalse(TestHTTPProtocol.requests.contains { $0.url?.path == "/v1/sync" })
                if failedPath == "/v1/setup" {
                    XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
                }
                handle { request in
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(auth.token)")
                    XCTAssertEqual(request.url?.path, "/v1/sync")
                    return (200, [:], try JSONEncoder().encode(baseline))
                }
                try await reopened.refresh()
                reopened.stopSocket()
                XCTAssertEqual(reopened.account?.token, saved.token)
                XCTAssertEqual(reopened.workspace?.id, saved.workspaceID)
                XCTAssertEqual(reopened.pendingIntents, fences)
                XCTAssertEqual(credentials.accounts.count, 1)
                XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
            }
        }
    }

    func testSocketReconnectRetriesTransientPreflightWithExistingCredential() async throws {
        for status in [502, 503, 504] {
            for failedPath in ["/v1/setup", "/v1/identity"] {
                let credentials = PairingCredentialStore()
                let client = store(credentials, persistence())
                let baseline = try snapshot(), (auth, device) = auth(baseline)
                let saved = try client.saveAuthenticatedAccount(auth, baseURL: URL(string: origin)!, deviceID: device.id, installationID: "installation", instanceID: "backend_1")
                client.account = saved; client.snapshot = baseline
                let fences = [MutationIntent(clientNonce: "socket_nonce", method: "POST", path: "/pairings/resource/approve", state: "outcome_unknown")]
                client.pendingIntents = fences
                let recovered = expectation(description: "Socket retries identity after HTTP \(status) at \(failedPath)")
                var failed = false
                var signalled = false
                TestHTTPProtocol.requests = []
                TestHTTPProtocol.handler = { request in
                    XCTAssertEqual(request.httpMethod, "GET")
                    let path = request.url!.path
                    if path == "/v1/realtime" {
                        XCTAssertTrue(signalled, "Socket must wait for successful identity preflight")
                        throw URLError(.networkConnectionLost)
                    }
                    if path == failedPath && !failed {
                        failed = true
                        return (status, ["Content-Type": "text/html"], Data())
                    }
                    if path == "/v1/setup" {
                        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                        return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["publicUrl": self.origin]))
                    }
                    XCTAssertEqual(path, "/v1/identity")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(saved.token)")
                    if failed && !signalled { signalled = true; recovered.fulfill() }
                    return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: baseline.workspace.id, overrides: ["publicUrl": self.origin]))
                }
                client.startSocket()
                await fulfillment(of: [recovered], timeout: 8)
                // Let the successful identity response install the verified transport.
                for _ in 0..<100 where client.transport == nil {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                client.stopSocket()
                XCTAssertNotNil(client.transport)
                XCTAssertNotEqual(client.connectionState, "reconnect_required")
                XCTAssertEqual(client.account?.token, saved.token)
                XCTAssertEqual(client.pendingIntents, fences)
                XCTAssertEqual(credentials.accounts.count, 1)
                XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
                XCTAssertGreaterThanOrEqual(TestHTTPProtocol.requests.filter { $0.url?.path == failedPath }.count, 2)
            }
        }
    }

    func testTerminalExpiryStopsObservation() async throws {
        let credentials = PairingCredentialStore(), expiry = deadline
        let client = store(credentials, persistence())
        try await installPreview(on: client, expiry: expiry)
        let claimed = claim(expiry)
        handle { _ in (200, [:], try JSONEncoder().encode(claimed)) }
        try await client.requestPairing(deviceName: "Phone", appVersion: "1")
        handle { request in
            XCTAssertEqual(request.url?.path, "/v1/pairings/pairing_1/complete")
            return (200, [:], try JSONEncoder().encode(PairingCompletion.pending(PairingCompletionPending(status: "expired", pairingId: claimed.pairingId, expiresAtMs: expiry))))
        }
        do { try await client.observePhonePairing(); XCTFail("Expiry must remain explicit") } catch {}
        XCTAssertEqual(client.pairingState, "expired")
        let count = TestHTTPProtocol.requests.count
        do { try await client.observePhonePairing(); XCTFail("Terminal observation is fenced") } catch PairingClientError.notReady {}
        XCTAssertEqual(TestHTTPProtocol.requests.count, count)
        XCTAssertTrue(credentials.accounts.isEmpty)
    }

    func testSocketIdentityFenceRejectsRevokedPhoneWithoutMutationReplay() async throws {
        let credentials = PairingCredentialStore()
        let client = store(credentials, persistence())
        let baseline = try snapshot(), (auth, device) = auth(baseline)
        var saved = try client.saveAuthenticatedAccount(auth, baseURL: URL(string: origin)!, deviceID: device.id, installationID: "installation")
        saved.instanceID = "backend_1"
        try credentials.save(saved)
        client.account = saved
        client.snapshot = baseline
        client.pendingIntents = [MutationIntent(clientNonce: "socket_fenced_nonce", method: "POST", path: "/approvals/resource/resolve", state: "outcome_unknown")]
        client.transport = try HTTPTransport(baseURL: saved.baseURL, token: saved.token, session: TestHTTPProtocol.session())
        TestHTTPProtocol.requests = []
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/v1/setup" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["publicUrl": self.origin]))
            }
            XCTAssertEqual(request.url?.path, "/v1/identity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(auth.token)")
            return (401, ["Content-Type": "application/json"], Data(#"{"error":{"code":"unauthenticated","message":"Session revoked","requestId":"revoked_phone","retrySafe":false}}"#.utf8))
        }
        client.startSocket()
        let reconnect = try XCTUnwrap(client.socketTask)
        await reconnect.value
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/setup", "/v1/identity"])
        XCTAssertEqual(client.connectionState, "reconnect_required")
        XCTAssertNil(client.transport)
        XCTAssertEqual(client.snapshot?.workspace.id, baseline.workspace.id)
        XCTAssertEqual(client.pendingIntents.map(\.clientNonce), ["socket_fenced_nonce"])
        XCTAssertEqual(credentials.accounts.first?.instanceID, "backend_1")
    }
}
