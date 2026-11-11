import XCTest
@testable import LemonBotKit

final class HostEnrollmentTests: XCTestCase {
    private let release = "curl -fsSL --proto '=https' --proto-redir '=https' 'https://github.com/z80dev/lemon/releases/download/v2026.10.22/join-node.sh' | bash -s -- '--name' 'chico' '--controller' 'ws://127.0.0.1:4040/ws' '--version' '2026.10.22' '--base-url' 'https://github.com/z80dev/lemon'"

    func testAutomaticRepairNeverRetriesRunningOrFailedAttempts() {
        XCTAssertTrue(HostSetupState.idle.allowsAutomaticAttempt)
        XCTAssertTrue(HostSetupState.done.allowsAutomaticAttempt)
        XCTAssertFalse(HostSetupState.running("Starting").allowsAutomaticAttempt)
        XCTAssertFalse(HostSetupState.failed(message: "Unavailable", detail: nil).allowsAutomaticAttempt)
    }

    func testReleaseAndSourceJoinCommandsYieldTheirTargets() throws {
        XCTAssertEqual(try HostEnrollment.target(fromJoinCommand: release),
                       .init(name: "chico", controller: "ws://127.0.0.1:4040/ws", source: nil, version: "2026.10.22", baseURL: "https://github.com/z80dev/lemon"))
        let source = "bash '/Users/me/lemon/scripts/join-node.sh' '--name' 'studio' '--controller' 'wss://controller.example/ws' '--source' '/Users/me/lemon'"
        XCTAssertEqual(try HostEnrollment.target(fromJoinCommand: source),
                       .init(name: "studio", controller: "wss://controller.example/ws", source: "/Users/me/lemon", version: nil, baseURL: nil))
    }

    func testJoinValuesThatWouldNeedEscapingAreRefused() {
        for command in [
            release.replacingOccurrences(of: "'chico'", with: "'chico; rm -rf ~'"),
            release.replacingOccurrences(of: "ws://127.0.0.1:4040/ws", with: "ws://evil.example/ws"),
            release.replacingOccurrences(of: "ws://127.0.0.1:4040/ws", with: "wss://host/ws?token=x"),
            release.replacingOccurrences(of: "https://github.com/z80dev/lemon'", with: "http://github.com/z80dev/lemon'"),
            release.replacingOccurrences(of: "'2026.10.22' '--base-url'", with: "'$(id)' '--base-url'"),
            "bash '/x/join-node.sh' '--name' 'a' '--controller' 'ws://127.0.0.1:4040/ws' '--source' 'relative/path'",
        ] {
            XCTAssertThrowsError(try HostEnrollment.target(fromJoinCommand: command), command)
        }
    }

    func testHostIdentityBecomesAValidNodeNameAndFriendlyName() {
        let mac = HostEnrollment.identity("host=Chico\ncomputer=Ada’s MacBook Pro\nstatus=ready\n")
        XCTAssertEqual(mac.nodeName, "chico"); XCTAssertEqual(mac.displayName, "Ada’s MacBook Pro")
        let linux = HostEnrollment.identity("host=build_box-01\nstatus=ready\n")
        XCTAssertEqual(linux.nodeName, "build_box-01"); XCTAssertEqual(linux.displayName, "build_box-01")
        XCTAssertEqual(HostEnrollment.nodeName(fromHostname: "--Ünïcode Host!"), "ncodehost")
        XCTAssertEqual(HostEnrollment.nodeName(fromHostname: "!!!"), "lemon-host")
    }

    func testCodeTravelsQuotedInsideTheScriptNotAsAnArgument() throws {
        let target = try HostEnrollment.target(fromJoinCommand: release)
        let script = HostEnrollment.script(target, code: "A1b2_c3-" + String(repeating: "x", count: 35))
        XCTAssertTrue(script.hasPrefix("name='chico'\ncontroller='ws://127.0.0.1:4040/ws'\n"))
        XCTAssertTrue(script.contains("code='A1b2_c3-"))
        XCTAssertTrue(HostEnrollment.script(target, code: nil).contains("code=''"))
    }

