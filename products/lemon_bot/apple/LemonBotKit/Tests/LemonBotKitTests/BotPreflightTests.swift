import XCTest
import Foundation
@testable import LemonBotKit

enum BotPreflightFixtures {
    static let origin = "https://desktop.example.ts.net:8449"
    static func descriptor(workspaceID: String? = nil, overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["product": "lemon_bot", "apiVersion": 1, "version": "1.0", "instanceId": "backend_1", "publicUrl": origin, "capabilities": ["pairing": true]]
        if let workspaceID { value["workspaceId"] = workspaceID } else { value["setupRequired"] = false }
        value.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
}

final class BotPreflightTests: XCTestCase {
    override func setUp() { TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil }
    override func tearDown() { TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
    func testExactOriginAndPhoneLoopbackRules() throws {
        for origin in [BotPreflightFixtures.origin, "https://example.org", "https://100.101.102.103:8449", "https://[2001:db8::1]"] {
            XCTAssertEqual(try BotPreflight.validateOrigin(origin), origin)
        }
        for origin in ["https://localhost", "https://localhost.", "https://foo.localhost", "https://127.0.0.2", "https://0.0.0.0", "https://[::]", "https://[::1]", "https://[::ffff:7f00:1]"] {
            XCTAssertThrowsError(try BotPreflight.validateOrigin(origin)) { XCTAssertEqual($0 as? BotPreflightError, .loopbackOrigin, origin) }
        }
        XCTAssertEqual(try BotPreflight.validateOrigin("http://127.0.0.1:4080", use: .sameMachine), "http://127.0.0.1:4080")
        for origin in ["http://example.org", "https://example.org/", "https://example.org/v1", "https://example.org?token=secret", "https://example.org#x", "https://user:secret@example.org", "https://EXAMPLE.org", "https://example.org:443", "https://127.1", "https://2130706433", "https://0177.0.0.1", "https://0x7f000001", "https://127.0.0.1.", "https://[0:0:0:0:0:0:0:1]", "https://[::ffff:127.0.0.1]", "https://example.org\n", "https://example.org\\@evil.org"] {
            XCTAssertThrowsError(try BotPreflight.validateOrigin(origin), origin)
        }
    }
    func testPreflightChecksPublicFingerprintBeforeSendingSession() async throws {
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertLessThanOrEqual(request.timeoutInterval, 10)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            if request.url?.path == "/v1/setup" {
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, ["Content-Type": "application/json; charset=utf-8"], try BotPreflightFixtures.descriptor())
            }
            XCTAssertEqual(request.url?.path, "/v1/identity")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer product-session")
            return (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(workspaceID: "workspace_1"))
        }
        let result = try await BotPreflightClient(session: TestHTTPProtocol.session()).preflight(origin: BotPreflightFixtures.origin, expectedInstanceID: "backend_1", session: BotPreflightSession(token: "product-session", workspaceID: "workspace_1"))
        XCTAssertEqual(result.identity?.workspaceId, "workspace_1")
        XCTAssertEqual(TestHTTPProtocol.requests.count, 2)
    }
    func testPublicPhoneProbeDoesNotClaimWorkspaceVerification() async throws {
        TestHTTPProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor()) }
        let result = try await BotPreflightClient(session: TestHTTPProtocol.session()).preflight(origin: BotPreflightFixtures.origin, expectedInstanceID: "backend_1")
        XCTAssertNil(result.identity)
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
        XCTAssertNil(TestHTTPProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
    }
    func testWrongServicesRedirectsIncompleteAndOversizedDescriptorsFailWithoutSession() async throws {
        let responses: [(Int, [String: String], Data)] = [
            (404, ["Content-Type": "text/html"], Data("Phoenix.Router.NoRouteError".utf8)),
            (200, ["Content-Type": "text/html"], Data("<html>Login</html>".utf8)),
            (302, ["Location": "https://other.example/v1/setup"], Data()),
            (200, [:], try BotPreflightFixtures.descriptor()),
            (200, ["Content-Type": "application/json"], Data(#"{"setupRequired":false,"version":"1","apiVersion":1}"#.utf8)),
            (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["product": "lemon_web"])),
            (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: ["apiVersion": 2])),
            (200, ["Content-Type": "application/json", "Content-Length": "16385"], Data(repeating: 32, count: 16385)),
            (200, ["Content-Type": "application/json"], Data(repeating: 32, count: 16385))
        ]
        for response in responses {
            TestHTTPProtocol.requests = []
            TestHTTPProtocol.handler = { _ in response }
            do {
                _ = try await BotPreflightClient(session: TestHTTPProtocol.session()).preflight(origin: BotPreflightFixtures.origin, expectedInstanceID: "backend_1", session: BotPreflightSession(token: "never-forward", workspaceID: "workspace_1"))
                XCTFail("Wrong service must be refused")
            } catch { XCTAssertEqual(error as? BotPreflightError, .wrongService) }
            XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
            XCTAssertNil(TestHTTPProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
        }
    }
    func testSetupIdentityCapabilityAndAdvertisedLoopbackFailClosed() async throws {
        let cases: [([String: Any], BotPreflightError)] = [
            (["instanceId": "another_backend"], .instanceMismatch),
            (["publicUrl": "https://localhost"], .loopbackOrigin),
            (["setupRequired": true], .pairingUnavailable),
            (["capabilities": ["pairing": false]], .pairingUnavailable)
        ]
        for (overrides, expected) in cases {
            TestHTTPProtocol.handler = { _ in (200, ["Content-Type": "application/json"], try BotPreflightFixtures.descriptor(overrides: overrides)) }
            do { _ = try await BotPreflightClient(session: TestHTTPProtocol.session()).preflight(origin: BotPreflightFixtures.origin, expectedInstanceID: "backend_1"); XCTFail("Expected rejection") }
            catch { XCTAssertEqual(error as? BotPreflightError, expected) }
        }
    }
    func testAuthenticatedWorkspaceAndInstanceMustMatch() async throws {
        for (overrides, expected) in [(["workspaceId": "other_workspace"], BotPreflightError.workspaceMismatch), (["instanceId": "other_backend"], .instanceMismatch)] {
            TestHTTPProtocol.handler = { request in
                let bytes = try BotPreflightFixtures.descriptor(workspaceID: request.url?.path == "/v1/identity" ? "workspace_1" : nil, overrides: request.url?.path == "/v1/identity" ? overrides : [:])
                return (200, ["Content-Type": "application/json"], bytes)
            }
            do {
                _ = try await BotPreflightClient(session: TestHTTPProtocol.session()).preflight(origin: BotPreflightFixtures.origin, expectedInstanceID: "backend_1", session: BotPreflightSession(token: "product-session", workspaceID: "workspace_1"))
                XCTFail("Wrong identity must be refused")
            } catch { XCTAssertEqual(error as? BotPreflightError, expected) }
        }
    }
    func testNetworkFailureUsesSafeActionableError() async throws {
        TestHTTPProtocol.handler = { _ in throw URLError(.serverCertificateUntrusted) }
        do { _ = try await BotPreflightClient(session: TestHTTPProtocol.session()).preflight(origin: BotPreflightFixtures.origin, expectedInstanceID: "backend_1"); XCTFail("TLS failure must be refused") }
        catch { XCTAssertEqual(error as? BotPreflightError, .unavailable) }
    }
}
