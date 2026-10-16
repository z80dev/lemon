import XCTest
import Foundation
@testable import LemonBotKit
import LemonBotUI

// MOCK TRANSPORT ONLY: these tests never contact a provider or alter real configuration.
private final class ProviderMockCredentials: AccountCredentialStore {
    var accounts: [StoredAccount] = []
    func load() throws -> [StoredAccount] { accounts }
    func save(_ account: StoredAccount) throws { accounts = [account] }
    func remove(_ id: String) throws { accounts.removeAll { $0.id == id } }
    func loadPendingPairing() throws -> PendingDevicePairing? { nil }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws {}
    func removePendingPairing() throws {}
}

// A controllable mock response allows account/target changes while a write is in flight.
private final class ProviderDelayedMockProtocol: URLProtocol {
    static var handler: ((URLRequest, @escaping (Int, Data) -> Void) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request) { [weak self] status, data in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@MainActor final class ProviderSettingsMockTests: XCTestCase {
    private func saved(_ id: String = "mock-account") -> StoredAccount {
        StoredAccount(id: id, baseURL: URL(string: "https://mock-product.example/v1")!, email: "mock@example.org", displayName: "Mock Owner", token: "mock-product-session", userID: "resource", workspaceID: "resource", sessionID: "mock-session")
    }
    private func inventory(nodeID: String? = nil, targetID: String = "mock-controller") -> ProviderManagement {
        ProviderManagement(target: .init(id: targetID, nodeId: nodeID, hostname: "mock-host"), default: .init(providerId: "anthropic", modelId: "mock-existing-model"), providers: [
            .init(id: "anthropic", displayName: "Mock Anthropic", methods: [.apiKey], configured: true, status: .configured, lastValidation: .init(atMs: 1234, ready: false), environmentOverrides: ["ANTHROPIC_API_KEY"], configurationOverrides: [.credentialPool]),
            .init(id: "openai_codex", displayName: "Mock Codex", methods: [.deviceCode], configured: false, status: .needsLogin),
            .init(id: "unsupported", displayName: "Mock unsupported", methods: [.unsupported], configured: false, status: .expired)
        ])
    }
    private func makeStore() throws -> (LemonBotStore, ClientPersistence) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let persistence = ClientPersistence(root: root)
        let store = LemonBotStore(keychain: ProviderMockCredentials(), persistence: persistence)
        store.account = saved()
        var snapshot = try JSONDecoder().decode(Snapshot.self, from: WireFixtures.snapshot)
        snapshot.member.role = "owner"
        store.member = snapshot.member; store.workspace = snapshot.workspace
        store.transport = try HTTPTransport(baseURL: saved().baseURL, token: saved().token, session: TestHTTPProtocol.session())
        store.connectionState = "online"
        store.providerSettings.management = inventory()
        store.providerSettings.setPresentation(visible: true, active: true)
        TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil
        addTeardownBlock { TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil; ProviderDelayedMockProtocol.handler = nil }
        return (store, persistence)
    }
    nonisolated private func deviceData(loginID: String, targetID: String = "mock-controller", status: String = "pending", expiry: Double? = nil, interval: Double = 1000, url: String = "https://auth.openai.com/codex/device") throws -> Data {
        var object: JSONObject = ["loginId": .string(loginID), "targetId": .string(targetID), "providerId": .string("openai_codex"), "status": .string(status), "verificationUrl": .null, "userCode": .null, "expiresAtMs": .null, "pollIntervalMs": .null]
        if status == "pending" {
            object["verificationUrl"] = .string(url); object["userCode"] = .string("MOCK-CODE")
            object["expiresAtMs"] = .number(expiry ?? (Date().timeIntervalSince1970 * 1000 + 60000)); object["pollIntervalMs"] = .number(interval)
        }
        return try JSONEncoder().encode(object)
    }
    nonisolated private func requestBody(_ request: URLRequest) throws -> JSONObject { try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request)) }
    private func journalText(_ persistence: ClientPersistence) throws -> String { String(decoding: try JSONEncoder().encode(persistence.loadMutationIntents(accountID: saved().id)), as: UTF8.self) }

    func testMockInventorySeparatesConfiguredResolverOverridesAndCurrentDefault() async throws {
        let (store, _) = try makeStore(), management = inventory()
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET"); XCTAssertEqual(request.url?.path, "/v1/instance/providers")
            return (200, [:], try JSONEncoder().encode(management))
        }
        await store.reloadProviders()
        XCTAssertEqual(store.providerSettings.management, management)
        XCTAssertEqual(ManagedProvider.Status.ready.label, "Ready")
        XCTAssertEqual(ManagedProvider.Status.needsLogin.label, "Needs login")
        XCTAssertEqual(ManagedProvider.Status.expired.label, "Expired")
        XCTAssertEqual(ManagedProvider.Status.configured.label, "Configured")
        XCTAssertEqual(store.providerSettings.management?.default.modelId, "mock-existing-model")
        XCTAssertEqual(store.providerSettings.management?.providers.first?.lastValidation?.ready, false)
        XCTAssertEqual(store.providerSettings.management?.providers.first?.configurationOverrides, [.credentialPool])
        XCTAssertEqual(SettingsPane.providers.title, "Providers")
        _ = ProvidersSettingsView(store: store)
    }
    func testMockCredentialSubmitClearsBeforeResponseAndNeverPersistsOrRestores() async throws {
        let (store, persistence) = try makeStore()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProviderDelayedMockProtocol.self]
        store.transport = try HTTPTransport(baseURL: saved().baseURL, token: saved().token, session: URLSession(configuration: config))
        let management = inventory(), response = try JSONEncoder().encode(management)
        var finish: ((Int, Data) -> Void)?
        let arrived = expectation(description: "mock write reached transport")
        ProviderDelayedMockProtocol.handler = { request, reply in
            XCTAssertEqual(request.httpMethod, "PUT"); XCTAssertEqual(request.url?.path, "/v1/instance/providers/anthropic/api-key")
            let body = try? JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))
            XCTAssertEqual(body?["value"], .string("mock-secret-not-a-real-key"))
            XCTAssertEqual(body?["targetId"], .string("mock-controller"))
            Task { @MainActor in finish = reply; arrived.fulfill() }
        }
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-secret-not-a-real-key"
        let submit = Task { await store.submitProviderCredential() }
        await fulfillment(of: [arrived], timeout: 3)
        XCTAssertEqual(store.providerSettings.secret, ""); XCTAssertNil(store.providerSettings.editingProviderID)
        XCTAssertFalse(try journalText(persistence).contains("mock-secret"))
        finish?(200, response); await submit.value
        XCTAssertEqual(store.providerSettings.management?.default, management.default)
        XCTAssertTrue(store.pendingIntents.isEmpty)
        let reopened = LemonBotStore(keychain: ProviderMockCredentials(), persistence: persistence)
        XCTAssertEqual(reopened.providerSettings.secret, ""); XCTAssertNil(reopened.providerSettings.deviceLogin)
        XCTAssertNil(try persistence.loadDraft(conversationID: "resource", accountID: saved().id))
    }
    func testMockFailureNeverRetainsEchoedCredentialAndCancelNavigationBackgroundClear() async throws {
        let (store, persistence) = try makeStore()
        TestHTTPProtocol.handler = { _ in
            (400, [:], Data(#"{"error":{"code":"invalid_request","message":"mock-secret-echo","requestId":"mock","retrySafe":true,"details":{"value":"mock-secret-echo"}}}"#.utf8))
        }
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-secret-echo"
        await store.submitProviderCredential()
        XCTAssertEqual(store.providerSettings.secret, "")
        XCTAssertFalse(store.providerSettings.message?.contains("mock-secret-echo") ?? false)
        XCTAssertFalse(store.errorMessage?.contains("mock-secret-echo") ?? false)
        XCTAssertFalse(try journalText(persistence).contains("mock-secret-echo"))
        for event in 0..<3 {
            store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-secret"
            switch event {
            case 0: store.providerSettings.clearCredential()
            case 1: store.providerSettings.setPresentation(visible: false, active: true)
            default: try await store.setPresence(foreground: false)
            }
            XCTAssertEqual(store.providerSettings.secret, ""); XCTAssertNil(store.providerSettings.editingProviderID)
        }
    }
    func testMockInvalidAndUnsupportedInputsNeverDispatchAndAlwaysClear() async throws {
        let (store, _) = try makeStore()
        store.beginProviderCredential("openai_codex"); XCTAssertNil(store.providerSettings.editingProviderID)
        for value in ["", "a\0b", String(repeating: "a", count: 16385)] {
            store.beginProviderCredential("anthropic"); store.providerSettings.secret = value
            await store.submitProviderCredential(); XCTAssertEqual(store.providerSettings.secret, "")
        }
        store.member?.role = "member"
        store.beginProviderCredential("anthropic"); await store.startProviderDeviceLogin()
        XCTAssertNil(store.providerSettings.management); XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
    }
    func testMockUnknownKeyIsFencedAndGenericStatusCannotSettleOrReplayIt() async throws {
        let (store, persistence) = try makeStore(), management = inventory()
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-unknown-key"
        await store.submitProviderCredential()
        let intent = try XCTUnwrap(store.pendingIntents.first)
        XCTAssertEqual(intent.resourceIDs, ["mock-controller"]); XCTAssertEqual(intent.state, "outcome_unknown")
        XCTAssertEqual(store.providerSettings.secret, ""); XCTAssertFalse(store.canWriteProviders)
        XCTAssertFalse(try journalText(persistence).contains("mock-unknown-key"))
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], try JSONEncoder().encode(management))
        }
        await store.reloadProviders(); await store.submitProviderCredential()
        let settled = try await store.reconcileMutation(intent.clientNonce)
        XCTAssertFalse(settled); XCTAssertEqual(store.pendingIntents.first?.clientNonce, intent.clientNonce)
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        XCTAssertEqual(try persistence.loadMutationIntents(accountID: saved().id).first?.clientNonce, intent.clientNonce)
    }
    func testMockNewIntentRequiresExplicitSuccessfulStatusReviewWithoutReplayingUnknownKey() async throws {
        let (store, _) = try makeStore(), management = inventory()
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-unknown-key"
        await store.submitProviderCredential()
        store.beginNewProviderChangeAfterReview()
        XCTAssertFalse(store.canWriteProviders)
        await store.reloadProviders(reviewingUnknownChange: true)
        XCTAssertFalse(store.providerSettings.reviewedUnknownChange)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, [:], try JSONEncoder().encode(management))
        }
        await store.reloadProviders()
        store.beginNewProviderChangeAfterReview()
        XCTAssertFalse(store.canWriteProviders)
        await store.reloadProviders(reviewingUnknownChange: true)
        XCTAssertTrue(store.providerSettings.reviewedUnknownChange)
        XCTAssertFalse(store.canWriteProviders)
        store.beginNewProviderChangeAfterReview()
        XCTAssertTrue(store.canWriteProviders)
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertTrue(store.providerSettings.message?.contains("still unconfirmed") == true)
        XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "PUT" }.count, 1)
        store.beginProviderCredential("anthropic")
        XCTAssertEqual(store.providerSettings.secret, "")
    }
    func testMockDefaultIsSeparateBoundConfirmationAndDisconnectDoesNotChooseDefault() async throws {
        let (store, _) = try makeStore(), management = inventory()
        TestHTTPProtocol.handler = { request in
            let body = try self.requestBody(request)
            XCTAssertEqual(body["targetId"], .string("mock-controller"))
            if request.url?.path.hasSuffix("/default") == true {
                XCTAssertEqual(body["providerId"], .string("anthropic")); XCTAssertEqual(body["modelId"], .string("mock-deliberate-model"))
            } else { XCTAssertNil(body["modelId"]); XCTAssertNil(body["providerId"]) }
            return (200, [:], try JSONEncoder().encode(management))
        }
        store.requestProviderDefault(providerID: "anthropic", modelID: "mock-deliberate-model")
        XCTAssertTrue(TestHTTPProtocol.requests.isEmpty); XCTAssertNotNil(store.providerSettings.confirmation)
        store.providerSettings.cancelConfirmation(); await store.confirmProviderChange(nil)
        XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
        store.requestProviderDefault(providerID: "anthropic", modelID: "mock-deliberate-model")
        let defaultConfirmation = store.providerSettings.confirmation
        let defaultTask = Task { await store.confirmProviderChange(defaultConfirmation) }
        store.providerSettings.cancelConfirmation() // SwiftUI dismisses before the task runs.
        await defaultTask.value
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
        store.requestProviderDisconnect("anthropic"); XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
        let disconnectConfirmation = store.providerSettings.confirmation
        let disconnectTask = Task { await store.confirmProviderChange(disconnectConfirmation) }
        store.providerSettings.cancelConfirmation()
        await disconnectTask.value
        XCTAssertEqual(TestHTTPProtocol.requests.last?.url?.path, "/v1/instance/providers/anthropic/disconnect")
        XCTAssertEqual(store.providerSettings.management?.default, management.default)
        store.requestProviderDefault(providerID: "anthropic", modelID: "mock-deliberate-model")
        let staleConfirmation = store.providerSettings.confirmation
        store.providerSettings.reset(); await store.confirmProviderChange(staleConfirmation)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 2)
    }
    func testMockDeviceFixedStartPollCancelIdentitiesAndForegroundBounds() async throws {
        let (store, persistence) = try makeStore()
        var loginID = "", pollNonces: [String] = [], cancelNonce = ""
        let management = inventory()
        TestHTTPProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, [:], try JSONEncoder().encode(management)) }
            let body = try self.requestBody(request), nonce = try XCTUnwrap(body["clientNonce"]?.stringValue)
            XCTAssertEqual(body["targetId"], .string("mock-controller"))
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/poll") { pollNonces.append(nonce); XCTAssertTrue(path.contains(loginID)) }
            else if path.hasSuffix("/cancel") { cancelNonce = nonce; XCTAssertTrue(path.contains(loginID)) }
            else { loginID = nonce }
            return (200, [:], try self.deviceData(loginID: loginID, status: path.hasSuffix("/cancel") ? "cancelled" : "pending"))
        }
        await store.startProviderDeviceLogin()
        XCTAssertEqual(store.providerSettings.deviceLogin?.loginId, loginID)
        XCTAssertEqual(store.providerSettings.deviceLogin?.browserURL?.absoluteString, "https://auth.openai.com/codex/device")
        XCTAssertEqual(store.providerSettings.nextPollDelay, 1)
        XCTAssertFalse(store.canWriteProviders)
        store.beginProviderCredential("anthropic")
        XCTAssertNil(store.providerSettings.editingProviderID)
        await store.pollProviderDeviceLogin(); await store.pollProviderDeviceLogin()
        XCTAssertEqual(pollNonces.count, 2); XCTAssertEqual(Set(pollNonces).count, 1); XCTAssertNotEqual(pollNonces.first, loginID)
        store.providerSettings.setPresentation(visible: false, active: true)
        let count = TestHTTPProtocol.requests.count; await store.pollProviderDeviceLogin(); XCTAssertEqual(TestHTTPProtocol.requests.count, count)
        store.providerSettings.setPresentation(visible: true, active: false); XCTAssertNil(store.providerSettings.nextPollDelay)
        store.providerSettings.setPresentation(visible: true, active: true)
        await store.cancelProviderDeviceLogin()
        XCTAssertNotEqual(cancelNonce, loginID); XCTAssertNotEqual(cancelNonce, pollNonces.first)
        XCTAssertEqual(store.providerSettings.deviceLogin?.status, .cancelled); XCTAssertNil(store.providerSettings.nextPollDelay)
        XCTAssertEqual(TestHTTPProtocol.requests.last?.httpMethod, "GET")
        XCTAssertFalse(try journalText(persistence).contains("MOCK-CODE"))
        XCTAssertFalse(try journalText(persistence).contains("auth.openai.com"))
    }
    func testMockUnknownDeviceStartExplicitReconciliationRetainsOriginalNonceAfterReopen() async throws {
        let (store, persistence) = try makeStore()
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        await store.startProviderDeviceLogin()
        let original = try XCTUnwrap(store.pendingIntents.first)
        XCTAssertTrue(store.providerSettings.deviceUnknown); XCTAssertNil(store.providerSettings.nextPollDelay)
        await store.pollProviderDeviceLogin(); XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
        store.providerSettings.reset() // Reopening restores no user code/URL, only safe journal metadata.
        store.pendingIntents = try persistence.loadMutationIntents(accountID: saved().id)
        store.providerSettings.management = inventory()
        TestHTTPProtocol.handler = { request in
            let body = try self.requestBody(request)
            XCTAssertEqual(body["clientNonce"], .string(original.clientNonce)); XCTAssertEqual(request.url?.path, "/v1" + original.path)
            return (200, [:], try self.deviceData(loginID: original.clientNonce))
        }
        await store.reconcileProviderDeviceLogin()
        XCTAssertTrue(store.pendingIntents.isEmpty)
        XCTAssertEqual(store.providerSettings.deviceLogin?.loginId, original.clientNonce)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 2)
    }
    func testMockUnknownPollAndCancelEachReconcileExactOriginalIntent() async throws {
        for action in ["poll", "cancel"] {
            let (store, _) = try makeStore()
            TestHTTPProtocol.handler = { request in
                let nonce = try XCTUnwrap(self.requestBody(request)["clientNonce"]?.stringValue)
                return (200, [:], try self.deviceData(loginID: nonce))
            }
            await store.startProviderDeviceLogin()
            let loginID = try XCTUnwrap(store.providerSettings.deviceLogin?.loginId)
            TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
            if action == "poll" { await store.pollProviderDeviceLogin() } else { await store.cancelProviderDeviceLogin() }
            let original = try XCTUnwrap(store.pendingIntents.first)
            XCTAssertTrue(original.path.hasSuffix("/\(loginID)/\(action)")); XCTAssertNotEqual(original.clientNonce, loginID)
            let management = inventory()
            TestHTTPProtocol.handler = { request in
                if request.httpMethod == "GET" { return (200, [:], try JSONEncoder().encode(management)) }
                XCTAssertEqual(try self.requestBody(request)["clientNonce"], .string(original.clientNonce))
                XCTAssertEqual(request.url?.path, "/v1" + original.path)
                return (200, [:], try self.deviceData(loginID: loginID, status: action == "cancel" ? "cancelled" : "completed"))
            }
            await store.reconcileProviderDeviceLogin()
            XCTAssertTrue(store.pendingIntents.isEmpty); XCTAssertNil(store.providerSettings.nextPollDelay)
            XCTAssertEqual(store.providerSettings.management?.providers[1].status, .needsLogin) // Completion is not Ready.
        }
    }
    func testMockDeviceTerminalStatesReloadAndMalformedResponsesStayUnknown() async throws {
        for status in ["completed", "denied", "expired", "cancelled", "lost", "failed"] {
            let (store, _) = try makeStore(), management = inventory()
            TestHTTPProtocol.handler = { request in
                if request.httpMethod == "GET" { return (200, [:], try JSONEncoder().encode(management)) }
                let nonce = try XCTUnwrap(self.requestBody(request)["clientNonce"]?.stringValue)
                return (200, [:], try self.deviceData(loginID: nonce, status: status))
            }
            await store.startProviderDeviceLogin()
            XCTAssertEqual(store.providerSettings.deviceLogin?.status.rawValue, status)
            XCTAssertNil(store.providerSettings.nextPollDelay); XCTAssertEqual(TestHTTPProtocol.requests.last?.httpMethod, "GET")
        }
        for (url, interval) in [("https://evil.example/codex/device", 1000.0), ("https://auth.openai.com/codex/device?x=1", 1000), ("https://auth.openai.com/codex/device", 999), ("https://auth.openai.com/codex/device", 60001)] {
            let (store, _) = try makeStore()
            TestHTTPProtocol.handler = { request in
                let nonce = try XCTUnwrap(self.requestBody(request)["clientNonce"]?.stringValue)
                return (200, [:], try self.deviceData(loginID: nonce, interval: interval, url: url))
            }
            await store.startProviderDeviceLogin()
            XCTAssertTrue(store.providerSettings.deviceUnknown); XCTAssertNil(store.providerSettings.deviceLogin)
            XCTAssertEqual(store.pendingIntents.count, 1); XCTAssertNil(store.providerSettings.nextPollDelay)
        }
    }
    func testMockDeviceExpiryAndStartingAreBounded() async throws {
        let (store, _) = try makeStore()
        TestHTTPProtocol.handler = { request in
            let nonce = try XCTUnwrap(self.requestBody(request)["clientNonce"]?.stringValue)
            return (200, [:], try self.deviceData(loginID: nonce, expiry: 1))
        }
        await store.startProviderDeviceLogin(); XCTAssertNil(store.providerSettings.nextPollDelay)
        let starting = try JSONDecoder().decode(ProviderDeviceLogin.self, from: deviceData(loginID: "mock-login", status: "starting"))
        store.providerSettings.deviceLogin = starting
        store.providerSettings.deviceIntent = .init(loginID: "mock-login", startNonce: "mock-login", pollNonce: "mock-poll", cancelNonce: "mock-cancel")
        XCTAssertEqual(store.providerSettings.nextPollDelay, 2)
        store.providerSettings.deviceIntent?.observationDeadline = 0
        XCTAssertNil(store.providerSettings.nextPollDelay)
    }
    func testMockExecutionTargetOwnershipAndTargetBoundRoutes() async throws {
        let (store, _) = try makeStore()
        let owned = Machine(id: "mock-owned", revision: 1, createdAtMs: 1, updatedAtMs: 1, nodeId: "mock-node", nodeName: "mock-worker", name: "Mock worker", ownerUserId: saved().userID, accessUserIds: [], status: "online", labels: [:], botIds: [])
        var shared = owned; shared.id = "mock-shared"; shared.ownerUserId = "someone-else"; shared.accessUserIds = [saved().userID]
        store.machines = [owned, shared]
        XCTAssertEqual(store.ownedProviderMachines.map(\.id), [owned.id])
        let management = inventory(nodeID: "mock-node", targetID: "mock-worker-target")
        TestHTTPProtocol.handler = { request in
            XCTAssertTrue(request.url!.path.hasPrefix("/v1/machines/mock-owned/providers"))
            if request.httpMethod != "GET" { XCTAssertEqual(try self.requestBody(request)["targetId"], .string("mock-worker-target")) }
            return (200, [:], try JSONEncoder().encode(management))
        }
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "discard-on-target-change"
        await store.selectProviderTarget(machineID: owned.id)
        XCTAssertEqual(store.providerSettings.secret, ""); XCTAssertEqual(store.providerSettings.management?.target, management.target)
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-worker-key"; await store.submitProviderCredential()
        XCTAssertEqual(TestHTTPProtocol.requests.last?.url?.path, "/v1/machines/mock-owned/providers/anthropic/api-key")
        let count = TestHTTPProtocol.requests.count
        await store.selectProviderTarget(machineID: shared.id)
        XCTAssertFalse(store.canManageProviders); XCTAssertNil(store.providerSettings.management); XCTAssertEqual(TestHTTPProtocol.requests.count, count)
    }
    func testMockLateMutationCannotCrossTargetOrAccountAndAccountChangeClearsSecrets() async throws {
        for changeAccount in [false, true] {
            let (store, _) = try makeStore()
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProviderDelayedMockProtocol.self]
            store.transport = try HTTPTransport(baseURL: saved().baseURL, token: saved().token, session: URLSession(configuration: config))
            var finish: ((Int, Data) -> Void)?
            let arrived = expectation(description: "mock delayed mutation")
            ProviderDelayedMockProtocol.handler = { _, reply in Task { @MainActor in finish = reply; arrived.fulfill() } }
            store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-old-secret"
            let submit = Task { await store.submitProviderCredential() }
            await fulfillment(of: [arrived], timeout: 3)
            if changeAccount {
                store.account = saved("mock-other-account"); store.generation = UUID()
            } else { store.providerSettings.reset(machineID: "mock-new-target") }
            finish?(200, try JSONEncoder().encode(inventory())); await submit.value
            XCTAssertNil(store.providerSettings.management); XCTAssertEqual(store.providerSettings.secret, "")
        }
        let (store, _) = try makeStore()
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-unsent-secret"
        store.account = saved("mock-other-account")
        XCTAssertEqual(store.providerSettings.secret, ""); XCTAssertNil(store.providerSettings.editingProviderID)
    }
}

