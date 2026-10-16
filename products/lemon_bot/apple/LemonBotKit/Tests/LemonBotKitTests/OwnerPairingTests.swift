import XCTest
import Foundation
@testable import LemonBotKit

private final class OwnerPairingCredentials: AccountCredentialStore {
    var accounts: [StoredAccount] = []
    func load() throws -> [StoredAccount] { accounts }
    func save(_ account: StoredAccount) throws { accounts.removeAll { $0.id == account.id }; accounts.append(account) }
    func remove(_ id: String) throws { accounts.removeAll { $0.id == id } }
    func loadPendingPairing() throws -> PendingDevicePairing? { nil }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws {}
    func removePendingPairing() throws {}
}

@MainActor final class OwnerPairingTests: XCTestCase {
    override func setUp() { TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil }
    override func tearDown() { TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
    private func store(origin: String = "http://127.0.0.1:4080", instanceID: String? = nil) throws -> (LemonBotStore, OwnerPairingCredentials) {
        let credentials = OwnerPairingCredentials()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = LemonBotStore(keychain: credentials, persistence: ClientPersistence(root: root))
        let account = StoredAccount(id: "account_1", baseURL: try HTTPTransport.normalizeBaseURL(URL(string: origin)!), email: "owner@example.org", displayName: "Owner", token: "owner-product-session", userID: "owner_1", workspaceID: "workspace_1", instanceID: instanceID)
        try credentials.save(account)
        store.account = account; store.accounts = [account]; store.connectionState = "online"
        store.httpSession = TestHTTPProtocol.session()
        store.transport = try HTTPTransport(baseURL: account.baseURL, token: account.token, session: store.httpSession)
        return (store, credentials)
    }
    private func pairing(status: String = "waiting", expiresAt: Double = Date().timeIntervalSince1970 * 1000 + 240_000) -> Pairing {
        Pairing(id: "pairing_1", revision: 1, createdAtMs: 1, updatedAtMs: 1, workspaceId: "workspace_1", ownerUserId: "owner_1", clusterName: "Existing workspace", backendUrl: BotPreflightFixtures.origin, status: status, expiresAtMs: expiresAt, deviceName: status == "pending_approval" ? "My iPhone" : nil, verificationCode: status == "pending_approval" ? "123456" : nil)
    }
    private func descriptorResponse(_ request: URLRequest, overrides: [String: Any] = [:]) throws -> (Int, [String: String], Data) {
        (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: request.url?.path == "/v1/identity" ? "workspace_1" : nil, overrides: overrides))
    }
    func testConfiguredBackendResolvesExactTailnetOriginAndPinsIdentityBeforeIssuance() async throws {
        let (store, credentials) = try store()
        TestHTTPProtocol.handler = { request in try self.descriptorResponse(request) }
        try await store.verifyOwnerPairingOrigin()
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url?.host }, ["127.0.0.1", "desktop.example.ts.net", "desktop.example.ts.net"])
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url?.path }, ["/v1/identity", "/v1/setup", "/v1/identity"])
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(store.ownerPairingPreflight?.origin, BotPreflightFixtures.origin)
        XCTAssertEqual(credentials.accounts.first?.instanceID, "backend_1")
        XCTAssertEqual(store.account?.baseURL.host, "127.0.0.1")
        XCTAssertNil(store.pairingURL)
    }
    func testNoQRMutationBeforeReadiness() async throws {
        let (store, _) = try store()
        do { try await store.createPairing(); XCTFail("Readiness must precede QR") } catch PairingClientError.notReady {}
        XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
    }
    func testRemoteBackendIsNeverReplacedOrProbedLocally() async throws {
        let (store, credentials) = try store(origin: "https://remote.example.ts.net")
        let original = store.account
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "remote.example.ts.net")
            throw URLError(.cannotConnectToHost)
        }
        do { try await store.verifyOwnerPairingOrigin(); XCTFail("Unavailable remote is not local setup") } catch { XCTAssertEqual(error as? BotPreflightError, .unavailable) }
        XCTAssertEqual(store.account, original)
        XCTAssertEqual(credentials.accounts, [try XCTUnwrap(original)])
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    func testLoopbackWrongServiceAndDifferentWorkspaceBlockQR() async throws {
        for (overrides, expected) in [(["publicUrl": "https://127.0.0.1"], BotPreflightError.loopbackOrigin), (["product": "lemon_web"], .wrongService), (["workspaceId": "workspace_2"], .workspaceMismatch)] {
            TestHTTPProtocol.requests = []
            let (store, _) = try store()
            TestHTTPProtocol.handler = { request in try self.descriptorResponse(request, overrides: overrides) }
            do { try await store.verifyOwnerPairingOrigin(); XCTFail("Wrong backend must fail closed") } catch { XCTAssertEqual(error as? BotPreflightError, expected) }
            XCTAssertNil(store.ownerPairingPreflight)
            XCTAssertNil(store.pairingURL)
            XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        }
    }
    func testChangedIdentityAfterVerificationBlocksIssuanceAndApproval() async throws {
        let (store, _) = try store()
        TestHTTPProtocol.handler = { request in try self.descriptorResponse(request) }
        try await store.verifyOwnerPairingOrigin()
        TestHTTPProtocol.handler = { request in try self.descriptorResponse(request, overrides: ["instanceId": "replacement_backend"]) }
        do { try await store.createPairing(); XCTFail("Changed backend must not issue QR") } catch { XCTAssertEqual(error as? BotPreflightError, .instanceMismatch) }
        XCTAssertNil(store.ownerPairingPreflight)
        do { try await store.approvePairing(pairing(status: "pending_approval")); XCTFail("Readiness was invalidated") } catch PairingClientError.notReady {}
        XCTAssertTrue(TestHTTPProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
        XCTAssertEqual(store.account?.instanceID, "backend_1")
    }
    func testCandidateCannotOverrideAdvertisedOriginOrUseNonTailnet() async throws {
        let (store, _) = try store()
        TestHTTPProtocol.handler = { request in try self.descriptorResponse(request) }
        do { try await store.verifyOwnerPairingOrigin("https://other.example.ts.net"); XCTFail("QR would advertise a different origin") } catch { XCTAssertEqual(error as? BotPreflightError, .invalidOrigin) }
        TestHTTPProtocol.handler = { request in try self.descriptorResponse(request, overrides: ["publicUrl": "https://product.example.org"]) }
        do { try await store.verifyOwnerPairingOrigin(); XCTFail("Guided journey requires Tailscale HTTPS") } catch { XCTAssertEqual(error as? BotPreflightError, .tailscaleRequired) }
    }
    func testExplicitApprovalUsesExactCodeAndRevisionThenReadsCompletionWithoutReplay() async throws {
        let (store, _) = try store()
        var request = pairing(status: "pending_approval"), approvalCount = 0
        TestHTTPProtocol.handler = { incoming in
            if incoming.url?.path == "/v1/pairings/pairing_1/approve" {
                approvalCount += 1
                let body = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(incoming))
                XCTAssertEqual(body["verificationCode"], .string("123456")); XCTAssertEqual(body["revision"], .number(1))
                request.status = "approved"; request.revision = 2
                return (200, [:], try JSONEncoder().encode(request))
            }
            if incoming.url?.path == "/v1/pairings" { return (200, [:], try JSONEncoder().encode(["waiting", "pending_approval"].contains(request.status) ? [request] : [])) }
            if incoming.url?.path == "/v1/pairings/pairing_1" { return (200, [:], try JSONEncoder().encode(request)) }
            return try self.descriptorResponse(incoming)
        }
        try await store.verifyOwnerPairingOrigin()
        try await store.refreshOwnerPairingStatus()
        XCTAssertEqual(approvalCount, 0)
        try await store.approvePairing(request)
        XCTAssertEqual(store.pairings.first?.status, "approved")
        try await store.refreshOwnerPairingStatus()
        XCTAssertEqual(store.pairings.first?.status, "approved")
        XCTAssertTrue(OwnerPairingProgress.shouldObserve(store.pairings))
        request.status = "consumed"; request.revision = 3
        try await store.refreshOwnerPairingStatus()
        XCTAssertEqual(store.pairings.first?.status, "consumed")
        try await store.refreshOwnerPairingStatus()
        XCTAssertEqual(store.pairings.first?.status, "consumed")
        XCTAssertEqual(approvalCount, 1)
        XCTAssertFalse(OwnerPairingProgress.shouldObserve(store.pairings))
    }
    func testLostApprovalReplyReconcilesReadOnlyWithoutApprovingTwice() async throws {
        let (store, _) = try store()
        var request = pairing(status: "pending_approval"), approvalCount = 0
        TestHTTPProtocol.handler = { incoming in
            if incoming.url?.path == "/v1/pairings/pairing_1/approve" {
                approvalCount += 1; request.status = "approved"; request.revision = 2
                throw URLError(.timedOut)
            }
            if incoming.url?.path == "/v1/pairings" { return (200, [:], try JSONEncoder().encode([Pairing]())) }
            if incoming.url?.path == "/v1/pairings/pairing_1" { return (200, [:], try JSONEncoder().encode(request)) }
            return try self.descriptorResponse(incoming)
        }
        try await store.verifyOwnerPairingOrigin()
        do { try await store.approvePairing(request); XCTFail("Lost receipt must stay fenced") } catch ClientError.outcomeUnknown {}
        XCTAssertEqual(store.pendingIntents.count, 1)
        try await store.refreshOwnerPairingStatus()
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(approvalCount, 1)
        XCTAssertEqual(store.pairings.first?.status, "approved")
    }
    func testFailedReadinessHidesButRetainsOriginalQRForExplicitRecovery() async throws {
        let (store, _) = try store()
        var parts = URLComponents()
        parts.scheme = "lemonbot"; parts.host = "pair"
        parts.queryItems = [URLQueryItem(name: "backend", value: BotPreflightFixtures.origin), URLQueryItem(name: "instance", value: "backend_1"), URLQueryItem(name: "cluster", value: "workspace_1"), URLQueryItem(name: "code", value: String(repeating: "A", count: 43))]
        let issued = PairingIssued(pairing: pairing(), pairUrl: try XCTUnwrap(parts.string))
        var issuanceCount = 0
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "POST" {
                issuanceCount += 1
                return (200, [:], try JSONEncoder().encode(issued))
            }
            return try self.descriptorResponse(request)
        }
        try await store.verifyOwnerPairingOrigin()
        try await store.createPairing()
        let originalLink = store.pairingURL
        TestHTTPProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { try await store.refreshOwnerPairingStatus(); XCTFail("Offline readiness must be hidden") } catch {}
        XCTAssertNil(store.ownerPairingPreflight)
        XCTAssertEqual(store.pairingURL, originalLink)
        TestHTTPProtocol.handler = { request in try self.descriptorResponse(request) }
        try await store.verifyOwnerPairingOrigin()
        XCTAssertNotNil(store.ownerPairingPreflight)
        XCTAssertEqual(store.pairingURL, originalLink)
        XCTAssertEqual(issuanceCount, 1)
    }
    func testObservationStopsAtOriginalExpiryAndTerminalStates() {
        for status in ["waiting", "pending_approval", "approved"] {
            XCTAssertTrue(OwnerPairingProgress.shouldObserve([pairing(status: status)]))
            XCTAssertFalse(OwnerPairingProgress.shouldObserve([pairing(status: status, expiresAt: 1)]))
        }
        for status in ["consumed", "denied", "expired"] { XCTAssertFalse(OwnerPairingProgress.shouldObserve([pairing(status: status)])) }
    }
    func testLegacyStoredAccountDecodesWithoutAnIdentityPin() throws {
        let (store, _) = try store()
        let encoded = try JSONEncoder().encode(try XCTUnwrap(store.account))
        let decoded = try JSONDecoder().decode(StoredAccount.self, from: encoded)
        XCTAssertNil(decoded.instanceID)
        XCTAssertEqual(decoded, store.account)
    }
}
