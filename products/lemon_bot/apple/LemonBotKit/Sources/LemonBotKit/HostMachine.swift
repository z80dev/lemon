import Foundation

/// Progress of making the connected machine a Bot machine. The sidebar renders it directly.
public enum HostSetupState: Equatable, Sendable {
    case idle
    case running(String)
    case failed(message: String, detail: String?)
    case done

    public var allowsAutomaticAttempt: Bool {
        switch self {
        case .idle, .done: return true
        case .running, .failed: return false
        }
    }
}

/// Local CLI progress, not a product protocol resource. Credentials never appear in these events.
public struct BootstrapProgress: Decodable, Equatable, Sendable {
    public let type: String
    public let step: String?
    public let state: String?
    public let detail: String?
    public let status: String?
    public let port: Int?
    public let machineId: String?
    public let manager: String?
    public let persistence: String?
    public let installCommand: String?

    public static func line(_ line: String) -> BootstrapProgress? {
        try? JSONDecoder().decode(Self.self, from: Data(line.utf8))
    }

    public static func result(_ output: String) throws -> BootstrapProgress {
        let results = output.split(whereSeparator: \.isNewline).compactMap { line(String($0)) }.filter { $0.type == "result" }
        guard results.count == 1, let result = results.first, result.status != nil else {
            throw HostEnrollment.Failure.unexpected(detail: "The setup command returned no unique result.")
        }
        return result
    }

    public var hostSetup: HostSetupState? {
        guard type == "step", state == "running" else { return nil }
        let text: String
        switch step {
        case "runtime": text = "Checking Lemon…"
        case "controller_choice": text = "Checking the controller…"
        case "setup": text = "Finishing Lemon setup…"
        case "units": text = "Starting Lemon services…"
        case "linger": text = "Checking background persistence…"
        case "owner": text = "Signing in on this machine…"
        case "machine": text = "Checking this Bot machine…"
        case "worker": text = "Setting up Lemon’s worker…"
        default: return nil
        }
        return .running(text)
    }

    public func requireMachine(machine: String) throws -> String {
        switch status {
        case "ready":
            guard let machineId, !machineId.isEmpty else { throw HostEnrollment.Failure.unexpected(detail: "No local machine was enrolled. Check whether the selected controller is remote.") }
            return machineId
        case "runtime_missing", "needs_attention": throw HostEnrollment.Failure.runtimeMissing(machine: machine)
        case "enroll_failed": throw HostEnrollment.Failure.enrollmentFailed(machine: machine, log: status ?? "")
        case "service_failed", "setup_required": throw HostEnrollment.Failure.serviceFailed(machine: machine, log: status ?? "")
        default: throw HostEnrollment.Failure.unexpected(detail: "The setup command returned an unsupported result.")
        }
    }
}

/// Native clients delegate supervision and invite handling entirely to `lemon-bot up`.
public enum HostEnrollment {
    public enum Failure: LocalizedError, Equatable {
        case runtimeMissing(machine: String)
        case enrollmentFailed(machine: String, log: String)
        case serviceFailed(machine: String, log: String)
        case unexpected(detail: String)

        public var errorDescription: String? {
            switch self {
            case .runtimeMissing(let machine): return "Lemon on \(machine) is missing or incompatible. Update Lemon there, then try again."
            case .enrollmentFailed(let machine, _): return "Couldn’t add \(machine) to Lemon."
            case .serviceFailed(let machine, _): return "Lemon services on \(machine) didn’t become ready."
            case .unexpected: return "Setting up this machine didn’t finish."
            }
        }
        public var detail: String? {
            switch self {
            case .enrollmentFailed(_, let log), .serviceFailed(_, let log), .unexpected(let log): return log.isEmpty ? nil : log
            case .runtimeMissing: return nil
            }
        }
    }

