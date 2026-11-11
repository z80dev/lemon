import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private enum Grant: String, Encodable {
    case granted
    case denied
    case unknown

    init(_ allowed: Bool) {
        self = allowed ? .granted : .denied
    }
}

private struct PermissionStatus: Encodable {
    let version = 1
    let accessibility: Grant
    let screenRecording: Grant
    let postEvent: Grant
    let listenEvent: Grant
    let fullDiskAccess: Grant
}

private func fullDiskAccess(home: URL) -> Grant {
    let database = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    let descriptor = open(database.path, O_RDONLY)
    if descriptor >= 0 {
        close(descriptor)
        return .granted
    }
    return errno == EPERM || errno == EACCES ? .denied : .unknown
}

let home = FileManager.default.homeDirectoryForCurrentUser
let mode: Arguments.Mode

do {
    mode = try Arguments.parse(Array(CommandLine.arguments.dropFirst()), home: home.path)
} catch {
    fputs(Arguments.usage + "\n", stderr)
    exit(64)
}

switch mode {
case .exec(let program, _):
    // The strict exec form puts the target's argv directly after the separator.
    // Reuse it rather than spawning a child or copying its C strings.
    execv(program, CommandLine.unsafeArgv.advanced(by: 2))
    perror("Lemon Bot Worker: execv")
    exit(71)
case .status:
    let status = PermissionStatus(
        accessibility: Grant(AXIsProcessTrusted()),
        screenRecording: Grant(CGPreflightScreenCaptureAccess()),
        postEvent: Grant(CGPreflightPostEventAccess()),
        listenEvent: Grant(CGPreflightListenEventAccess()),
        fullDiskAccess: fullDiskAccess(home: home)
    )
    do {
        var data = try JSONEncoder().encode(status)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    } catch {
        fputs("Lemon Bot Worker: could not encode permission status\n", stderr)
        exit(71)
    }
case .request(.screenRecording):
    _ = CGRequestScreenCaptureAccess()
case .request(.accessibility):
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
    _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
}

exit(0)
