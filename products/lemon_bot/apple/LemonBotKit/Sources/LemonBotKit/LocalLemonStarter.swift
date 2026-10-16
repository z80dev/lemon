import Foundation

/// Builds the command copied for the user to paste into Terminal.
///
/// The sandboxed app never spawns Lemon itself or writes executable scripts.
/// Every interpolated value is single-quoted, and only absolute, control-free paths are accepted.
public enum LemonStartCommand {
    public static let lemonCandidates = ["/.lemon/bin/lemon", "/.local/bin/lemon", "/bin/lemon"]
    public static let systemLemonCandidates = ["/opt/homebrew/bin/lemon", "/usr/local/bin/lemon"]
    public static let bunCandidates = ["/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
    public static let backendDirectory = "products/lemon_bot/backend"

    public enum BuildError: Error, Equatable, Sendable {
        case invalidCheckout
    }

    /// POSIX single-quote quoting: safe for any string without NUL.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func isSafeAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    /// `checkout` is the Lemon checkout that contains `products/lemon_bot/backend`; `home` the real user home.
    public static func command(checkout: String, home: String) throws -> String {
        guard isSafeAbsolutePath(checkout), isSafeAbsolutePath(home) else { throw BuildError.invalidCheckout }
        let lemonPaths = (lemonCandidates.map { home + $0 } + systemLemonCandidates + [checkout + "/bin/lemon"]).map(shellQuote).joined(separator: " ")
        let bunPaths = (bunCandidates.map { bunPath in bunPath.hasPrefix("/.") ? home + bunPath : bunPath }).map(shellQuote).joined(separator: " ")
        return """
        (
        # Starts Lemon and Lemon Bot as the current Terminal user.
        pick() { for c in "$@"; do [ -x "$c" ] && { printf '%s\\n' "$c"; return 0; }; done; return 1; }
        lemon=$(pick \(lemonPaths)) || { echo "Couldn't find the lemon command."; exit 1; }
        bun=$(pick \(bunPaths)) || { echo "Couldn't find bun."; exit 1; }
        cd \(shellQuote(checkout)) || { echo "Couldn't open the Lemon checkout."; exit 1; }
        "$lemon" start &
        exec "$bun" run --cwd \(shellQuote(backendDirectory)) start
        )

        """
    }
}

/// Progress of a start attempt; the UI renders this directly.
public enum LemonStartState: Equatable, Sendable {
    case idle
    case openingTerminal
    case waitingForHealth(attempt: Int, of: Int)
    case started
    case failed(reason: String)

    public var isBusy: Bool {
        switch self {
        case .openingTerminal, .waitingForHealth: return true
        case .idle, .started, .failed: return false
        }
    }
}

public protocol TerminalHandoff: Sendable {
    /// Copies `command` to the clipboard and opens Terminal without executing anything.
    func open(command: String) async throws
}

/// Hands off to Terminal, then polls health; success only after a health check passes.
public struct LocalLemonStarter: Sendable {
    public static let checkoutDefaultsKey = "lemonCheckoutPath"
    public static let maxReasonLength = 300

    let handoff: TerminalHandoff
    let isHealthy: @Sendable () async -> Bool
    let checkout: @Sendable () -> String?
    let homeDirectory: String
    let healthAttempts: Int
    let healthInterval: Duration

    public init(handoff: TerminalHandoff,
                isHealthy: @escaping @Sendable () async -> Bool,
                checkout: @escaping @Sendable () -> String? = { UserDefaults.standard.string(forKey: LocalLemonStarter.checkoutDefaultsKey) },
                homeDirectory: String,
                healthAttempts: Int = 60,
                healthInterval: Duration = .seconds(1)) {
        self.handoff = handoff; self.isHealthy = isHealthy; self.checkout = checkout
        self.homeDirectory = homeDirectory; self.healthAttempts = max(healthAttempts, 1); self.healthInterval = healthInterval
    }

    /// Configured checkout if set, else `~/lemon`.
    public func checkoutPath() -> String {
        if let configured = checkout()?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty { return configured }
        return homeDirectory + "/lemon"
    }

    /// Reports each state through `onState`; returns the terminal state.
    /// Cancellation observed after a health check takes precedence over a healthy result.
    @discardableResult
    public func start(onState: @Sendable (LemonStartState) -> Void = { _ in }) async -> LemonStartState {
        func finish(_ state: LemonStartState) -> LemonStartState { onState(state); return state }
        if Task.isCancelled { return finish(.failed(reason: "Start was cancelled.")) }
        onState(.openingTerminal)
        let command: String
        do { command = try LemonStartCommand.command(checkout: checkoutPath(), home: homeDirectory) }
        catch { return finish(.failed(reason: "The Lemon checkout path must be an absolute path. Set it and try again.")) }
        do { try await handoff.open(command: command) }
        catch { return finish(.failed(reason: bounded("Couldn’t prepare Terminal: " + error.localizedDescription))) }
        for attempt in 1...healthAttempts {
            if Task.isCancelled { return finish(.failed(reason: "Start was cancelled.")) }
            onState(.waitingForHealth(attempt: attempt, of: healthAttempts))
            let healthy = await isHealthy()
            if Task.isCancelled { return finish(.failed(reason: "Start was cancelled.")) }
            if healthy { return finish(.started) }
            if attempt < healthAttempts { try? await Task.sleep(for: healthInterval) }
        }
        return finish(.failed(reason: "The command was copied, but Lemon Bot didn’t become healthy in time. Paste it into Terminal and press Return; check Terminal for errors, then try again."))
    }

    func bounded(_ text: String) -> String {
        let clean = redact(text).split(whereSeparator: \.isNewline).joined(separator: " ")
        return clean.count > Self.maxReasonLength ? String(clean.prefix(Self.maxReasonLength - 1)) + "…" : clean
    }

    /// Removes secrets and the home directory from text that may be shown or copied.
    func redact(_ text: String) -> String {
        var out = homeDirectory.count > 1 ? text.replacingOccurrences(of: homeDirectory, with: "~") : text
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b[A-Za-z0-9_]*(token|secret|password|passwd|api[_-]?key|authorization)[A-Za-z0-9_]*\s*[=:]\s*\S+"#,
            #"\b(sk|pk|ghp|gho|xox[abp])[-_][A-Za-z0-9_-]{10,}"#,
            #"\b[A-Za-z0-9+/_-]{32,}={0,2}"#
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return out
    }
}

#if os(macOS)
import AppKit

/// Copies a command and opens Terminal via NSWorkspace; no script or Apple Events.
public struct TerminalWorkspaceHandoff: TerminalHandoff {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
    }
    public init() {}

    @MainActor public func open(command: String) async throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(command, forType: .string) else {
            throw Failure(errorDescription: "couldn’t copy the command")
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            throw Failure(errorDescription: "Terminal isn’t available")
        }
        _ = try await NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
#endif
