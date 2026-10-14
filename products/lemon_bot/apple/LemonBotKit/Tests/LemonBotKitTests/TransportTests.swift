import XCTest
import Foundation
@testable import LemonBotKit

final class TestHTTPProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TestHTTPProtocol.self]
        return URLSession(configuration: config)
    }
    static func body(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return result }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

final class TransportTests: XCTestCase {
    override func setUp() { TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil }
    override func tearDown() { TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = [] }
    func testRemoteTLSAndURLInjectionRules() throws {
        XCTAssertThrowsError(try HTTPTransport(baseURL: XCTUnwrap(URL(string: "http://example.org"))))
        XCTAssertThrowsError(try HTTPTransport(baseURL: XCTUnwrap(URL(string: "https://user:token@example.org"))))
        let client = try HTTPTransport(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:4080")))
        XCTAssertEqual(try client.url("/bots", query: ["query": "a&b / c"]).path, "/v1/bots")
        XCTAssertEqual(URLComponents(url: try client.url("/bots", query: ["query": "a&b / c"]), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b / c")
        for path in ["//evil.example", "/bots?token=x", "/../auth", "/%2e%2e/auth", "/bots/%", "/bots\\x"] { XCTAssertThrowsError(try client.url(path)) }
        XCTAssertThrowsError(try HTTPTransport.pathID("x/y"))
        XCTAssertEqual(try HTTPTransport.pathID("opaque id"), "opaque%20id")
    }
    func testMutationPreservesRevisionConfirmationAndProvidedNonce() async throws {
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session")
            let body = try JSONDecoder().decode(JSONObject.self, from: TestHTTPProtocol.body(request))
            XCTAssertEqual(body["clientNonce"], .string("fixed_nonce_123456"))
            XCTAssertEqual(body["revision"], .number(7)); XCTAssertEqual(body["confirmationToken"], .string("confirmation"))
            XCTAssertEqual(body["confirmName"], .string("Office Mac"))
            return (200, ["Content-Type": "application/json"], Data(#"{"id":"m","deleted":true}"#.utf8))
        }
        let client = try HTTPTransport(baseURL: XCTUnwrap(URL(string: "https://product.example")), token: "session", session: TestHTTPProtocol.session())
        let result: Deleted = try await client.mutate("DELETE", "/machines/m", body: ["clientNonce": .string("fixed_nonce_123456"), "revision": .number(7), "confirmationToken": .string("confirmation"), "confirmName": .string("Office Mac")])
        XCTAssertTrue(result.deleted); XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    func testTimeoutNeverAutomaticallyReplaysMutation() async throws {
        TestHTTPProtocol.handler = { _ in throw URLError(.timedOut) }
        let client = try HTTPTransport(baseURL: XCTUnwrap(URL(string: "https://product.example")), token: "session", session: TestHTTPProtocol.session())
        do { let _: Empty = try await client.mutate("POST", "/drafts/d/send", body: ["clientNonce": .string("same_intent_123456"), "revision": .number(2)]); XCTFail("Expected uncertain outcome") }
        catch ClientError.outcomeUnknown(let nonce) { XCTAssertEqual(nonce, "same_intent_123456") }
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    func testUnreadableAcceptedReceiptIsUncertainNotFailed() async throws {
        TestHTTPProtocol.handler = { _ in (202, [:], Data("{}".utf8)) }
        let client = try HTTPTransport(baseURL: XCTUnwrap(URL(string: "https://product.example")), session: TestHTTPProtocol.session())
        do { let _: MessageReceipt = try await client.mutate("POST", "/conversations/c/messages", body: ["clientNonce": .string("fixed_message_123456"), "text": .string("Hello")]); XCTFail("Expected uncertain receipt") }
        catch ClientError.outcomeUnknown(let nonce) { XCTAssertEqual(nonce, "fixed_message_123456") }
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
    func testExactBackendPrerequisiteIsNotConvertedToEmptyData() async throws {
        TestHTTPProtocol.handler = { _ in (503, [:], Data(#"{"error":{"code":"capability_unavailable","message":"Configure destination node.shell.open","requestId":"req_shell","retrySafe":true,"details":{"prerequisite":"Install Lemon PTY worker"}}}"#.utf8)) }
        let client = try HTTPTransport(baseURL: XCTUnwrap(URL(string: "https://product.example")), session: TestHTTPProtocol.session())
        do { let _: Page<Terminal> = try await client.read("/terminals"); XCTFail("Must fail rather than return an empty page") }
        catch let error as BackendError {
            XCTAssertEqual(error.failure.code, "capability_unavailable")
            XCTAssertTrue(error.localizedDescription.contains("Install Lemon PTY worker")); XCTAssertEqual(error.failure.requestId, "req_shell")
        }
    }
    func testTicketDownloadRequiresAuthorizedOriginAndFetchesActualBytes() async throws {
        let bytes = Data([0, 1, 2, 255, 0, 4])
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/downloads/ticket")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["Content-Type": "application/octet-stream", "Content-Length": String(bytes.count)], bytes)
        }
        let client = try HTTPTransport(baseURL: XCTUnwrap(URL(string: "https://product.example")), token: "session", session: TestHTTPProtocol.session())
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("binary.dat")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let ticket = Download(url: "https://product.example/v1/downloads/ticket", expiresAtMs: Date().timeIntervalSince1970 * 1000 + 60000, filename: "binary.dat", mime: "application/octet-stream", size: bytes.count)
        let result = try await client.download(ticket, destination: destination)
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        var foreign = ticket; foreign.url = "https://other.example/v1/downloads/ticket"
        do { _ = try await client.download(foreign, destination: destination); XCTFail("Reject foreign ticket origin") } catch ClientError.invalidBinary {}
        XCTAssertEqual(TestHTTPProtocol.requests.count, 1)
    }
}
