import Foundation

/// Progress of making the connected machine a Bot machine. The sidebar renders it directly.
public enum HostSetupState: Equatable, Sendable {
    case idle
    case running(String)
    case failed(message: String, detail: String?)
    case done
}

/// Turns the machine a Mac connected to (this Mac or an SSH host) into a Bot machine: a Lemon
/// execution node enrolled with a one-use invite, then kept running by the OS service manager.
public enum HostEnrollment {
    /// The credential-free parts of the backend's `joinCommand`.
    public struct JoinTarget: Equatable, Sendable {
        public let name: String
        public let controller: String
        public let source: String?
        public let version: String?
        public let baseURL: String?
    }

    public enum Outcome: Equatable, Sendable { case ready, needsEnrollment }

    public enum Failure: LocalizedError, Equatable {
        case invalidInvite
        case runtimeMissing(machine: String)
        case enrollmentFailed(machine: String, log: String)
        case serviceFailed(machine: String, log: String)
        case unexpected(detail: String)

        public var errorDescription: String? {
            switch self {
            case .invalidInvite: return "Lemon Bot returned an invitation this app can’t use."
            case .runtimeMissing(let machine): return "Lemon on \(machine) is missing or too old to run Bots. Update Lemon there, then try again."
            case .enrollmentFailed(let machine, _): return "Couldn’t add \(machine) to Lemon."
            case .serviceFailed(let machine, _): return "\(machine) joined Lemon, but its worker didn’t stay running."
            case .unexpected: return "Setting up this machine didn’t finish."
            }
        }
        public var detail: String? {
            switch self {
            case .enrollmentFailed(_, let log), .serviceFailed(_, let log), .unexpected(let log): return log.isEmpty ? nil : log
            case .invalidInvite, .runtimeMissing: return nil
            }
        }
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Node names the backend accepts: `^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$`.
    public static func nodeName(fromHostname host: String) -> String {
        let cleaned = String(host.lowercased().unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.").contains($0) })
        let trimmed = cleaned.drop { !$0.isLetter && !$0.isNumber }
        return trimmed.isEmpty ? "lemon-host" : String(trimmed.prefix(64))
    }

    /// Reads `--name/--controller/--source/--version/--base-url` from the single-quoted join command,
    /// accepting only values `join-node.sh` itself would accept (and nothing that needs escaping).
    public static func target(fromJoinCommand command: String) throws -> JoinTarget {
        guard let expression = try? NSRegularExpression(pattern: "'([^']*)'") else { throw Failure.invalidInvite }
        let words = expression.matches(in: command, range: NSRange(command.startIndex..., in: command)).compactMap { Range($0.range(at: 1), in: command).map { String(command[$0]) } }
        var options: [String: String] = [:]
        var index = 0
        while index < words.count {
            if words[index].hasPrefix("--"), index + 1 < words.count { options[words[index]] = words[index + 1]; index += 2 } else { index += 1 }
        }
        guard let name = options["--name"], matches(name, #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#),
              let controller = options["--controller"], controller.count <= 2048,
              matches(controller, #"^(wss://[A-Za-z0-9.\[\]:-]+|ws://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]{1,5})?)(/[A-Za-z0-9._~/-]*)?$"#) else { throw Failure.invalidInvite }
        let source = options["--source"], version = options["--version"], baseURL = options["--base-url"]
        if let version, !matches(version, #"^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9][A-Za-z0-9.-]*)?$"#) { throw Failure.invalidInvite }
        if let source {
            guard source.hasPrefix("/"), source.count <= 4096, baseURL == nil, !source.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { throw Failure.invalidInvite }
        } else {
            guard version != nil, let baseURL, baseURL.count <= 2048, matches(baseURL, #"^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$"#) else { throw Failure.invalidInvite }
        }
        return JoinTarget(name: name, controller: controller, source: source, version: version, baseURL: baseURL)
    }

    /// Prints `host=` and, on macOS, `computer=` (the friendly name).
    public static let identifyScript = #"""
    printf 'host=%s\n' "$(hostname -s 2>/dev/null || hostname)"
    command -v scutil >/dev/null 2>&1 && printf 'computer=%s\n' "$(scutil --get ComputerName 2>/dev/null)"
    echo status=ready
    """#

    /// With `code`: enroll once, then hand the worker to launchd (macOS) or systemd --user (Linux).
    /// Without: (re)start the worker with this host's stored node credential and report whether it came online.
    /// Prints `status=ready|needs_enrollment|runtime_missing|enroll_failed|service_failed` and `log=` lines.
    /// Values are validated by `target(fromJoinCommand:)` and travel inside the script on stdin.
    public static func script(_ target: JoinTarget, code: String?) -> String {
        let header = [
            "name=\(quote(target.name))", "controller=\(quote(target.controller))",
            "source=\(quote(target.source ?? ""))", "version=\(quote(target.version ?? ""))",
            "base_url=\(quote(target.baseURL ?? ""))", "code=\(quote(code ?? ""))",
        ].joined(separator: "\n")
        return header + "\n" + serviceScript
    }

    private static let serviceScript = #"""
    set -u
    uid=$(id -u)
    label="org.lemon.node.$name"
    plist="$HOME/Library/LaunchAgents/$label.plist"
    unit="lemon-node-$name.service"
    unit_file="$HOME/.config/systemd/user/$unit"
    logs="$HOME/.lemon/logs"; log="$logs/node-$name.log"
    mkdir -p "$logs"
    say_log() { tail -n 8 "$log" 2>/dev/null | sed 's/^/log=/'; }
    size() { n=$(wc -c <"$log" 2>/dev/null | tr -d ' '); echo "${n:-0}"; }
    online_since() { i=0; while [ $i -lt 60 ]; do tail -c +$(($1 + 1)) "$log" 2>/dev/null | grep -q "Execution node online" && return 0; i=$((i + 1)); sleep 1; done; return 1; }
    systemd_user() { [ "$(uname -s)" != Darwin ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; }
    stop_worker() {
      if [ "$(uname -s)" = Darwin ]; then launchctl bootout "gui/$uid/$label" >/dev/null 2>&1
      elif systemd_user; then systemctl --user stop "$unit" >/dev/null 2>&1
      fi
      pkill -f "node join --name $name --controller" >/dev/null 2>&1
      sleep 1
    }
    compatible() {
      [ -n "$1" ] && [ -x "$1" ] || return 1
      if [ -n "$version" ]; then [ "$("$1" version 2>/dev/null)" = "$version" ] || return 1; fi
      "$1" node capabilities --json --require-bot >/dev/null 2>&1
    }
    lemon=
    if [ -n "$source" ]; then
      compatible "$source/bin/lemon" && lemon="$source/bin/lemon"
    else
      for candidate in "$HOME/.lemon/bin/lemon" "$(command -v lemon 2>/dev/null)" "$HOME/.lemon/versions/$version/bin/lemon"; do
        if compatible "$candidate"; then lemon=$candidate; break; fi
      done
      if [ -z "$lemon" ] && [ -n "$code" ]; then
        installer=$(mktemp) && curl -fsSL --proto '=https' --proto-redir '=https' "${base_url%/}/releases/download/v$version/install.sh" -o "$installer" \
          && LEMON_VERSION="$version" LEMON_INSTALL_BASE_URL="$base_url" sh "$installer" --profile full --require-bot --force --skip-setup --no-modify-path >/dev/null 2>&1
        rm -f "$installer"
        compatible "$HOME/.lemon/versions/$version/bin/lemon" && lemon="$HOME/.lemon/versions/$version/bin/lemon"
      fi
    fi
    [ -n "$lemon" ] || { echo status=runtime_missing; exit 0; }

    # Bots run your CLI tools, so the worker gets your login shell's PATH.
    path=$("${SHELL:-/bin/sh}" -lc 'printf %s "$PATH"' 2>/dev/null </dev/null | tr -d '&<>"\\')
    [ -n "$path" ] || path=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
    path="$(dirname "$lemon"):$HOME/.lemon/bin:$path"

    start_worker() {
      if [ "$(uname -s)" = Darwin ]; then
        mkdir -p "$HOME/Library/LaunchAgents"
        cat >"$plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>Label</key><string>$label</string>
      <key>ProgramArguments</key><array>
        <string>$lemon</string><string>node</string><string>join</string>
        <string>--name</string><string>$name</string>
        <string>--controller</string><string>$controller</string>
        <string>--cwd</string><string>$HOME</string>
      </array>
      <key>EnvironmentVariables</key><dict>
        <key>HOME</key><string>$HOME</string>
        <key>PATH</key><string>$path</string>
        <key>LEMON_GATEWAY_HEALTH_PORT</key><string>0</string>
        <key>LEMON_ROUTER_HEALTH_PORT</key><string>0</string>
      </dict>
      <key>WorkingDirectory</key><string>$HOME</string>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>ThrottleInterval</key><integer>10</integer>
      <key>StandardOutPath</key><string>$log</string>
      <key>StandardErrorPath</key><string>$log</string>
    </dict></plist>
    PLIST
        launchctl bootstrap "gui/$uid" "$plist"
      elif systemd_user; then
        mkdir -p "$(dirname "$unit_file")"
        cat >"$unit_file" <<UNIT
    [Unit]
    Description=Lemon execution node $name
    After=network-online.target

    [Service]
    ExecStart="$lemon" node join --name "$name" --controller "$controller" --cwd "$HOME"
    WorkingDirectory=$HOME
    Environment="PATH=$path" LEMON_GATEWAY_HEALTH_PORT=0 LEMON_ROUTER_HEALTH_PORT=0
    Restart=always
    RestartSec=5
    StandardOutput=append:$log
    StandardError=append:$log

    [Install]
    WantedBy=default.target
    UNIT
        systemctl --user daemon-reload && systemctl --user enable --now "$unit" >/dev/null 2>&1
      else
        (cd "$HOME" && PATH="$path" LEMON_GATEWAY_HEALTH_PORT=0 LEMON_ROUTER_HEALTH_PORT=0 nohup "$lemon" node join --name "$name" --controller "$controller" --cwd "$HOME" </dev/null >>"$log" 2>&1 &)
      fi
    }

    if [ -z "$code" ]; then
      # Restart (or first supervise) the worker with this host's stored node credential.
      stop_worker; start=$(size); start_worker
      if online_since "$start"; then echo status=ready; else stop_worker; echo status=needs_enrollment; fi
      exit 0
    fi

    stop_worker
    start=$(size)
    cd "$HOME"
    printf '%s\n' "$code" | PATH="$path" LEMON_GATEWAY_HEALTH_PORT=0 LEMON_ROUTER_HEALTH_PORT=0 \
      "$lemon" node join --name "$name" --controller "$controller" --invite-code-stdin --cwd "$HOME" >>"$log" 2>&1 &
    enrolling=$!
    if ! online_since "$start"; then kill "$enrolling" 2>/dev/null; echo status=enroll_failed; say_log; exit 0; fi
    kill "$enrolling" 2>/dev/null; wait "$enrolling" 2>/dev/null
    start=$(size); start_worker
    if online_since "$start"; then echo status=ready; else echo status=service_failed; say_log; fi
    """#

    public static func parse(_ output: String, machine: String) throws -> Outcome {
        var status: String?
        var log: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("status=") { status = String(line.dropFirst(7)) }
            else if line.hasPrefix("log=") { log.append(String(line.dropFirst(4))) }
        }
        switch status {
        case "ready": return .ready
        case "needs_enrollment": return .needsEnrollment
        case "runtime_missing": throw Failure.runtimeMissing(machine: machine)
        case "enroll_failed": throw Failure.enrollmentFailed(machine: machine, log: log.joined(separator: "\n"))
        case "service_failed": throw Failure.serviceFailed(machine: machine, log: log.joined(separator: "\n"))
        default: throw Failure.unexpected(detail: "The setup script returned no result.")
        }
    }

    /// `host=` / `computer=` from `identifyScript`, as the node name and the name people see.
    public static func identity(_ output: String) -> (nodeName: String, displayName: String) {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }
        let host = values["host"] ?? ""
        let display = [values["computer"], host].compactMap { $0 }.first { !$0.isEmpty } ?? "My machine"
        return (nodeName(fromHostname: host), String(display.prefix(120)))
    }
}

#if os(macOS)
extension LemonBotStore {
    /// The machine this Mac reached with its private key, when it can set that machine up itself.
    public var hostRoute: MachineRoute? {
        guard let account else { return nil }
        if let route = account.route { return route }
        return ConnectionIssue.isLoopback(account.baseURL) ? .thisMac : nil
    }

    /// True when nothing can run Bots yet and this Mac can fix that without asking.
    public var shouldSetUpHost: Bool {
        hostRoute != nil && ["owner", "admin"].contains(member?.role ?? "") && connectionState == "online"
            && !machines.contains { $0.status == "online" } && hostSetup == .idle
    }

    /// One click: enroll the connected machine as a Lemon execution node and keep its worker running.
    /// Reuses a machine of the same name: restarting its worker, or repairing it with a fresh invite.
    public func setUpHostMachine() async {
        if case .running = hostSetup { return }
        guard let route = hostRoute else { return }
        let label = route.machineLabel
        do {
            hostSetup = .running("Checking \(label)…")
            let (nodeName, displayName) = HostEnrollment.identity(try await CommandRunner.script(HostEnrollment.identifyScript, on: route, timeout: 30))
            let current: Page<Machine> = try await read("/machines")
            machines = current.items
            let machine: Machine
            let invite: MachineInvite
            if let existing = current.items.first(where: { $0.nodeName == nodeName && $0.status != "revoked" }) {
                hostSetup = .running("Starting Lemon’s worker on \(label)…")
                if let target = try await joinTarget(for: existing),
                   try HostEnrollment.parse(await CommandRunner.script(HostEnrollment.script(target, code: nil), on: route, timeout: 120), machine: label) == .ready {
                    try await finishHostSetup(existing.id); return
                }
                hostSetup = .running("Reconnecting \(existing.name)…")
                machine = existing
                invite = try await mutate("POST", "/machines/\(HTTPTransport.pathID(existing.id))/reconnect", body: [:])
            } else {
                hostSetup = .running("Adding \(displayName) to Lemon…")
                let created = try await attachMachine(name: displayName, nodeName: nodeName)
                machine = created.machine; invite = created.invite
            }
            let target = try HostEnrollment.target(fromJoinCommand: invite.joinCommand)
            hostSetup = .running("Setting up \(label) to run Bots…")
            _ = try HostEnrollment.parse(await CommandRunner.script(HostEnrollment.script(target, code: invite.inviteCode), on: route, timeout: 600), machine: label)
            try await finishHostSetup(machine.id)
        } catch {
            hostSetup = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                                detail: (error as? HostEnrollment.Failure)?.detail ?? (error as? MachineConnectionError)?.detail)
        }
    }

    /// The join target of an already-attached machine, from its newest invitation.
    private func joinTarget(for machine: Machine) async throws -> HostEnrollment.JoinTarget? {
        let invites: Page<MachineInvite> = try await read("/machines/\(HTTPTransport.pathID(machine.id))/invites")
        return invites.items.sorted { $0.createdAtMs > $1.createdAtMs }.lazy.compactMap { try? HostEnrollment.target(fromJoinCommand: $0.joinCommand) }.first
    }

    /// A name the controller already knows (enrolled outside Lemon Bot) gets a numbered sibling.
    private func attachMachine(name: String, nodeName: String) async throws -> MachineAttachResult {
        var candidate = nodeName
        for attempt in 2...4 {
            do { return try await mutate("POST", "/machines", body: ["name": .string(name), "nodeName": .string(candidate)]) }
            catch let error as BackendError where error.failure.code == "conflict" { candidate = String(nodeName.prefix(60)) + "-\(attempt)" }
        }
        throw HostEnrollment.Failure.unexpected(detail: "Every node name tried for this machine is already taken.")
    }

    /// Success only once the backend itself reports the machine online.
    private func finishHostSetup(_ id: ID) async throws {
        for _ in 0..<30 {
            let machine: Machine = try await read("/machines/\(HTTPTransport.pathID(id))")
            upsert(&machines, machine, id: { $0.id }, revision: { $0.revision })
            if machine.status == "online" { hostSetup = .done; return }
            try await Task.sleep(for: .seconds(2))
        }
        throw HostEnrollment.Failure.unexpected(detail: "The worker started, but Lemon Bot hasn’t seen the machine online yet.")
    }
}
#endif
