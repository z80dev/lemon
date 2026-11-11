import XCTest
@testable import LemonBotKit

private final class MachineSetupCredentials: AccountCredentialStore {
    private var pending: PendingDevicePairing?
    func loadPendingPairing() throws -> PendingDevicePairing? { pending }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws { pending = pairing }
    func removePendingPairing() throws { pending = nil }
    func load() throws -> [StoredAccount] { [] }
    func save(_ account: StoredAccount) throws {}
    func remove(_ id: String) throws {}
}

@MainActor final class MachineSetupTests: XCTestCase {
    private func makeStore() -> LemonBotStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return LemonBotStore(keychain: MachineSetupCredentials(), persistence: ClientPersistence(root: root))
    }
    private func fixture(step: String = "checking_ssh", state: String = "running", failure: String = "null", revision: Int = 1) -> Data {
        Data("""
        {"id":"setup","revision":\(revision),"createdAtMs":1,"updatedAtMs":2,"machineId":null,"sshDestination":"me@studio","step":"\(step)","state":"\(state)","failure":\(failure),"persistence":null,"finishedAtMs":null}
        """.utf8)
    }
    func testContractEnumsAndFailureMessages() throws {
        let decoder = JSONDecoder()
        for step in MachineSetupStep.allCases {
            XCTAssertEqual(try decoder.decode(MachineSetup.self, from: fixture(step: step.rawValue)).step, step)
        }
        for failure in MachineSetupFailure.allCases {
            let value = try decoder.decode(MachineSetup.self, from: fixture(state: "failed", failure: "{\"code\":\"\(failure.rawValue)\",\"message\":\"Failed\",\"detail\":null}"))
            XCTAssertEqual(value.failure?.code, failure)
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertThrowsError(try decoder.decode(MachineSetup.self, from: fixture(step: "invalid")))
    }
    func testTunnelAndPreviewDecode() throws {
        let decoder = JSONDecoder()
        let legacyPreview = try decoder.decode(MachineEnrollmentPreview.self, from: Data(#"{"reachability":"routable"}"#.utf8))
        XCTAssertNil(legacyPreview.ssh)
        XCTAssertEqual(try decoder.decode(MachineLink.self, from: Data(#"{"kind":"direct"}"#.utf8)), .direct)
        for state in ["online", "reconnecting", "failed", "stopped", "unknown"] {
            for detail in ["ssh_auth_failed", "host_key_changed", "host_unreachable", "forward_refused", "remote_port_in_use"] {
                let data = Data("{\"kind\":\"ssh_tunnel\",\"sshDestination\":null,\"nodePort\":4044,\"productPort\":4100,\"tunnel\":{\"state\":\"\(state)\",\"detail\":\"\(detail)\",\"checkedAtMs\":null}}".utf8)
                let link = try decoder.decode(MachineLink.self, from: data)
                XCTAssertEqual(try decoder.decode(MachineLink.self, from: JSONEncoder().encode(link)), link)
            }
        }
        for reason in ["controller_remote", "node_gateway_unavailable", "launcher_unavailable"] {
            let preview = try decoder.decode(MachineEnrollmentPreview.self, from: Data("{\"reachability\":\"loopback_only\",\"ssh\":{\"available\":false,\"reason\":\"\(reason)\"}}".utf8))
            XCTAssertEqual(preview.ssh?.reason?.rawValue, reason)
        }
    }
    func testRealtimeSetupUpdatesRejectStaleRevisions() async throws {
        let store = makeStore()
        let value = try JSONDecoder().decode(MachineSetup.self, from: fixture(step: "installing", revision: 2))
        let event = RealtimeEvent(seq: "1", payload: .machineSetupUpserted(value), timestampMs: 2)
        let decoded = try JSONDecoder().decode(RealtimeEvent.self, from: JSONEncoder().encode(event))
        try await store.apply(decoded)
        try await store.receiveMachineSetup(JSONDecoder().decode(MachineSetup.self, from: fixture()))
        XCTAssertEqual(store.machineSetups["setup"]?.step, .installing)
    }
    func testSSHPostUsesValidatedDestinationAndName() async throws {
        let store = makeStore()
        store.account = StoredAccount(id: "test", baseURL: URL(string: "https://product.example/v1")!, email: "test@example.org", displayName: "Test", token: "session", userID: "user", workspaceID: "workspace")
        store.connectionState = "online"
        store.transport = try HTTPTransport(baseURL: URL(string: "https://product.example/v1")!, token: "session", session: TestHTTPProtocol.session())
        let response = fixture()
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/machines/ssh")
            let body = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))
            XCTAssertEqual(body["sshDestination"], .string("me@studio"))
            XCTAssertEqual(body["name"], .string("Studio"))
            XCTAssertNotNil(body["clientNonce"])
            return (202, [:], response)
        }
        defer { TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
        let result = try await store.addMachineOverSSH(destination: "me@studio", name: "Studio")
        XCTAssertEqual(result.id, "setup")
        XCTAssertEqual(store.machineSetups["setup"], result)
    }
}
