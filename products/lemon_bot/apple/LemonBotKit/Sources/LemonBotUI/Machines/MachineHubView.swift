import SwiftUI
import LemonBotKit

public struct MachineHubView: View {
    let store: LemonBotStore
    @State private var machines: [Machine] = []
    @State private var cursor: String?
    @State private var attach = false
    @State private var action = HubAction()
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        List {
            HubError(action: action, store: store)
            Section { Text("Bots using the same computer user share its files and logins. Use a separate computer user or machine to keep them apart. You keep full access to your machine.") }
            ForEach(machines) { machine in
                NavigationLink { MachineDetailView(store: store, machineID: machine.id) } label: {
                    VStack(alignment: .leading) {
                        Text(machine.name).font(.headline)
                        Text("\(humanizedStatus(machine.status)) · \(machine.botIds.count) Bots")
                        Text("Last seen: \(hubDate(machine.lastSeenAtMs))").font(LBFont.meta)
                    }
                }
            }
            if cursor != nil { Button("More machines") { Task { await load(more: true) } } }
            NavigationLink("Owned-host operations") { HostOperationsView(store: store) }
        }
        .navigationTitle("Machines")
        .toolbar { Button("Attach machine") { attach = true }; Button("Refresh") { Task { await load() } } }
        .sheet(isPresented: $attach) { NavigationStack { MachineAttachView(store: store) } }
        .task { await load() }
    }
    private func load(more: Bool = false) async {
        await action.perform(readOnly: true) {
            let page: HubPage<Machine> = try await store.read("/machines", query: more ? ["cursor": cursor ?? ""] : [:])
            machines = hubMerged(machines, page.items, append: more, id: \.id); cursor = page.nextCursor
        }
    }
}
struct MachineAttachView: View {
    let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var nodeName = ""
    @State private var labelKey = ""
    @State private var labelValue = ""
    @State private var accepted = false
    @State private var result: MachineAttachResult?
    @State private var action = HubAction()
    var body: some View {
        Form {
            HubError(action: action, store: store)
            if let result { MachineEnrollmentView(store: store, machineID: result.machine.id, initialInvite: result.invite) }
            else {
                TextField("Friendly name", text: $name)
                TextField("Machine connection name", text: $nodeName)
                TextField("Optional label key", text: $labelKey)
                TextField("Label value", text: $labelValue)
                Toggle("I trust this machine and understand its Bots share files and logins", isOn: $accepted)
                Button("Create one-use invitation") { Task { await action.perform {
                    var body: JSONObject = ["name": .string(name), "nodeName": .string(nodeName)]
                    if !labelKey.isEmpty { body["labels"] = .object([labelKey: .string(labelValue)]) }
                    result = try await store.mutate("POST", "/machines", body: body)
                } } }.disabled(!accepted || name.isEmpty || nodeName.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
            }
        }.formStyle(.grouped).navigationTitle("Attach a machine").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }
}
struct MachineEnrollmentView: View {
    let store: LemonBotStore
    let machineID: ID
    let initialInvite: MachineInvite?
    @State private var machine: Machine?
    @State private var invites: [MachineInvite] = []
    @State private var cursor: String?
    @State private var action = HubAction()
    var body: some View {
        Section("Enrollment and repair") {
            HubError(action: action, store: store)
            Text("Run the one-use command on the destination. Configure provider credentials and working directory on that host, and supervise its worker with your service manager. Copying does not prove installation or enrollment.")
            Text("Actual machine status: \(machine?.status ?? "Loading")")
            ForEach(invites) { invite in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(invite.enrollment) · \(invite.status)").font(.headline)
                    Text("Expires: \(hubDate(invite.expiresAtMs))")
                    if let error = invite.lastError { Text(error).foregroundStyle(LB.danger) }
                    if invite.status == "pending" {
                        Text(invite.joinCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy exact join command") { hubCopy(invite.joinCommand) }
                        Button("Copy one-use code") { hubCopy(invite.inviteCode) }
                        Button("Revoke invitation", role: .destructive) { Task { await action.perform {
                            let _: HubDeleted = try await store.mutate("DELETE", "/machines/\(hubID(machineID))/invites/\(hubID(invite.id))", body: [:]); try await refresh()
                        } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                    }
                }
            }
            if cursor != nil { Button("Older invitations") { Task { await action.perform(readOnly: true) { try await refresh(more: true) } } } }
            Button("Reconnect same durable machine / reissue") { Task { await action.perform {
                let invite: MachineInvite = try await store.mutate("POST", "/machines/\(hubID(machineID))/reconnect", body: [:]); invites.insert(invite, at: 0)
            } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
        }
        .task {
            if let initialInvite { invites = [initialInvite] }
            while !Task.isCancelled {
                await action.poll { try await refresh() }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
    }
    private func refresh(more: Bool = false) async throws {
        machine = try await store.read("/machines/\(hubID(machineID))")
        let page: HubPage<MachineInvite> = try await store.read("/machines/\(hubID(machineID))/invites", query: more ? ["cursor": cursor ?? ""] : [:])
        invites = hubMerged(invites, page.items, append: more, id: \.id); cursor = page.nextCursor
    }
}
public struct MachineDetailView: View {
    let store: LemonBotStore
    let machineID: ID
    @State private var machine: Machine?
    @State private var host: HostInfo?
    @State private var capabilities: MachineCapabilities?
    @State private var management: HostManagement?
    @State private var hostError: String?
    @State private var managementError: String?
    @State private var capabilityError: String?
    @State private var name = ""
    @State private var preview: HubConfirmation?
    @State private var action = HubAction()
    public init(store: LemonBotStore, machineID: ID) { self.store = store; self.machineID = machineID }
    public var body: some View {
        Form {
            HubError(action: action, store: store)
            if let machine {
                Section("Your machine") {
                    Text(humanizedStatus(machine.status))
                    Text("Last seen \(hubDate(machine.lastSeenAtMs))")
                    DisclosureGroup("Details") {
                        let details = "Connection name: \(machine.nodeName)\nOwner ID: \(machine.ownerUserId)"
                        Text(details).textSelection(.enabled)
                        Button("Copy") { copyText(details) }
                    }
                    Text("Bots using the same computer user share its files and logins. Use a separate computer user or machine to keep them apart.").foregroundStyle(LB.warning)
                    TextField("Name", text: $name)
                    Button("Save machine name") { Task { await action.perform {
                        let updated: Machine = try await store.mutate("PATCH", "/machines/\(hubID(machineID))", body: ["revision": .number(Double(machine.revision)), "name": .string(name)]); self.machine = updated
                    } } }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                }
                Section("Machine information") {
                    if let host {
                        LabeledContent("Hostname / OS", value: "\(host.hostname) · \(host.os) \(host.osVersion) · \(host.arch)")
                        LabeledContent("CPU", value: "\(host.cpuCount) cores")
                        LabeledContent("Memory free / total", value: "\(host.memFreeBytes) / \(host.memTotalBytes) bytes")
                        LabeledContent("Disk free / total", value: "\(host.diskFreeBytes) / \(host.diskTotalBytes) bytes")
                        LabeledContent("Lemon / uptime", value: "\(host.lemonVersion) · \(host.uptimeSec)s")
                        LabeledContent("OS user / cwd", value: "\(host.user) · \(host.defaultCwd)")
                        Text("Measured \(hubDate(host.measuredAtMs))")
                    } else { ActionErrorView(message: hostError); if hostError == nil { Text("Loading measurements") } }
                }
                if let capabilities {
                    Section("Capabilities and actual OS grants") {
                        Text("\(capabilities.os) · \(capabilities.stale ? "Stale" : "Measured") · \(hubDate(capabilities.measuredAtMs))")
                        ForEach(capabilities.items, id: \.id) { capability in
                            VStack(alignment: .leading) {
                                Text(capability.name).font(.headline)
                                Text("\(capability.supported ? "Supported" : "Unsupported") · \(capability.configuredLevel) · OS grant \(capability.osGrant)")
                                Text(capability.reason)
                                Text(capability.tools.joined(separator: ", ")).font(LBFont.meta)
                            }
                        }
                    }
                }
                if let capabilityError { Section("Capability measurement unavailable") { ActionErrorView(message: capabilityError) } }
                Section("Bots on this machine") {
                    ForEach(store.bots.filter { $0.machineId == machineID }) { bot in
                        NavigationLink(bot.name) { BotOverviewView(store: store, botID: bot.id) }
                        MachineBotGrantsView(store: store, bot: bot)
                    }
                }
                Section("Machine tools") {
                    NavigationLink("Files") { MachineFilesView(store: store, machineID: machineID) }
                    NavigationLink("Interactive terminal") { MachineTerminalView(store: store, machineID: machineID) }
                    NavigationLink("Write-only secrets") { MachineSecretsView(store: store, machineID: machineID) }
                }
                Section("Machine management") {
                    if let management {
                        Text("\(management.provider) · isolated root: \(management.environmentRoot ?? "None")")
                        Text("Backup: \(hubDate(management.lastBackupAtMs))")
                        Text("Network: \(management.supportsNetworkPolicy ? "Supported" : "Unsupported") · Egress: \(management.supportsEgress ? "Supported" : "Unsupported") · Setup: \(management.supportsSetup ? "Supported" : "Unsupported")")
                        NavigationLink("Review machine actions") { HostOperationsView(store: store, machineID: machineID, supported: management.supportedActions) }
                    } else { ActionErrorView(message: managementError); if managementError == nil { Text("Loading configured driver") } }
                }
                MachineEnrollmentView(store: store, machineID: machineID, initialInvite: nil)
                Button("Preview detach", role: .destructive) { Task { await action.perform { preview = try await store.mutate("POST", "/machines/\(hubID(machineID))/preview", body: ["action": .string("detach")]) } } }
                    .disabled(action.busy || action.uncertain || store.connectionState != "online")
                if let preview { HubConfirmationForm(store: store, preview: preview, action: action) { name in await action.perform {
                    let _: HubDeleted = try await store.mutate("DELETE", "/machines/\(hubID(machineID))", body: preview.body(name: name)); self.preview = nil; try await load()
                } } }
            }
        }.formStyle(.grouped).navigationTitle(machine?.name ?? "Machine").toolbar { Button("Refresh") { Task { await action.checkStatus(store) { try await load() } } } }
            .task { await action.perform(readOnly: true) { try await load() } }
    }
    private func load() async throws {
        let value: Machine = try await store.read("/machines/\(hubID(machineID))"); machine = value; name = value.name
        do { host = try await store.read("/machines/\(hubID(machineID))/host"); hostError = nil } catch { host = nil; hostError = humanErrorText(error) }
        do { capabilities = try await store.read("/machines/\(hubID(machineID))/capabilities"); capabilityError = nil } catch { capabilities = nil; capabilityError = humanErrorText(error) }
        do { management = try await store.read("/machines/\(hubID(machineID))/management"); managementError = nil } catch { management = nil; managementError = humanErrorText(error) }
    }
}
struct HostOperationsView: View {
    let store: LemonBotStore
    let machineID: ID?
    let supported: [String]
    @State private var selected: Set<ID> = []
    @State private var hostAction = "restart_worker"
    @State private var preview: HubConfirmation?
    @State private var operations: [HostOperation] = []
    @State private var cursor: String?
    @State private var action = HubAction()
    init(store: LemonBotStore, machineID: ID? = nil, supported: [String] = ["update", "recover", "restart_worker", "stop_worker", "suspend", "recreate_environment", "delete_environment"]) { self.store = store; self.machineID = machineID; self.supported = supported }
    var body: some View {
        Form {
            HubError(action: action, store: store)
            Text("Operations require a configured driver and explicit authority. Recreate/delete affect only its isolated environment, never your host home or SSH. Acceptance is not completion. Uncertain operations are not replayed.")
            Section("Exact targets") {
                ForEach(store.machines.filter { machineID == nil || $0.id == machineID }) { machine in
                    Toggle("\(machine.name) · \(machine.status)", isOn: Binding(get: { selected.contains(machine.id) }, set: { if $0 { selected.insert(machine.id) } else { selected.remove(machine.id) }; preview = nil }))
                }
                Picker("Action", selection: $hostAction) { ForEach(supported, id: \.self) { Text($0).tag($0) } }.onChange(of: hostAction) { preview = nil }
                Button("Preview selected hosts") { Task { await action.perform {
                    preview = try await store.mutate("POST", "/host-operations/preview", body: ["machineIds": .array(selected.sorted().map(JSONValue.string)), "action": .string(hostAction)])
                } } }.disabled(selected.isEmpty || action.busy || action.uncertain || store.connectionState != "online")
            }
            if let preview { HubConfirmationForm(store: store, preview: preview, action: action) { name in await action.perform {
                var body = preview.body(name: name); body["machineIds"] = .array(selected.sorted().map(JSONValue.string)); body["action"] = .string(hostAction)
                let operation: HostOperation = try await store.mutate("POST", "/host-operations", body: body); operations.insert(operation, at: 0); self.preview = nil
                if operation.state == "outcome_unknown" { action.uncertain = true; action.uncertainResourceID = operation.id; action.error = "We couldn't confirm whether this ran. Check its result below before trying again." }
            } } }
            Section("Persisted operations / per-target outcomes") {
                ForEach(operations) { operation in
                    VStack(alignment: .leading) {
                        Text("\(humanizedStatus(operation.action)) · \(hubStatusLabel(operation.state))").font(LBFont.rowTitle)
                        DisclosureGroup("Details") { Text(operation.id).textSelection(.enabled); Button("Copy") { copyText(operation.id) } }
                        ForEach(operation.results, id: \.machineId) { result in Text("\(store.machines.first(where: { $0.id == result.machineId })?.name ?? "Machine"): \(hubStatusLabel(result.state)) · \(result.reason ?? "")") }
                        Button("Check status") { Task { await action.perform(readOnly: true) {
                            let current: HostOperation = try await store.read("/host-operations/\(hubID(operation.id))")
                            if let index = operations.firstIndex(where: { $0.id == current.id }) { operations[index] = current }
                            if action.uncertainResourceID == current.id, ["completed", "succeeded", "failed", "cancelled"].contains(current.state) { action.uncertain = false; action.uncertainResourceID = nil; action.error = nil }
                        } } }
                    }
                }
                if cursor != nil { Button("More operations") { Task { await load(more: true) } } }
            }
        }.formStyle(.grouped).navigationTitle("Host operations").toolbar { Button("Refresh results") { Task { await load() } } }
            .task { if let machineID { selected = [machineID] }; if let first = supported.first { hostAction = first }; await load() }
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) {
        let page: HubPage<HostOperation> = try await store.read("/host-operations", query: more ? ["cursor": cursor ?? ""] : [:]); operations = hubMerged(operations, page.items, append: more, id: \.id); cursor = page.nextCursor
    } }
}
