import XCTest
import Foundation
import Network
import CryptoKit
@testable import LemonBotKit

private final class AckCredentials: AccountCredentialStore {
    func load() throws -> [StoredAccount] { [] }
    func save(_ account: StoredAccount) throws {}
    func remove(_ id: String) throws {}
    func loadPendingPairing() throws -> PendingDevicePairing? { nil }
    func savePendingPairing(_ pairing: PendingDevicePairing) throws {}
    func removePendingPairing() throws {}
}

/// A real loopback WebSocket handshake and one captured client frame, with no timer-driven synchronization.
private final class AckSocketServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "LemonBotTests.ackSocket")
    private var connection: NWConnection?
    private var buffer = Data()
    private let received: (Data) -> Void
    init(ready: XCTestExpectation, received: @escaping (Data) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.received = received
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.readHandshake()
        }
        listener.start(queue: queue)
    }
    func close() { listener.cancel(); queue.sync { connection?.cancel() } }
    private func readHandshake() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            self.buffer.append(data)
            guard let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) else { self.readHandshake(); return }
            let header = String(decoding: self.buffer[..<end.upperBound], as: UTF8.self)
            guard let key = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") })?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) else { return }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            self.buffer.removeSubrange(..<end.upperBound)
            self.connection?.send(content: Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8), completion: .contentProcessed { error in
                if error == nil { self.readFrame() }
            })
        }
    }
    private func readFrame() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            self.buffer.append(data)
            let bytes = [UInt8](self.buffer)
            guard bytes.count >= 2 else { self.readFrame(); return }
            let length = Int(bytes[1] & 0x7f)
            guard length < 126, bytes[1] & 0x80 != 0 else { return }
            guard bytes.count >= 6 + length else { self.readFrame(); return }
            self.received(Data((0..<length).map { bytes[6 + $0] ^ bytes[2 + $0 % 4] }))
        }
    }
}

@MainActor final class RealtimeAcknowledgementTests: XCTestCase {
    func testFrameAcknowledgementDoesNotClaimANewerSnapshotCursorWasDelivered() async throws {
        let ready = expectation(description: "Native socket listener ready")
        let received = expectation(description: "Frame cursor acknowledged")
        var frame: RealtimeClientFrame?
        let server = try AckSocketServer(ready: ready) { data in frame = try? JSONDecoder().decode(RealtimeClientFrame.self, from: data); received.fulfill() }
        defer { server.close() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.listener.port)
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port.rawValue)/realtime")!)
        defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        socket.resume()
        let store = LemonBotStore(keychain: AckCredentials())
        // A snapshot's global watermark is independent of frames delivered on this connection.
        store.cursor = "100"
        try await store.advanceCursor("5", on: socket)
        await fulfillment(of: [received], timeout: 5)
        guard case .ack(let acknowledgement) = frame else { return XCTFail("Expected an ACK frame") }
        XCTAssertEqual(acknowledgement.cursor, "5", "ACK must not exceed the frame actually delivered on this socket.")
        XCTAssertEqual(store.cursor, "100", "Persisted snapshot state must never move backwards.")
    }
}
