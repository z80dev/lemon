#if DEBUG
import Foundation
import XCTest
import LemonBotKit
@testable import LemonBotUI

final class FixtureMessageTests: XCTestCase {
    func testMessagesAreRecordedOnceAndIsolatedBetweenFixtureSessions() throws {
        let session = UUID().uuidString
        let room = LemonBotFixtureID.zestMain
        func request(_ method: String, _ path: String, session: String, body: MessageSend? = nil) throws -> (Int, Data) {
            var request = URLRequest(url: FixtureURLProtocol.baseURL.appendingPathComponent("v1" + path))
            request.httpMethod = method
            request.setValue(session, forHTTPHeaderField: "X-LB-Fixture-Session")
            request.httpBody = try body.map { try JSONEncoder().encode($0) }
            return FixtureURLProtocol.respond(to: request)
        }
        let message = MessageSend(clientNonce: UUID().uuidString, text: "Keyboard up\nSecond line")
        let (status, data) = try request("POST", "/conversations/\(room)/messages", session: session, body: message)
        XCTAssertEqual(status, 200)
        let receipt = try JSONDecoder().decode(MessageReceipt.self, from: data)
        XCTAssertEqual(receipt.status, "accepted")
        XCTAssertEqual(receipt.entries.first?.text, message.text)
        XCTAssertTrue(receipt.runs.isEmpty, "Fixture sends record authored text but never execute Bot work")
        let replay = try request("POST", "/conversations/\(room)/messages", session: session, body: message)
        XCTAssertEqual(data, replay.1)
        let page = try JSONDecoder().decode(Page<TranscriptEntry>.self, from: request("GET", "/conversations/\(room)/entries", session: session).1)
        XCTAssertEqual(page.items.filter { $0.clientNonce == message.clientNonce }.count, 1)
        let isolated = try JSONDecoder().decode(Page<TranscriptEntry>.self, from: request("GET", "/conversations/\(room)/entries", session: UUID().uuidString).1)
        XCTAssertFalse(isolated.items.contains { $0.clientNonce == message.clientNonce })
        XCTAssertEqual(try request("DELETE", "/conversations/\(room)", session: session).0, 409)
    }
}
#endif
