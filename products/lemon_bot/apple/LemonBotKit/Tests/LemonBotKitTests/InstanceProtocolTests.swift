import Foundation
import XCTest
@testable import LemonBotKit

final class InstanceProtocolTests: XCTestCase {
    // The canonical fixture is produced and checked by backend/test/core/instance.test.ts.
    private func fixture() throws -> Data {
        let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: kit.appendingPathComponent("../../sdk/ts/test/fixtures/instance-status.json").standardizedFileURL)
    }
    func testBackendInstanceFixtureDecodesAndRoundTripsRequiredNulls() throws {
        let data = try fixture()
        let value = try JSONDecoder().decode(InstanceStatus.self, from: data)
        XCTAssertEqual(value.backend.version, "0.1.0")
        XCTAssertEqual(value.controller.state, .connected)
        XCTAssertEqual(value.controller.methodCount, 4)
        XCTAssertNil(value.controller.lastError)
        XCTAssertEqual(value.lemon?.memoryMb, 256.5)
        XCTAssertEqual(value.lemon?.activeSessions, 7)
        XCTAssertEqual(value.lemon?.runs?.completedToday, 4)
        XCTAssertEqual(value.lemon?.nodes?.online, 2)
        XCTAssertFalse(value.runtime.controllable)
        let encoded = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encoded) as? NSDictionary, try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }
    func testMissingRequiredNullableKeyIsRejected() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        json.removeValue(forKey: "lemonUnavailableReason")
        XCTAssertThrowsError(try JSONDecoder().decode(InstanceStatus.self, from: JSONSerialization.data(withJSONObject: json)))
    }
    func testRuntimeOperationAndRequest() throws {
        let data = Data(#"{"id":"op","action":"restart","state":"succeeded","startedAtMs":1,"completedAtMs":2,"exitCode":0,"output":"done"}"#.utf8)
        let operation = try JSONDecoder().decode(RuntimeOperation.self, from: data)
        XCTAssertEqual(operation.action, .restart)
        XCTAssertEqual(operation.state, .succeeded)
        XCTAssertEqual(operation.exitCode, 0)
        let request = RuntimeActionRequest(clientNonce: "nonce", confirm: true)
        XCTAssertTrue(try XCTUnwrap(JSONDecoder().decode(RuntimeActionRequest.self, from: JSONEncoder().encode(request)).confirm))
    }
}
