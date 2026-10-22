import Foundation

/// How this Mac reaches a Lemon Bot it signs into with that machine's private local-access key.
/// Being the same OS user (or having SSH access) is the proof; there is no password.
public enum MachineRoute: Codable, Hashable, Sendable {
    case thisMac
    /// `host` is anything `ssh` accepts: `user@host` or a `~/.ssh/config` alias.
    case ssh(host: String, remotePort: Int)

    public var title: String {
        switch self {
        case .thisMac: return "This Mac"
        case .ssh(let host, _): return host
        }
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_@:[]%")

    /// Accepts what a person types for `ssh` (an optional leading `ssh ` is dropped).
    /// Rejects option injection, whitespace and shell or control characters.
    public static func sshHost(_ input: String) -> String? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("ssh ") { value = String(value.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        guard !value.isEmpty, value.count <= 255, !value.hasPrefix("-"), !value.hasPrefix("@"), !value.hasSuffix("@"),
              value.unicodeScalars.allSatisfy(hostCharacters.contains) else { return nil }
        return value
    }

    /// A stable loopback port per SSH host, so a saved account keeps one base URL across launches.
    public static func tunnelPort(for host: String) -> Int {
        var hash: UInt32 = 2_166_136_261
        for byte in host.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return 41_000 + Int(hash % 1_000)
    }
}

public enum MachineConnectionError: LocalizedError, Equatable {
    case invalidHost
    case sshFailed(host: String, detail: String)
    case notInstalled(machine: String)
    case outdated(machine: String)
    case startFailed(machine: String, log: String)
    case tunnelFailed(host: String, detail: String)
    case unexpected(detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "Enter an SSH destination such as me@studio or an alias from your SSH config."
        case .sshFailed(let host, _):
            return "Couldn’t connect to \(host) over SSH. Make sure “ssh \(host)” works in Terminal without asking for a password."
        case .notInstalled(let machine):
            return "Lemon Bot isn’t installed on \(machine)."
        case .outdated(let machine):
            return "Lemon Bot on \(machine) is running an older version. Update and restart it, then connect again."
        case .startFailed(let machine, _):
            return "Lemon Bot on \(machine) didn’t start."
        case .tunnelFailed(let host, _):
            return "Connected to \(host), but couldn’t open a tunnel to its Lemon Bot."
        case .unexpected:
            return "Lemon Bot couldn’t finish connecting."
        }
    }

    /// Diagnostic text from ssh or the Lemon Bot log; never contains the access key.
    public var detail: String? {
        switch self {
        case .sshFailed(_, let detail), .tunnelFailed(_, let detail), .unexpected(let detail): return detail.isEmpty ? nil : detail
        case .startFailed(_, let log): return log.isEmpty ? nil : log
        case .invalidHost, .notInstalled, .outdated: return nil
        }
    }
}

/// Finds (or starts) Lemon Bot on the target machine and reads its local-access key.
/// The same POSIX script runs here (`sh -s -- <checkout>`) and over SSH (`ssh host sh -s`).
public enum MachineBootstrap {
    public struct Ready: Equatable, Sendable {
        public let port: Int
        public let key: String
        public let started: Bool
    }

    public static let installCommand = "curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --profile lemon_bot"