extension ProviderSettingsMockTests {
    func testMockUnknownDefaultAndDisconnectKeepTheirOriginalFencesAfterStatusReview() async throws {
        for action in ["default", "disconnect"] {
            let (store, persistence) = try makeStore(), management = inventory()
            TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
            if action == "default" { store.requestProviderDefault(providerID: "anthropic", modelID: "mock-model") }
            else { store.requestProviderDisconnect("anthropic") }
            await store.confirmProviderChange(store.providerSettings.confirmation)
            let original = try XCTUnwrap(store.pendingIntents.first)
            TestHTTPProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, [:], try JSONEncoder().encode(management))
            }
            await store.reloadProviders()
            store.requestProviderDefault(providerID: "anthropic", modelID: "another-model")
            store.requestProviderDisconnect("anthropic")
            await store.confirmProviderChange(store.providerSettings.confirmation)
            XCTAssertNil(store.providerSettings.confirmation)
            XCTAssertEqual(store.pendingIntents.first?.clientNonce, original.clientNonce)
            XCTAssertEqual(try persistence.loadMutationIntents(accountID: saved().id).first?.clientNonce, original.clientNonce)
            XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
        }
    }
    func testMockDeviceReconciliationRejectionCannotReleaseOriginalFence() async throws {
        let (store, persistence) = try makeStore()
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        await store.startProviderDeviceLogin()
        let original = try XCTUnwrap(store.pendingIntents.first)
        TestHTTPProtocol.handler = { _ in
            (503, [:], Data(#"{"error":{"code":"machine_offline","message":"Mock target offline before dispatch","requestId":"mock","retrySafe":true}}"#.utf8))
        }
        await store.reconcileProviderDeviceLogin()
        XCTAssertEqual(store.pendingIntents.first?.clientNonce, original.clientNonce)
        XCTAssertEqual(try persistence.loadMutationIntents(accountID: saved().id).first?.resourceIDs, ["mock-controller"])
        XCTAssertTrue(store.providerSettings.deviceUnknown); XCTAssertNil(store.providerSettings.nextPollDelay)
    }
    func testMockUntrustedErrorDetailsCannotEnterProviderJournal() async throws {
        let (store, persistence) = try makeStore()
        TestHTTPProtocol.handler = { _ in
            (409, [:], Data(#"{"error":{"code":"outcome_unknown","message":"mock-credential-echo","requestId":"mock","retrySafe":false,"details":{"resourceIds":["mock-credential-echo"],"runId":"mock-credential-echo"}}}"#.utf8))
        }
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-credential-echo"
        await store.submitProviderCredential()
        XCTAssertEqual(store.pendingIntents.first?.resourceIDs, ["mock-controller"]); XCTAssertNil(store.pendingIntents.first?.runID)
        XCTAssertFalse(try journalText(persistence).contains("mock-credential-echo"))
        XCTAssertFalse(store.providerSettings.message?.contains("mock-credential-echo") ?? false)
    }
    func testMockLateDeviceAndInventoryResultsCannotCrossAccountOrTarget() async throws {
        for isDevice in [false, true] {
            for changeAccount in [false, true] {
                let (store, _) = try makeStore()
                let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ProviderDelayedMockProtocol.self]
                store.transport = try HTTPTransport(baseURL: saved().baseURL, token: saved().token, session: URLSession(configuration: config))
                var finish: ((Int, Data) -> Void)?
                var loginID = ""
                let arrived = expectation(description: "mock delayed provider response")
                ProviderDelayedMockProtocol.handler = { request, reply in
                    let nonce = request.httpMethod == "GET" ? "" : (try? self.requestBody(request))?["clientNonce"]?.stringValue ?? ""
                    Task { @MainActor in loginID = nonce; finish = reply; arrived.fulfill() }
                }
                let action = Task {
                    if isDevice { await store.startProviderDeviceLogin() }
                    else { await store.reloadProviders() }
                }
                await fulfillment(of: [arrived], timeout: 3)
                if changeAccount { store.account = saved("mock-new-account"); store.generation = UUID() }
                else { store.providerSettings.reset(machineID: "mock-other-target") }
                let data = isDevice ? try deviceData(loginID: loginID) : try JSONEncoder().encode(inventory())
                finish?(200, data); await action.value
                XCTAssertNil(store.providerSettings.deviceLogin); XCTAssertNil(store.providerSettings.management)
                XCTAssertEqual(store.providerSettings.secret, "")
            }
        }
    }
    func testMockOwnershipRevocationClearsEditorAndInvalidatesBoundConfirmation() throws {
        let (store, _) = try makeStore()
        store.beginProviderCredential("anthropic"); store.providerSettings.secret = "mock-secret"
        store.member?.role = "member"
        XCTAssertEqual(store.providerSettings.secret, ""); XCTAssertNil(store.providerSettings.management)
        XCTAssertFalse(store.canManageProviders); XCTAssertTrue(TestHTTPProtocol.requests.isEmpty)
    }
    func testMockExplicitCheckAfterExpiryOrObservationDeadlineUsesFixedPollAndSettles() async throws {
        for expired in [false, true] {
            let (store, _) = try makeStore(), management = inventory()
            let expiry = Date().timeIntervalSince1970 * 1000 + 900000
            TestHTTPProtocol.handler = { request in
                let nonce = try XCTUnwrap(self.requestBody(request)["clientNonce"]?.stringValue)
                return (200, [:], try self.deviceData(loginID: nonce, expiry: expired ? 1 : expiry))
            }
            await store.startProviderDeviceLogin()
            if !expired {
                XCTAssertEqual(store.providerSettings.deviceIntent?.observationDeadline, expiry / 1000)
                XCTAssertNotNil(store.providerSettings.nextPollDelay) // Full advertised 15-minute grant.
            }
            let intent = try XCTUnwrap(store.providerSettings.deviceIntent)
            store.providerSettings.deviceIntent?.observationDeadline = 0
            XCTAssertNil(store.providerSettings.nextPollDelay)
            TestHTTPProtocol.handler = { request in
                if request.httpMethod == "GET" { return (200, [:], try JSONEncoder().encode(management)) }
                XCTAssertTrue(request.url!.path.hasSuffix("/\(intent.loginID)/poll"))
                XCTAssertEqual(try self.requestBody(request)["clientNonce"], .string(intent.pollNonce))
                return (200, [:], try self.deviceData(loginID: intent.loginID, status: expired ? "expired" : "completed"))
            }
            await store.reconcileProviderDeviceLogin()
            XCTAssertEqual(store.providerSettings.deviceLogin?.status, expired ? .expired : .completed)
            XCTAssertTrue(store.canWriteProviders)
        }
    }
    func testMockNewSessionNeverReplaysUnknownStartOrPollAndRequiresExplicitRetirement() async throws {
        for action in ["start", "poll"] {
            let (store, persistence) = try makeStore(), management = inventory()
            if action == "poll" {
                TestHTTPProtocol.handler = { request in
                    let nonce = try XCTUnwrap(self.requestBody(request)["clientNonce"]?.stringValue)
                    return (200, [:], try self.deviceData(loginID: nonce))
                }
                await store.startProviderDeviceLogin()
            }
            TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
            if action == "start" { await store.startProviderDeviceLogin() }
            else { await store.pollProviderDeviceLogin() }
            let original = try XCTUnwrap(store.pendingIntents.first)
            XCTAssertEqual(original.providerSessionID, "mock-session")
            store.providerSettings.reset()
            var newAccount = saved(); newAccount.sessionID = "mock-new-session"
            store.account = newAccount
            store.pendingIntents = try persistence.loadMutationIntents(accountID: newAccount.id)
            store.providerSettings.management = management
            let count = TestHTTPProtocol.requests.count
            await store.reconcileProviderDeviceLogin()
            await store.startProviderDeviceLogin()
            store.retireUnreachableProviderDeviceLoginAfterReview()
            XCTAssertEqual(TestHTTPProtocol.requests.count, count)
            XCTAssertEqual(store.pendingIntents, [original])
            TestHTTPProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, [:], try JSONEncoder().encode(management))
            }
            await store.reloadProviders() // Generic reads never authorize retirement.
            store.retireUnreachableProviderDeviceLoginAfterReview()
            XCTAssertFalse(store.canWriteProviders)
            await store.reloadProviders(reviewingUnknownChange: true)
            XCTAssertTrue(store.providerSettings.reviewedUnreachableDeviceLogin)
            store.retireUnreachableProviderDeviceLoginAfterReview()
            XCTAssertTrue(store.pendingIntents.isEmpty)
            XCTAssertTrue(store.providerSettings.message?.contains("still unconfirmed") == true)
            XCTAssertTrue(store.canWriteProviders)
            XCTAssertEqual(TestHTTPProtocol.requests.filter { $0.httpMethod == "POST" }.count, action == "start" ? 1 : 2)
            TestHTTPProtocol.handler = { request in
                let nonce = try XCTUnwrap(self.requestBody(request)["clientNonce"]?.stringValue)
                XCTAssertNotEqual(nonce, original.clientNonce)
                return (200, [:], try self.deviceData(loginID: nonce))
            }
            await store.startProviderDeviceLogin()
            XCTAssertEqual(store.providerSettings.deviceIntent?.sessionID, "mock-new-session")
            XCTAssertNotNil(store.providerSettings.deviceLogin)
        }
    }
}
