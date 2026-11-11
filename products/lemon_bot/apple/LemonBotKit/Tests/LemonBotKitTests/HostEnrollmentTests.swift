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
    func testHostScriptReturnsLifecycleFailureWithoutScrapingWorkerLogs() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("host-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bot = home.appendingPathComponent(".local/bin/lemon-bot")
        try FileManager.default.createDirectory(at: bot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mock = #"""
        #!/bin/sh
        [ "$*" = "up --json --no-open" ] || exit 2
        printf '%s\n' '{"type":"step","step":"worker","state":"running","detail":"repair"}'
        printf '%s\n' '{"type":"result","status":"enroll_failed","port":4100,"machineId":"machine_chico","manager":"launchd","persistence":"login"}'
        exit 1
        """#
        try mock.write(to: bot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bot.path)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-s"]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(HostEnrollment.setupScript.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertThrowsError(try BootstrapProgress.result(text).requireMachine(machine: "chico")) {
            XCTAssertEqual($0 as? HostEnrollment.Failure, .enrollmentFailed(machine: "chico", log: "enroll_failed"))
        }
    }
}
