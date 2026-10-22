import XCTest
@testable import LemonBotKit

final class HostEnrollmentTests: XCTestCase {
    private let release = "curl -fsSL --proto '=https' --proto-redir '=https' 'https://github.com/z80dev/lemon/releases/download/v2026.10.22/join-node.sh' | bash -s -- '--name' 'chico' '--controller' 'ws://127.0.0.1:4040/ws' '--version' '2026.10.22' '--base-url' 'https://github.com/z80dev/lemon'"

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
}
