import SwiftUI
import LemonBotKit

struct MachineSSHSetupView: View {
    let store: LemonBotStore
    var machine: Machine? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var destination = ""
    @State private var name = ""
    @State private var preview: MachineEnrollmentPreview?
    @State private var setupID: ID?
    @State private var action = HubAction()
    @State private var createBot = false
    private var setup: MachineSetup? { setupID.flatMap { store.machineSetups[$0] } }
    var body: some View {
        Form {
            HubError(action: action, store: store)
            if let setup {
                Section("Setup progress") {
                    ForEach(Array(MachineSetupStep.allCases.dropLast()), id: \.self) { step in
                        Label(title(step), systemImage: icon(step, setup: setup))
                    }
                }
                if setup.state == .succeeded {
                    Section {
                        Text("\(store.machines.first(where: { $0.id == setup.machineId })?.name ?? setup.sshDestination) is online").font(.headline)
                        Text(persistence(setup.persistence))
                        Button("Create a Bot here") { createBot = true }.disabled(setup.machineId == nil)
                    }
                } else if let failure = setup.failure {
                    Section("Couldn't add this machine") {
                        Text(failure.code.message)
                        Text(failure.message)
                        if let detail = failure.detail { DisclosureGroup("Details") { Text(detail).textSelection(.enabled) } }
                        Button("Try again") { start() }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                    }
                }
            } else if preview?.ssh?.available == true || machine != nil {
                Section {
                    TextField("SSH address", text: $destination, prompt: Text("me@studio"))
                        .disabled(machine != nil)
                    DisclosureGroup("Advanced") { TextField("Name (optional)", text: $name) }
                    Text("Use an SSH address that works without a password from the computer running your Lemon controller.")
                    Button(machine == nil ? "Add a machine" : "Reconnect") { start() }
                        .disabled(action.busy || action.uncertain || store.connectionState != "online" || (machine == nil && MachineRoute.sshHost(destination) == nil))
                }
            } else if let preview {
                Section {
                    Text(unavailable(preview.ssh?.reason))
                    Link("Read the machine connection guide", destination: URL(string: "https://lemon.food/user-guide/attaching-a-bot-machine")!)
                }
            } else { ProgressView("Checking connection options") }
            if preview?.reachability == "routable", setup?.state != .running {
                NavigationLink("Use a join command instead") { MachineAttachView(store: store) }
            }
        }
        .formStyle(.grouped).navigationTitle(machine == nil ? "Add a machine" : "Reconnect machine")
        .toolbar { Button("Close") { dismiss() } }
        .frame(minWidth: 420, minHeight: 420)
        .sheet(isPresented: $createBot) { BotEditorView(store: store, machineID: setup?.machineId) }
        .task {
            if machine != nil { start() }
            else { await action.perform(readOnly: true) { preview = try await store.read("/machines/enrollment-preview") } }
        }
    }
    private func start() {
        Task { await action.perform {
            let result: MachineSetup
            if let machine { result = try await store.retryMachineSetup(machine: machine) }
            else if let id = setup?.machineId, let machine = store.machines.first(where: { $0.id == id }) { result = try await store.retryMachineSetup(machine: machine) }
            else { result = try await store.addMachineOverSSH(destination: destination, name: name) }
            setupID = result.id
        } }
    }
    private func title(_ step: MachineSetupStep) -> String {
        switch step {
        case .checking_ssh: return "Connect over SSH"
        case .opening_tunnel: return "Open a secure link"
        case .issuing_invite: return "Get an invite"
        case .installing: return "Install Lemon"
        case .verifying, .online: return "Check it works"
        }
    }
    private func icon(_ step: MachineSetupStep, setup: MachineSetup) -> String {
        let steps = MachineSetupStep.allCases
        let current = steps.firstIndex(of: setup.step) ?? 0
        let index = steps.firstIndex(of: step) ?? 0
        if setup.state == .succeeded || index < current { return "checkmark.circle.fill" }
        if index == current { return setup.state == .failed ? "xmark.circle.fill" : "arrow.triangle.2.circlepath" }
        return "circle"
    }
    private func persistence(_ value: MachineSetup.Persistence?) -> String {
        switch value {
        case .login: return "It starts when you log in."
        case .boot: return "It starts at boot."
        case .session: return "It runs while you are logged in. Enable linger to keep it after logout."
        case .some(.none): return "It is running but will not restart automatically."
        case nil: return "The worker is connected."
        }
    }
    private func unavailable(_ reason: MachineSSHAvailability.Reason?) -> String {
        switch reason {
        case .controller_remote: return "SSH setup is unavailable because this backend uses a remote controller."
        case .node_gateway_unavailable: return "The controller's node gateway is unavailable. Restart or repair the controller before adding a machine."
        case .launcher_unavailable: return "This backend doesn't have a Lemon runtime launcher configured."
        case nil: return "SSH machine setup is unavailable on this controller."
        }
    }
}

struct MachineTunnelSection: View {
    let machine: Machine
    let reconnect: () -> Void
    var body: some View {
        if case let .sshTunnel(destination, _, _, tunnel) = machine.link {
            Section("Secure link") {
                Text("Connected through SSH from this computer")
                Text("Tunnel: \(tunnel.state.rawValue)")
                if let detail = tunnel.detail { Text(message(detail, destination: destination ?? machine.name)) }
                Text("Works while this Mac is awake and Lemon is running.")
                if destination != nil { Button("Reconnect", action: reconnect) }
            }
        }
    }
    private func message(_ detail: MachineLinkDetail, destination: String) -> String {
        switch detail {
        case .ssh_auth_failed: return "This computer can't sign in to \(machine.name) over SSH anymore. Make sure ssh \(destination) works without a password, then Reconnect."
        case .host_key_changed: return "\(machine.name)'s SSH identity changed. Check it and update known_hosts, then Reconnect."
        case .host_unreachable: return "\(machine.name) can't be reached. Check its network and SSH address, then Reconnect."
        case .forward_refused: return "The SSH server refused the secure link. Enable remote TCP forwarding, then Reconnect."
        case .remote_port_in_use: return "A required destination port is in use. Free it, then Reconnect."
        }
    }
}