    /// Prints `port=`, `key=` and `status=ready`, or `status=not_installed|outdated|start_failed` (with `log=` lines).
    public static let script = #"""
    set -u
    data="${LEMON_BOT_DATA_DIR:-$HOME/.lemon/lemon_bot}"
    port="${LEMON_BOT_PORT:-4100}"
    up() {
      if command -v curl >/dev/null 2>&1; then curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$port/v1/setup" 2>/dev/null
      elif command -v wget >/dev/null 2>&1; then wget -q -T 2 -O /dev/null "http://127.0.0.1:$port/v1/setup" 2>/dev/null
      else pgrep -f lemon-bot >/dev/null 2>&1
      fi
    }
    pick() { for c in "$@"; do [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }; done; return 1; }
    if ! up; then
      if bot=$(pick "$HOME/.lemon/lemon_bot/current/bot/bin/lemon-bot" "$HOME/.local/bin/lemon-bot" "$HOME/.lemon/bin/lemon-bot" "$(command -v lemon-bot 2>/dev/null)"); then
        set -- "$bot" --no-open
      elif [ -n "${1:-}" ] && [ -f "$1/products/lemon_bot/backend/src/cli.ts" ] && bun=$(pick "$HOME/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun "$(command -v bun 2>/dev/null)"); then
        set -- "$bun" run --cwd "$1/products/lemon_bot/backend" start --no-open
      else
        echo status=not_installed; exit 0
      fi
      mkdir -p "$data" && chmod 700 "$data"
      if command -v setsid >/dev/null 2>&1; then setsid nohup "$@" </dev/null >>"$data/lemon-bot.log" 2>&1 &
      else nohup "$@" </dev/null >>"$data/lemon-bot.log" 2>&1 &
      fi
      tries=0
      until up; do
        tries=$((tries + 1))
        if [ "$tries" -ge 60 ]; then echo status=start_failed; tail -n 8 "$data/lemon-bot.log" 2>/dev/null | sed 's/^/log=/'; exit 0; fi
        sleep 1
      done
      echo started=1
    fi
    key=$(head -n 1 "$data/local-access.key" 2>/dev/null) || key=
    [ -n "$key" ] || { echo status=outdated; exit 0; }
    echo "port=$port"
    echo "key=$key"
    echo status=ready
    """#

    public static func parse(_ output: String, machine: String) throws -> Ready {
        var values: [String: String] = [:]
        var log: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<separator]), value = String(line[line.index(after: separator)...])
            if name == "log" { log.append(value) } else { values[name] = value }
        }
        switch values["status"] {
        case "ready":
            guard let port = values["port"].flatMap(Int.init), (1...65_535).contains(port),
                  let key = values["key"], key.count == 64, key.allSatisfy(\.isHexDigit) else { throw MachineConnectionError.outdated(machine: machine) }
            return Ready(port: port, key: key.lowercased(), started: values["started"] == "1")
        case "not_installed": throw MachineConnectionError.notInstalled(machine: machine)
        case "outdated": throw MachineConnectionError.outdated(machine: machine)
        case "start_failed": throw MachineConnectionError.startFailed(machine: machine, log: log.joined(separator: "\n"))
        default: throw MachineConnectionError.unexpected(detail: "The setup script returned no result.")
        }
    }
}

#if os(macOS)
import AppKit

struct CommandOutput: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs a short-lived command with `input` on stdin; the timeout terminates it.
enum CommandRunner {
    static var environment: [String: String] {
        var values = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        values["PATH"] = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.bun/bin"].joined(separator: ":")
        return values
    }

    static func run(_ executable: String, _ arguments: [String], input: String, timeout: TimeInterval) async throws -> CommandOutput {
        try await Task.detached(priority: .userInitiated) { try runBlocking(executable, arguments, input: input, timeout: timeout) }.value
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: Data] = [:]
        func set(_ index: Int, _ data: Data) { lock.withLock { values[index] = data } }
        func text(_ index: Int) -> String { lock.withLock { String(decoding: values[index] ?? Data(), as: UTF8.self) } }
    }

    private static func runBlocking(_ executable: String, _ arguments: [String], input: String, timeout: TimeInterval) throws -> CommandOutput {
        let process = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try? stdin.fileHandleForWriting.close()
        let reading = DispatchGroup(), collected = Collected()
        for (index, pipe) in [stdout, stderr].enumerated() {
            DispatchQueue.global().async(group: reading) { collected.set(index, pipe.fileHandleForReading.readDataToEndOfFile()) }
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        process.waitUntilExit()
        deadline.cancel()
        // A detached grandchild must never hold these pipes; don't wait on one that does.
        _ = reading.wait(timeout: .now() + 2)
        return CommandOutput(status: process.terminationStatus, stdout: collected.text(0), stderr: collected.text(1))
    }

    static func ssh(_ host: String, _ options: [String] = []) -> [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new"] + options + ["--", host]
    }

    /// Last lines of ssh's stderr: enough to tell auth, DNS and host-key failures apart.
    static func summary(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
    }
}

extension MachineBootstrap {
    /// Lemon checkout used when no installed `lemon-bot` exists (source development).
    public static let checkoutDefaultsKey = "lemonCheckoutPath"

    static func ensure(_ route: MachineRoute) async throws -> Ready {
        switch route {
        case .thisMac:
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let checkout = UserDefaults.standard.string(forKey: checkoutDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let output = try await CommandRunner.run("/bin/sh", ["-s", "--", checkout.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? home + "/lemon"], input: script, timeout: 90)
            return try parse(output.stdout, machine: "this Mac")
        case .ssh(let host, _):
            let output = try await CommandRunner.run("/usr/bin/ssh", CommandRunner.ssh(host, ["-T"]) + ["sh", "-s"], input: script, timeout: 100)
            // 255 is ssh's own failure; anything else came from the remote script or shell.
            if output.status == 255 || !output.stdout.contains("status=") {
                throw MachineConnectionError.sshFailed(host: host, detail: CommandRunner.summary(output.stderr))
            }
            return try parse(output.stdout, machine: host)
        }
    }
}

/// Keeps one `ssh -N -L` tunnel for the active SSH account and restarts it if it drops.
@MainActor public final class SSHTunnels {
    public static let shared = SSHTunnels()
    private struct Target: Equatable { let host: String; let remotePort: Int; var port: Int { MachineRoute.tunnelPort(for: host) } }
    private var target: Target?
    private var process: Process?
    private var lastError = ""
    private var retryDelay: Duration = .seconds(2)

    /// Opens the tunnel for an SSH route and closes any other; other routes close it.
    /// Returns once the remote Lemon Bot answers through it, or after `wait` elapses.
    @discardableResult
    public func activate(_ route: MachineRoute?, wait: Duration = .seconds(8)) async -> URL? {
        guard case .ssh(let host, let remotePort) = route else { close(); return nil }
        let next = Target(host: host, remotePort: remotePort)
        if next != target { close(); target = next }
        if process?.isRunning != true { spawn() }
        let base = URL(string: "http://127.0.0.1:\(next.port)")!
        let deadline = ContinuousClock.now + wait
        while ContinuousClock.now < deadline, target == next {
            if await Self.answers(base) { retryDelay = .seconds(2); return base }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    func open(host: String, remotePort: Int) async throws -> URL {
        if let base = await activate(.ssh(host: host, remotePort: remotePort), wait: .seconds(20)) { return base }
        throw MachineConnectionError.tunnelFailed(host: host, detail: lastError)
    }

    public func close() {
        target = nil
        let running = process
        process = nil
        if running?.isRunning == true { running?.terminate() }
    }

    private func spawn() {
        guard let target else { return }
        let process = Process(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = CommandRunner.ssh(target.host, [
            "-N", "-T", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(target.port):127.0.0.1:\(target.remotePort)",
        ])
        process.environment = CommandRunner.environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        process.terminationHandler = { [weak self] ended in
            let text = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in self?.ended(ended, stderr: text, target: target) }
        }
        do { try process.run(); self.process = process }
        catch { lastError = error.localizedDescription }
    }

    private func ended(_ ended: Process, stderr: String, target previous: Target) {
        lastError = CommandRunner.summary(stderr)
        guard process === ended else { return }
        process = nil
        guard target == previous else { return }
        // Restart while this account stays active, backing off to a minute.
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(60))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.target == previous, self.process == nil else { return }
            self.spawn()
        }
    }

    private static func answers(_ base: URL) async -> Bool {
        guard let client = try? HTTPTransport(baseURL: base) else { return false }
        defer { client.session.invalidateAndCancel() }
        return (try? await client.read("/setup", timeout: 2, as: SetupStatus.self)) != nil
    }
}

extension LemonBotStore {
    public enum ConnectStep: Equatable, Sendable { case preparing, tunneling, signingIn }

    /// The name a newly created owner gets: this Mac user's full name.
    static var ownerName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    /// One click: find or start Lemon Bot on the machine, read its private key (directly or over SSH),
    /// sign in as its owner (creating the owner on a fresh install) and open the workspace.
    public func connect(to route: MachineRoute, progress: @MainActor (ConnectStep) -> Void = { _ in }) async throws {
        progress(.preparing)
        let ready = try await MachineBootstrap.ensure(route)
        var resolved = route
        let base: URL
        switch route {
        case .thisMac:
            base = URL(string: "http://127.0.0.1:\(ready.port)")!
        case .ssh(let host, _):
            progress(.tunneling)
            resolved = .ssh(host: host, remotePort: ready.port)
            base = try await SSHTunnels.shared.open(host: host, remotePort: ready.port)
        }
        progress(.signingIn)
        let auth = try await HTTPTransport(baseURL: base, token: ready.key, session: httpSession).localAccess(displayName: Self.ownerName)
        let saved = try saveAuthenticatedAccount(auth, baseURL: base, deviceID: nil, installationID: nil, route: resolved)
        try await restoreAccount(saved)
    }

    /// Starts the current account's Lemon Bot if it stopped, then reconnects without signing in again.
    public func startBackend() async throws {
        guard let account else { throw ClientError.signedOut }
        let route = account.route ?? .thisMac
        let ready = try await MachineBootstrap.ensure(route)
        if case .ssh(let host, _) = route { _ = try await SSHTunnels.shared.open(host: host, remotePort: ready.port) }
        try await retryNow()
    }
}
#endif
