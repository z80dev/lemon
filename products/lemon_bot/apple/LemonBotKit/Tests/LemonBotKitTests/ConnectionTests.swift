import Foundation
import XCTest
@testable import LemonBotKit

private final class ConnectionCredentials: AccountCredentialStore {
    var accounts: [StoredAccount] = []
    func load() throws -> [StoredAccount] { accounts }
    func save(_ account: StoredAccount) throws { accounts.append(account) }
    func remove(_ id: String) throws { accounts.removeAll { $0.id == id } }
    func loadPendingPairing() throws -> PendingDevicePairing? { nil }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws {}
    func removePendingPairing() throws {}
}

@MainActor final class ConnectionTests: XCTestCase {
    private func store() throws -> LemonBotStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let value = LemonBotStore(keychain: ConnectionCredentials(), persistence: ClientPersistence(root: root))
        value.account = StoredAccount(id: "connection-test", baseURL: URL(string: "https://product.example/v1")!, email: "member@example.org", displayName: "Member", token: "session", userID: "resource", workspaceID: "resource")
        value.httpSession = TestHTTPProtocol.session()
        value.transport = try HTTPTransport(baseURL: value.account!.baseURL, token: "session", session: value.httpSession)
        TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil
        addTeardownBlock { @MainActor in value.stopSocket(); TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = []; try? FileManager.default.removeItem(at: root) }
        return value
    }
    func testURLFailureClassificationsPreserveTargetTimeAndDetails() throws {
        let url = URL(string: "http://127.0.0.1:4080/v1")!, now = Date(timeIntervalSince1970: 123), retry = Date(timeIntervalSince1970: 135)
        let cases: [(URLError.Code, ConnectionIssue.Layer, String)] = [
            (.cannotConnectToHost, .backendUnreachable, "Nothing is answering at 127.0.0.1:4080"),
            (.cannotFindHost, .backendUnreachable, "couldn’t be found"), (.dnsLookupFailed, .backendUnreachable, "couldn’t be found"),
            (.timedOut, .backendUnreachable, "too long"), (.notConnectedToInternet, .offlineDevice, "network connection"),
            (.networkConnectionLost, .offlineDevice, "network connection"), (.secureConnectionFailed, .backendUnreachable, "certificate"),
            (.serverCertificateUntrusted, .backendUnreachable, "certificate"), (.serverCertificateHasBadDate, .backendUnreachable, "certificate"),
            (.appTransportSecurityRequiresSecureConnection, .backendUnreachable, "requires HTTPS")
        ]
        for (code, layer, reason) in cases {
            let issue = ConnectionIssue.classify(URLError(code), baseURL: url, email: "owner@example.org", at: now, nextRetryAt: retry)
            XCTAssertEqual(issue.layer, layer); XCTAssertTrue(issue.reason.contains(reason), issue.reason)
            XCTAssertEqual(issue.origin, "http://127.0.0.1:4080"); XCTAssertEqual(issue.email, "owner@example.org")
            XCTAssertEqual(issue.lastAttemptAt, now); XCTAssertEqual(issue.nextRetryAt, retry); XCTAssertFalse(issue.detail.isEmpty)
        }
        XCTAssertTrue(ConnectionIssue.isLoopback(url)); XCTAssertFalse(ConnectionIssue.isLoopback(URL(string: "https://desktop.tailnet.ts.net")!))
    }
    func testHTTPFailuresAreNotMisreportedAsLocalServiceMissing() throws {
        let url = URL(string: "https://desktop.tailnet.ts.net")!
        for status in [500, 502, 503, 504] {
            let issue = ConnectionIssue.classify(ClientError.http(status), baseURL: url)
            XCTAssertEqual(issue.layer, .backendError(status)); XCTAssertFalse(issue.reason.contains("isn’t running"))
        }
        XCTAssertTrue(ConnectionIssue.classify(ClientError.http(502), baseURL: url).reason.contains("proxy"))
        XCTAssertEqual(ConnectionIssue.classify(ClientError.http(401), baseURL: url).layer, .signedOutOrRevoked)
    }
    func testRefreshRecordsTransportFailureAndRetryNowReadsImmediately() async throws {
        let value = try store()
        TestHTTPProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do { try await value.refresh(); XCTFail("Expected failure") } catch {}
        value.stopSocket()
        XCTAssertEqual(value.connectionIssue?.layer, .backendUnreachable)
        XCTAssertNotNil(value.lastConnectionAttemptAt)
        value.nextRetryAt = Date().addingTimeInterval(30)
        TestHTTPProtocol.requests = []
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        snapshot.hasMore.bots = false; snapshot.hasMore.machines = false; snapshot.hasMore.conversations = false; snapshot.hasMore.notifications = false
        let data = try JSONEncoder().encode(snapshot)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/sync")
            return (200, [:], data)
        }
        try await value.retryNow()
        value.stopSocket()
        XCTAssertNil(value.nextRetryAt); XCTAssertNil(value.connectionIssue)
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.url?.path == "/v1/sync" }.count, 1)
    }
    func testControllerDownAfterSuccessfulSyncFetchesOwnerDiagnostics() async throws {
        let value = try store()
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        snapshot.capabilities.controlConnected = false; snapshot.member.role = "owner"
        snapshot.hasMore.bots = false; snapshot.hasMore.machines = false; snapshot.hasMore.conversations = false; snapshot.hasMore.notifications = false
        let data = try JSONEncoder().encode(snapshot)
        let status = Data(#"{"measuredAtMs":1,"backend":{"version":"0.1.0","apiVersion":1,"startedAtMs":1,"publicUrl":"https://product.example"},"controller":{"url":"ws://127.0.0.1:4040/ws","state":"rejected","connectedAtMs":null,"lastDisconnectedAtMs":1,"lastError":{"code":"auth_rejected","message":"Controller refused the backend credential.","atMs":1},"nextRetryAtMs":null,"methodCount":0},"lemon":null,"lemonUnavailableReason":"Controller disconnected","runtime":{"actions":["start","stop","restart"],"via":"launcher","reason":null,"operation":null}}"#.utf8)
        TestHTTPProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/sync": return (200, [:], data)
            case "/v1/instance": return (200, [:], status)
            default: throw URLError(.badURL)
            }
        }
        try await value.synchronize()
        XCTAssertEqual(value.connectionIssue?.layer, .controllerDown)
        XCTAssertEqual(value.instanceStatus?.controller.state, .rejected)
        XCTAssertTrue(value.canControlInstance)
        XCTAssertTrue(value.connectionIssue?.detail.contains("auth_rejected") == true)
        snapshot.member.role = "member"
        let memberData = try JSONEncoder().encode(snapshot)
        TestHTTPProtocol.requests = []
        TestHTTPProtocol.handler = { _ in (200, [:], memberData) }
        value.instanceStatus = nil
        try await value.synchronize()
        XCTAssertEqual(value.connectionIssue?.layer, .controllerDown)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
        XCTAssertFalse(value.canViewInstance)
    }
    func testRevokedDeviceKeepsExplicitSignInIssue() throws {
        let value = try store()
        value.markReconnectRequired()
        XCTAssertEqual(value.connectionState, "reconnect_required")
        XCTAssertEqual(value.connectionIssue?.layer, .signedOutOrRevoked)
        XCTAssertNil(value.nextRetryAt)
    }
    func testRuntimeActionsUseJournalAndRequireDestructiveConfirmation() async throws {
        let value = try store()
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        snapshot.member.role = "owner"; value.member = snapshot.member
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var instance = try JSONDecoder().decode(InstanceStatus.self, from: Data(contentsOf: kit.appendingPathComponent("../../sdk/ts/test/fixtures/instance-status.json").standardizedFileURL))
        instance.runtime.actions = [.start, .stop, .restart]; value.instanceStatus = instance; value.connectionState = "online"
        TestHTTPProtocol.handler = { request in
            let body = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))
            XCTAssertEqual(request.url?.path, "/v1/instance/runtime/restart")
            XCTAssertEqual(body["confirm"], .bool(true)); XCTAssertNotNil(body["clientNonce"]?.stringValue)
            return (202, [:], Data(#"{"id":"operation","action":"restart","state":"running","startedAtMs":1,"completedAtMs":null,"exitCode":null,"output":"Starting…"}"#.utf8))
        }
        do { try await value.performRuntimeAction(.restart); XCTFail("Expected confirmation requirement") } catch {}
        XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
        try await value.performRuntimeAction(.restart, confirmed: true)
        XCTAssertEqual(value.instanceStatus?.runtime.operation?.state, .running)
        XCTAssertTrue(value.pendingIntents.isEmpty)
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        do { try await value.performRuntimeAction(.start); XCTFail("Expected uncertain response") } catch ClientError.outcomeUnknown {}
        XCTAssertEqual(value.pendingIntents.count, 1)
        let nonce = try XCTUnwrap(value.pendingIntents.first?.clientNonce)
        let count = TestHTTPProtocol.requests.count
        do { try await value.performRuntimeAction(.start); XCTFail("Must not create a second start intent") } catch ClientError.unresolvedMutation(let intent) { XCTAssertEqual(intent.clientNonce, nonce) }
        XCTAssertEqual(TestHTTPProtocol.requests.count, count)
    }
    func testRuntimePollingObservesReceiptAndRefreshesWithoutReplayingCommands() async throws {
        let value = try store()
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        snapshot.hasMore.bots = false; snapshot.hasMore.machines = false; snapshot.hasMore.conversations = false; snapshot.hasMore.notifications = false
        let sync = try JSONEncoder().encode(snapshot)
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var instance = try JSONDecoder().decode(InstanceStatus.self, from: Data(contentsOf: kit.appendingPathComponent("../../sdk/ts/test/fixtures/instance-status.json").standardizedFileURL))
        instance.runtime.operation = try JSONDecoder().decode(RuntimeOperation.self, from: Data(#"{"id":"operation","action":"restart","state":"running","startedAtMs":1,"completedAtMs":null,"exitCode":null,"output":"Starting…"}"#.utf8))
        value.instanceStatus = instance
        instance.runtime.operation?.state = .succeeded
        instance.runtime.operation?.completedAtMs = 2
        instance.runtime.operation?.exitCode = 0
        instance.runtime.operation?.output = "Lemon is running."
        let completed = try JSONEncoder().encode(instance)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/v1/instance" { return (200, [:], completed) }
            XCTAssertEqual(request.url?.path, "/v1/sync")
            return (200, [:], sync)
        }
        try await value.waitForRuntimeOperation()
        value.stopSocket()
        XCTAssertEqual(value.instanceStatus?.runtime.operation?.state, .succeeded)
        XCTAssertEqual(value.instanceStatus?.runtime.operation?.output, "Lemon is running.")
        XCTAssertEqual(TestHTTPProtocol.requests.map { $0.url!.path }, ["/v1/instance", "/v1/sync"])
        XCTAssertTrue(value.pendingIntents.isEmpty)
    }
    func testInstanceRoleCeilingsKeepAdminReadOnlyAndMembersOut() throws {
        let value = try store()
        value.member = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot).member
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        value.instanceStatus = try JSONDecoder().decode(InstanceStatus.self, from: Data(contentsOf: kit.appendingPathComponent("../../sdk/ts/test/fixtures/instance-status.json").standardizedFileURL))
        value.instanceStatus?.runtime.actions = [.start, .stop, .restart]
        value.member?.role = "owner"
        XCTAssertTrue(value.canViewInstance); XCTAssertTrue(value.canControlInstance)
        value.member?.role = "admin"
        XCTAssertTrue(value.canViewInstance); XCTAssertFalse(value.canControlInstance)
        value.member?.role = "member"
        XCTAssertFalse(value.canViewInstance); XCTAssertFalse(value.canControlInstance)
    }
    func testDiscoveryUsesOnlyPublicSetupWithShortTimeoutAndDeduplicatesOrigins() async throws {
        let value = try store()
        value.accounts = [value.account!, value.account!]
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/setup"); XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertEqual(request.timeoutInterval, 2)
            if request.url?.host == "localhost" { throw URLError(.timedOut) }
            return (200, [:], Data(#"{"setupRequired":false,"version":"0.1.0","apiVersion":1}"#.utf8))
        }
        let found = await value.discoverBackends()
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(Set(found.map { $0.baseURL.host! }), ["product.example", "127.0.0.1"])
        XCTAssertTrue(found.allSatisfy { $0.version == "0.1.0" && !$0.setupRequired })
    }
}
