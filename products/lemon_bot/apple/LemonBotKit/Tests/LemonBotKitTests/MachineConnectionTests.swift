import XCTest
import Foundation
@testable import LemonBotKit

final class MachineConnectionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("machine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        TestHTTPProtocol.requests = []; TestHTTPProtocol.handler = nil
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        TestHTTPProtocol.handler = nil; TestHTTPProtocol.requests = []
    }

    func testSSHDestinationsAcceptWhatPeopleTypeAndRejectInjection() {
        XCTAssertEqual(MachineRoute.sshHost("  me@studio.local "), "me@studio.local")
        XCTAssertEqual(MachineRoute.sshHost("ssh devbox"), "devbox")
        XCTAssertEqual(MachineRoute.sshHost("me@[fe80::1%en0]"), "me@[fe80::1%en0]")
        for bad in ["", "-oProxyCommand=sh", "ssh -p 22 host", "host; rm -rf /", "a b", "me@", "@host", "$(id)", "host\nother"] {
            XCTAssertNil(MachineRoute.sshHost(bad), bad)
        }
    }

    func testTunnelPortIsStablePerHostAndCaseInsensitive() {
        let port = MachineRoute.tunnelPort(for: "me@Studio")
        XCTAssertEqual(port, MachineRoute.tunnelPort(for: "me@studio"))
        XCTAssertTrue((41_000..<42_000).contains(port))
        XCTAssertNotEqual(port, MachineRoute.tunnelPort(for: "other"))
    }

    func testRouteSurvivesAccountRoundTripAndOldAccountsDecodeWithoutOne() throws {
        let account = StoredAccount(id: "a", baseURL: URL(string: "http://127.0.0.1:41234/v1")!, email: "me@lemon.local", displayName: "Me", token: "t", userID: "u", workspaceID: "w", route: .ssh(host: "me@studio", remotePort: 4100))
        let decoded = try JSONDecoder().decode(StoredAccount.self, from: JSONEncoder().encode(account))
        XCTAssertEqual(decoded.route, .ssh(host: "me@studio", remotePort: 4100))
        XCTAssertEqual(decoded.location, "me@studio")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        legacy.removeValue(forKey: "route")
        let old = try JSONDecoder().decode(StoredAccount.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.route)
        XCTAssertEqual(old.location, "127.0.0.1")
    }

    func testLocalAccessSendsOnlyTheMachineKeyAndName() async throws {
        let key = String(repeating: "ab", count: 32)
        TestHTTPProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/auth/local")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
            let body = try JSONSerialization.jsonObject(with: TestHTTPProtocol.body(request)) as? [String: String]
            XCTAssertEqual(body, ["displayName": "Ada"])
            return (200, [:], WireFixtures.pairedAuth)
        }
        let auth = try await HTTPTransport(baseURL: URL(string: "http://127.0.0.1:4100")!, token: key, session: TestHTTPProtocol.session()).localAccess(displayName: "Ada")
        XCTAssertFalse(auth.token.isEmpty)
    }

    // MARK: Bootstrap script, run under /bin/sh with an isolated HOME and fake curl/lemon-bot.

    private var home: URL { root.appendingPathComponent("home") }
    private var data: URL { home.appendingPathComponent(".lemon/lemon_bot") }

    private func executable(_ path: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body).write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }
    /// `curl` answers only once `marker` exists: the stand-in for a listening backend.
    private func fakeCurl() throws {
        try executable(root.appendingPathComponent("bin/curl"), "[ -f \"\(root.path)/up\" ]\n")
    }
    private func runScript() throws -> String {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s", "--", root.appendingPathComponent("no-checkout").path]
        process.environment = ["HOME": home.path, "PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(MachineBootstrap.script.utf8)); try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text
    }
    private func writeKey(_ key: String) throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try (key + "\n").write(to: data.appendingPathComponent("local-access.key"), atomically: true, encoding: .utf8)
    }

    func testRunningLemonBotReturnsItsKeyWithoutStartingAnything() throws {
        try fakeCurl(); FileManager.default.createFile(atPath: root.appendingPathComponent("up").path, contents: nil)
        try writeKey(String(repeating: "C", count: 64))
        let ready = try MachineBootstrap.parse(runScript(), machine: "this Mac")
        XCTAssertEqual(ready, .init(port: 4100, key: String(repeating: "c", count: 64), started: false))
    }

    func testStoppedLemonBotIsStartedDetachedThenReadyWithItsKey() throws {
        try fakeCurl()
        let key = String(repeating: "d", count: 64)
        // The installed launcher "starts" by writing its key and coming up.
        try executable(home.appendingPathComponent(".lemon/lemon_bot/current/bot/bin/lemon-bot"),
                       "[ \"$1\" = --no-open ] || exit 2\nprintf '%s\\n' \(key) > \"$HOME/.lemon/lemon_bot/local-access.key\"\ntouch \"\(root.path)/up\"\n")
        let ready = try MachineBootstrap.parse(runScript(), machine: "this Mac")
        XCTAssertEqual(ready, .init(port: 4100, key: key, started: true))
        let mode = try FileManager.default.attributesOfItem(atPath: data.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testMissingInstallAndOldBackendAreDistinctFailures() throws {
        try fakeCurl()
        XCTAssertThrowsError(try MachineBootstrap.parse(runScript(), machine: "studio")) {
            XCTAssertEqual($0 as? MachineConnectionError, .notInstalled(machine: "studio"))
        }
        FileManager.default.createFile(atPath: root.appendingPathComponent("up").path, contents: nil)
        XCTAssertThrowsError(try MachineBootstrap.parse(runScript(), machine: "studio")) {
            XCTAssertEqual($0 as? MachineConnectionError, .outdated(machine: "studio"))
        }
    }

    func testParseRejectsMalformedKeysAndKeepsStartLog() {
        XCTAssertThrowsError(try MachineBootstrap.parse("port=4100\nkey=nothex\nstatus=ready\n", machine: "m")) {
            XCTAssertEqual($0 as? MachineConnectionError, .outdated(machine: "m"))
        }
        XCTAssertThrowsError(try MachineBootstrap.parse("status=start_failed\nlog=EADDRINUSE\nlog=exit 1\n", machine: "m")) {
            XCTAssertEqual($0 as? MachineConnectionError, .startFailed(machine: "m", log: "EADDRINUSE\nexit 1"))
        }
        XCTAssertThrowsError(try MachineBootstrap.parse("Welcome to my server\n", machine: "m")) {
            XCTAssertEqual($0 as? MachineConnectionError, .unexpected(detail: "The setup script returned no result."))
        }
    }
}