    func testScriptStatusesMapToOutcomesAndFailures() throws {
        XCTAssertEqual(try HostEnrollment.parse("status=ready\n", machine: "m"), .ready)
        XCTAssertEqual(try HostEnrollment.parse("status=needs_enrollment\n", machine: "m"), .needsEnrollment)
        XCTAssertThrowsError(try HostEnrollment.parse("status=runtime_missing\n", machine: "m")) { XCTAssertEqual($0 as? HostEnrollment.Failure, .runtimeMissing(machine: "m")) }
        XCTAssertThrowsError(try HostEnrollment.parse("status=enroll_failed\nlog=refused\n", machine: "m")) { XCTAssertEqual($0 as? HostEnrollment.Failure, .enrollmentFailed(machine: "m", log: "refused")) }
        XCTAssertThrowsError(try HostEnrollment.parse("motd\n", machine: "m")) { XCTAssertEqual($0 as? HostEnrollment.Failure, .unexpected(detail: "The setup script returned no result.")) }
    }

    func testGeneratedScriptIsValidShell() throws {
        let script = HostEnrollment.script(try HostEnrollment.target(fromJoinCommand: release), code: nil)
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-n"]
        process.standardInput = input
        try process.run(); input.fileHandleForWriting.write(Data(script.utf8)); try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    func testScriptReturnsNeedsEnrollmentImmediatelyWhenLogHasNeedsReauthorization() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("host-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockBin = tempDir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: mockBin, withIntermediateDirectories: true)

        let lemonScript = """
        #!/bin/sh
        if [ "$1" = "node" ] && [ "$2" = "capabilities" ]; then
            exit 0
        fi
        if [ "$1" = "node" ] && [ "$2" = "join" ]; then
            echo "Execution node needs_reauthorization (session_expired): token expired"
            exit 0
        fi
        exit 0
        """
        let lemonPath = mockBin.appendingPathComponent("lemon")
        try lemonScript.write(to: lemonPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lemonPath.path)

        let launchctlScript = """
        #!/bin/sh
        if [ "$1" = "bootstrap" ]; then
            mkdir -p "$HOME/.lemon/logs"
            echo "Execution node needs_reauthorization (session_expired): token expired" >> "$HOME/.lemon/logs/node-chico.log"
        fi
        exit 0
        """
        let launchctlPath = mockBin.appendingPathComponent("launchctl")
        try launchctlScript.write(to: launchctlPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctlPath.path)

        let systemctlScript = """
        #!/bin/sh
        if echo "$*" | grep -q "enable"; then
            mkdir -p "$HOME/.lemon/logs"
            echo "Execution node needs_reauthorization (session_expired): token expired" >> "$HOME/.lemon/logs/node-chico.log"
        fi
        exit 0
        """
        let systemctlPath = mockBin.appendingPathComponent("systemctl")
        try systemctlScript.write(to: systemctlPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemctlPath.path)

        let sleepScript = "#!/bin/sh\nexit 0\n"
        let sleepPath = mockBin.appendingPathComponent("sleep")
        try sleepScript.write(to: sleepPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sleepPath.path)

        let target = HostEnrollment.JoinTarget(
            name: "chico",
            controller: "ws://127.0.0.1:4040/ws",
            source: tempDir.path,
            version: nil,
            baseURL: nil
        )
        let script = HostEnrollment.script(target, code: nil)

        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.environment = [
            "HOME": tempDir.path,
            "PATH": mockBin.path + ":/usr/bin:/bin"
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        let outText = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertLessThan(elapsed, 10.0, "Script should have returned early without waiting 60s timeout")
        XCTAssertTrue(outText.contains("status=needs_enrollment"), "Output was: \(outText)")
        let outcome = try HostEnrollment.parse(outText, machine: "chico")
        XCTAssertEqual(outcome, .needsEnrollment)
    }
}
