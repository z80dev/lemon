import XCTest
@testable import LemonBotKit

final class HostEnrollmentTests: XCTestCase {
    func testAutomaticRepairNeverRetriesRunningOrFailedAttempts() {
        XCTAssertTrue(HostSetupState.idle.allowsAutomaticAttempt)
        XCTAssertTrue(HostSetupState.done.allowsAutomaticAttempt)
        XCTAssertFalse(HostSetupState.running("Starting").allowsAutomaticAttempt)
        XCTAssertFalse(HostSetupState.failed(message: "Unavailable", detail: nil).allowsAutomaticAttempt)
    }

    func testNDJSONStepsMapToHostSetupAndResultKeepsMachineIdentity() throws {
        let output = #"""
        {"type":"step","step":"units","state":"running","detail":null}
        {"type":"step","step":"worker","state":"running","detail":"repair"}
        {"type":"result","status":"ready","port":4100,"machineId":"machine_studio","manager":"launchd","persistence":"login"}
        """#
        XCTAssertEqual(BootstrapProgress.line(String(output.split(separator: "\n")[0]))?.hostSetup, .running("Starting Lemon services…"))
        XCTAssertEqual(BootstrapProgress.line(String(output.split(separator: "\n")[1]))?.hostSetup, .running("Setting up Lemon’s worker…"))
        let result = try BootstrapProgress.result(output)
        XCTAssertEqual(try result.requireMachine(machine: "studio"), "machine_studio")
        XCTAssertEqual(result.persistence, "login")
        XCTAssertNil(result.hostSetup)
        XCTAssertNil(BootstrapProgress.line("not json"))
        XCTAssertNil(BootstrapProgress.line(#"{"type":"step","step":"worker","state":"ok"}"#)?.hostSetup)
        XCTAssertThrowsError(try BootstrapProgress.result(output + "\n" + output))
        XCTAssertThrowsError(try BootstrapProgress.result("Welcome to my server\n"))
    }

    func testResultFailuresMapWithoutExposingRawCommandOutput() throws {
        for (status, expected) in [
            ("runtime_missing", HostEnrollment.Failure.runtimeMissing(machine: "m")),
            ("needs_attention", .runtimeMissing(machine: "m")),
            ("enroll_failed", .enrollmentFailed(machine: "m", log: "enroll_failed")),
            ("service_failed", .serviceFailed(machine: "m", log: "service_failed")),
            ("setup_required", .serviceFailed(machine: "m", log: "setup_required")),
        ] {
            let result = try BootstrapProgress.result("{\"type\":\"result\",\"status\":\"\(status)\"}")
            XCTAssertThrowsError(try result.requireMachine(machine: "m")) { XCTAssertEqual($0 as? HostEnrollment.Failure, expected) }
        }
        XCTAssertThrowsError(try BootstrapProgress.result(#"{"type":"result","status":"ready","machineId":null}"#).requireMachine(machine: "m"))
    }

    func testHostIdentityStillSupportsAutomaticRepairTrigger() {
        XCTAssertEqual(HostEnrollment.nodeName("host=Chico\nstatus=ready\n"), "chico")
        XCTAssertEqual(HostEnrollment.nodeName(fromHostname: "build_box-01"), "build_box-01")
        XCTAssertEqual(HostEnrollment.nodeName(fromHostname: "--Ünïcode Host!"), "ncodehost")
        XCTAssertEqual(HostEnrollment.nodeName(fromHostname: "!!!"), "lemon-host")
    }

    func testHostScriptDelegatesLifecycleWithoutInviteOrSupervisorImplementation() {
        XCTAssertTrue(HostEnrollment.setupScript.contains("up --json --no-open"))
        XCTAssertTrue(HostEnrollment.setupScript.contains("--worker-wrapper"))
        for obsolete in ["nohup", "pkill", "launchctl", "systemctl", "invite-code"] {
            XCTAssertFalse(HostEnrollment.setupScript.contains(obsolete))
        }
    }

    func testGeneratedScriptIsValidShell() throws {
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh"); process.arguments = ["-n"]
        process.standardInput = input
        try process.run(); input.fileHandleForWriting.write(Data(HostEnrollment.setupScript.utf8)); try input.fileHandleForWriting.close()
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