    public static let setupScript = MachineBootstrap.locateScript + "\n" + #"""
    [ -n "$bot" ] || { printf '%s\n' '{"type":"result","status":"runtime_missing","port":4100,"machineId":null,"manager":"none","persistence":"none"}'; exit 1; }
    wrapper="${2:-}"
    set -- "$bot" up --json --no-open
    [ -z "$wrapper" ] || set -- "$@" --worker-wrapper "$wrapper"
    exec "$@"
    """#

    public static func nodeName(fromHostname host: String) -> String {
        let cleaned = String(host.lowercased().unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.").contains($0) })
        let trimmed = cleaned.drop { !$0.isLetter && !$0.isNumber }
        return trimmed.isEmpty ? "lemon-host" : String(trimmed.prefix(64))
    }

    public static let identifyScript = #"""
    printf 'host=%s\n' "$(hostname -s 2>/dev/null || hostname)"
    echo status=ready
    """#

    public static func nodeName(_ output: String) -> String {
        let host = output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("host=") }.map { String($0.dropFirst(5)) } ?? ""
        return nodeName(fromHostname: host)
    }
}

#if os(macOS)
extension LemonBotStore {
    public var hostRoute: MachineRoute? {
        guard let account else { return nil }
        if let route = account.route { return route }
        return ConnectionIssue.isLoopback(account.baseURL) ? .thisMac : nil
    }

    public var hostSetupTrigger: String {
        ([account?.id ?? "", connectionState, member?.role ?? ""] + machines.map { "\($0.id):\($0.status)" }.sorted()).joined(separator: "|")
    }

    public var shouldSetUpHost: Bool {
        hostRoute != nil && ["owner", "admin"].contains(member?.role ?? "") && connectionState == "online"
            && (!machines.contains { $0.status == "online" } || machines.contains { $0.nodeName == hostMachineNodeName && $0.status == "offline" })
            && hostSetup.allowsAutomaticAttempt
    }

    public func automaticallySetUpHostMachine() async {
        let trigger = hostSetupTrigger
        guard lastHostSetupTrigger != trigger, hostSetup.allowsAutomaticAttempt,
              let route = hostRoute, connectionState == "online",
              ["owner", "admin"].contains(member?.role ?? "") else { return }
        lastHostSetupTrigger = trigger
        if hostMachineNodeName == nil {
            let current = generation
            do {
                let name = HostEnrollment.nodeName(try await CommandRunner.script(HostEnrollment.identifyScript, on: route, timeout: 30))
                try assertGeneration(current)
                hostMachineNodeName = name
            } catch {
                guard generation == current else { return }
                hostSetup = .failed(message: error.localizedDescription, detail: nil)
                return
            }
        }
        if shouldSetUpHost { await setUpHostMachine() }
        lastHostSetupTrigger = hostSetupTrigger
    }

    /// Uses the same resumable bootstrap as Terminal, locally or over the existing SSH route.
    public func setUpHostMachine() async {
        if case .running = hostSetup { return }
        guard let route = hostRoute, ["owner", "admin"].contains(member?.role ?? ""), connectionState == "online" else { return }
        let current = generation
        do {
            hostSetup = .running("Checking \(route.machineLabel)…")
            var arguments = [""]
            if route == .thisMac {
                let checkout = UserDefaults.standard.string(forKey: MachineBootstrap.checkoutDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
                arguments[0] = checkout.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? FileManager.default.homeDirectoryForCurrentUser.path + "/lemon"
                if let wrapper = WorkerHost.executableURL() { arguments.append(wrapper.path) }
            }
            let output = try await CommandRunner.script(HostEnrollment.setupScript, on: route, arguments: arguments, timeout: 600) { [weak self] line in
                guard let state = BootstrapProgress.line(line)?.hostSetup else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current, case .running = self.hostSetup else { return }
                    self.hostSetup = state
                }
            }
            try assertGeneration(current)
            let machineID = try BootstrapProgress.result(output).requireMachine(machine: route.machineLabel)
            try await finishHostSetup(machineID, generation: current)
        } catch {
            guard generation == current else { return }
            hostSetup = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                detail: (error as? HostEnrollment.Failure)?.detail ?? (error as? MachineConnectionError)?.detail)
        }
    }

    private func finishHostSetup(_ id: ID, generation current: UUID) async throws {
        for _ in 0..<30 {
            let machine: Machine = try await read("/machines/\(HTTPTransport.pathID(id))")
            try assertGeneration(current)
            upsert(&machines, machine, id: { $0.id }, revision: { $0.revision })
            hostMachineNodeName = machine.nodeName
            if machine.status == "online" { hostSetup = .done; return }
            try await Task.sleep(for: .seconds(2))
        }
        throw HostEnrollment.Failure.unexpected(detail: "The worker started, but Lemon Bot hasn’t seen the machine online yet.")
    }
}
#endif
