import Foundation

public struct MachineSshSetupRequest: Codable, Hashable {
    public var clientNonce: String
    public var sshDestination: String
    public var name: String?
    public var machineId: ID?
    public init(clientNonce: String, sshDestination: String, name: String? = nil, machineId: ID? = nil) {
        self.clientNonce = clientNonce; self.sshDestination = sshDestination
        self.name = name; self.machineId = machineId
    }
}

public enum MachineLinkState: String, Codable, Hashable { case online, reconnecting, failed, stopped, unknown }
public enum MachineLinkDetail: String, Codable, Hashable { case ssh_auth_failed, host_key_changed, host_unreachable, forward_refused, remote_port_in_use }
public struct MachineTunnel: Codable, Hashable {
    public var state: MachineLinkState
    public var detail: MachineLinkDetail?
    public var checkedAtMs: TimestampMs?
}
public enum MachineLink: Codable, Hashable {
    case direct
    case sshTunnel(sshDestination: String?, nodePort: Int, productPort: Int?, tunnel: MachineTunnel)
    enum CodingKeys: String, CodingKey { case kind, sshDestination, nodePort, productPort, tunnel }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "direct": self = .direct
        case "ssh_tunnel": self = .sshTunnel(sshDestination: try c.decodeIfPresent(String.self, forKey: .sshDestination), nodePort: try c.decode(Int.self, forKey: .nodePort), productPort: try c.decodeIfPresent(Int.self, forKey: .productPort), tunnel: try c.decode(MachineTunnel.self, forKey: .tunnel))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Invalid MachineLink.kind")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .direct: try c.encode("direct", forKey: .kind)
        case let .sshTunnel(destination, nodePort, productPort, tunnel):
            try c.encode("ssh_tunnel", forKey: .kind)
            try c.encode(destination, forKey: .sshDestination)
            try c.encode(nodePort, forKey: .nodePort)
            try c.encode(productPort, forKey: .productPort)
            try c.encode(tunnel, forKey: .tunnel)
        }
    }
}
public struct MachineSSHAvailability: Codable, Hashable {
    public var available: Bool
    public var reason: Reason?
    public enum Reason: String, Codable, Hashable { case controller_remote, node_gateway_unavailable, launcher_unavailable }
}
public enum MachineSetupStep: String, Codable, Hashable, CaseIterable { case checking_ssh, opening_tunnel, issuing_invite, installing, verifying, online }
public enum MachineSetupFailure: String, Codable, Hashable, CaseIterable {
    case ssh_unreachable, ssh_auth_failed, ssh_host_key_changed, unsupported_host, port_in_use, forward_refused, runtime_install_failed, enroll_failed, enroll_outcome_unknown, service_failed, not_bot_ready, controller_unavailable, interrupted
    public var message: String {
        switch self {
        case .ssh_unreachable: return "Couldn't reach this SSH address. Check the address and network, then try again."
        case .ssh_auth_failed: return "SSH sign-in failed. Make sure SSH works without a password from the controller computer."
        case .ssh_host_key_changed: return "The machine's SSH identity changed. Check it and update known_hosts before trying again."
        case .unsupported_host: return "This machine doesn't support the Lemon worker service."
        case .port_in_use: return "A required port is already in use on the destination. Free it, then try again."
        case .forward_refused: return "The SSH server refused the secure link. Enable remote TCP forwarding, then try again."
        case .runtime_install_failed: return "Lemon couldn't be installed on the destination."
        case .enroll_failed: return "Machine enrollment failed. Try again to issue a fresh repair invite."
        case .enroll_outcome_unknown: return "The connection ended during enrollment. Check the machine; trying again uses a fresh repair invite."
        case .service_failed: return "The worker service was installed but isn't online yet."
        case .not_bot_ready: return "The machine connected but isn't ready to run Bots."
        case .controller_unavailable: return "The controller is unavailable. Restore its connection, then try again."
        case .interrupted: return "Setup was interrupted when the controller restarted. Try again."
        }
    }
}
public struct MachineSetup: Codable, Hashable, Identifiable {
    public var id: ID
    public var revision: Int
    public var createdAtMs: TimestampMs
    public var updatedAtMs: TimestampMs
    public var machineId: ID?
    public var sshDestination: String
    public var step: MachineSetupStep
    public var state: State
    public var failure: Failure?
    public var persistence: Persistence?
    public var finishedAtMs: TimestampMs?
    public enum State: String, Codable, Hashable { case running, succeeded, failed }
    public enum Persistence: String, Codable, Hashable { case login, boot, session, none }
    public struct Failure: Codable, Hashable { public var code: MachineSetupFailure; public var message: String; public var detail: String? }
}

extension LemonBotStore {
    public func addMachineOverSSH(destination: String, name: String? = nil) async throws -> MachineSetup {
        guard let destination = MachineRoute.sshHost(destination) else { throw ClientError.invalidPath }
        var body: JSONObject = ["sshDestination": .string(destination)]
        if let name, !name.isEmpty { body["name"] = .string(name) }
        return try await startMachineSetup(body)
    }
    public func retryMachineSetup(setup: MachineSetup) async throws -> MachineSetup {
        var body: JSONObject = ["sshDestination": .string(setup.sshDestination)]
        if let machineId = setup.machineId { body["machineId"] = .string(machineId) }
        return try await startMachineSetup(body)
    }
    public func retryMachineSetup(machine: Machine) async throws -> MachineSetup {
        guard case let .sshTunnel(destination?, _, _, _) = machine.link else { throw ClientError.invalidPath }
        return try await startMachineSetup(["sshDestination": .string(destination), "machineId": .string(machine.id)])
    }
    private func startMachineSetup(_ body: JSONObject) async throws -> MachineSetup {
        guard connectionState == "online" else { throw ClientError.offline }
        let setup: MachineSetup = try await mutate("POST", "/machines/ssh", body: body)
        try await receiveMachineSetup(setup)
        return machineSetups[setup.id] ?? setup
    }
    func receiveMachineSetup(_ setup: MachineSetup) async throws {
        guard setup.revision >= (machineSetups[setup.id]?.revision ?? -1) else { return }
        machineSetups[setup.id] = setup
        if setup.state == .succeeded {
            machines = try await allPages("/machines", as: Machine.self)
        }
    }
}
