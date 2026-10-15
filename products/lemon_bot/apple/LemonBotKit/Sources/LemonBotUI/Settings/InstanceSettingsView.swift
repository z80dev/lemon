import SwiftUI
import LemonBotKit

struct InstanceSettingsView: View {
    let store: LemonBotStore
    @State private var action = UIActionState()
    @State private var readError: String?
    @State private var refreshing = false
    @State private var confirmation: RuntimeAction?
    private var operation: RuntimeOperation? { store.instanceStatus?.runtime.operation }
    private var pendingRuntime: Bool { store.pendingIntents.contains { $0.path.hasPrefix("/instance/runtime/") } }
    private var pollKey: String { (store.account?.id ?? "") + "|" + (operation.flatMap { $0.state == .running ? $0.id : nil } ?? "idle") }

    var body: some View {
        Form {
            if store.canViewInstance {
                if let status = store.instanceStatus {
                    lifecycle(status.runtime)
                    backend(status.backend)
                    controller(status.controller)
                    lemon(status)
                    Section {
                        Text("Measured \(timestamp(status.measuredAtMs).formatted())").font(LBFont.meta).foregroundStyle(LB.muted)
                        Text("Refreshes every 10 seconds while open, or every 2 seconds during a command.").font(LBFont.meta).foregroundStyle(LB.muted)
                    }
                } else if refreshing { ProgressView("Loading Lemon instance…") }
                errors
            } else {
                Text("Only workspace owners can view instance details.").foregroundStyle(LB.muted)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Lemon instance")
        .toolbar {
            if store.canViewInstance { Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(refreshing) }
        }
        .refreshable { await refresh() }
        .task(id: pollKey) {
            guard store.canViewInstance else { return }
            await refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(operation?.state == .running ? 2 : 10)) }
                catch { return }
                await refresh()
            }
        }
        .confirmationDialog(confirmation == .stop ? "Stop Lemon?" : "Restart Lemon?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let requested = confirmation {
                Button(requested == .stop ? "Stop Lemon" : "Restart Lemon", role: .destructive) { confirmation = nil; run(requested, confirmed: true) }
            }
        } message: {
            Text(confirmation == .stop ? "Bots stop working until Lemon is started again. Lemon Bot stays available so you can start it from here." : "Bots stop working until Lemon has restarted and reconnected. Lemon Bot stays available during the restart.")
        }
    }
    private func backend(_ backend: InstanceBackend) -> some View {
        Section("Lemon Bot service") {
            LabeledContent("Version", value: "\(backend.version) · API \(backend.apiVersion)")
            LabeledContent("Address") { Text(store.account.map { ConnectionIssue.origin(for: $0.baseURL) } ?? backend.publicUrl).textSelection(.enabled) }
            if store.account.map({ ConnectionIssue.origin(for: $0.baseURL) }) != backend.publicUrl {
                LabeledContent("Public address") { Text(backend.publicUrl).textSelection(.enabled) }
            }
            LabeledContent("Up since", value: timestamp(backend.startedAtMs).formatted())
        }
    }
    private func controller(_ controller: InstanceController) -> some View {
        Section("Lemon link") {
            LabeledContent("State") { StatusBadge(text: controller.state.rawValue) }
            LabeledContent("Address") { Text(controller.url).font(LBFont.code).textSelection(.enabled) }
            if let connected = controller.connectedAtMs { LabeledContent("Connected since", value: timestamp(connected).formatted()) }
            if let disconnected = controller.lastDisconnectedAtMs { LabeledContent("Last disconnected", value: timestamp(disconnected).formatted()) }
            if let retry = controller.nextRetryAtMs { LabeledContent("Next retry", value: timestamp(retry).formatted()) }
            if let error = controller.lastError {
                DisclosureGroup("Last error · Details") {
                    Text(error.message).textSelection(.enabled)
                    Text("\(error.code) · \(timestamp(error.atMs).formatted())").font(LBFont.code).textSelection(.enabled)
                    Button("Copy link error") { copyText("\(controller.url)\n\(error.code): \(error.message)\n\(timestamp(error.atMs).formatted())") }
                }
            }
            Button("Reconnect") { Task { await action.perform { try await store.reconnectLemonLink() } } }.disabled(action.busy)
        }
    }
    @ViewBuilder private func lemon(_ status: InstanceStatus) -> some View {
        Section("Lemon") {
            if let lemon = status.lemon {
                LabeledContent("Version", value: lemon.version ?? "Unavailable")
                LabeledContent("Uptime", value: lemon.uptimeMs.map(instanceUptime) ?? "Unavailable")
                LabeledContent("Memory", value: lemon.memoryMb.map { $0.formatted(.number.precision(.fractionLength(0...1))) + " MB" } ?? "Unavailable")
                if let runs = lemon.runs {
                    LabeledContent("Active / queued runs", value: "\(runs.active) / \(runs.queued)")
                    LabeledContent("Completed today", value: "\(runs.completedToday)")
                }
                if let sessions = lemon.activeSessions { LabeledContent("Active sessions", value: "\(sessions)") }
                if let nodes = lemon.nodes { LabeledContent("Nodes online", value: "\(nodes.online) of \(nodes.total)") }
                if let connections = lemon.connections { LabeledContent("Connections", value: "\(connections.active) active · \(connections.operators) operator · \(connections.nodes) node") }
                if let channels = lemon.channels {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Channels").font(LBFont.metaEmphasis)
                        if channels.configured.isEmpty { Text("No channels configured").foregroundStyle(LB.muted) }
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(channels.configured, id: \.self) { name in
                                    LabelChip(text: "\(name) · \(channels.connected.contains(name) ? "connected" : "configured")", tint: channels.connected.contains(name) ? LB.success : LB.warning)
                                }
                                ForEach(channels.connected.filter { !channels.configured.contains($0) }, id: \.self) { name in LabelChip(text: "\(name) · connected", tint: LB.success) }
                            }
                        }.scrollIndicators(.never)
                    }
                }
                if let skills = lemon.skills { LabeledContent("Skills", value: "\(skills.enabled) enabled / \(skills.installed) installed") }
            } else { Text(status.lemonUnavailableReason ?? "Lemon details are unavailable while the link is down.").foregroundStyle(LB.muted) }
        }
    }
    private func lifecycle(_ runtime: InstanceRuntime) -> some View {
        Section("Lifecycle") {
            if runtime.controllable {
                if store.canControlInstance {
                    HStack {
                        Button("Start") { run(.start) }
                        Button("Restart") { confirmation = .restart }
                        Button("Stop", role: .destructive) { confirmation = .stop }
                    }.buttonStyle(.pill(.secondary)).disabled(action.busy || operation?.state == .running || pendingRuntime)
                } else { Text("Only workspace owners can start, stop or restart Lemon.").foregroundStyle(LB.muted) }
            } else { Text(runtime.reason ?? "This backend cannot control Lemon on this host.").foregroundStyle(LB.muted).textSelection(.enabled) }
            if let operation { RuntimeOperationView(operation: operation) }
            if pendingRuntime {
                Text("A previous command has no confirmed result. Refresh to inspect the current state; the command will not be sent again automatically.").font(LBFont.meta).foregroundStyle(LB.warning)
            }
        }
    }
    @ViewBuilder private var errors: some View {
        if readError != nil || action.error != nil {
            Section {
                Text(readError != nil ? "Instance details couldn’t refresh. Any details shown are from the last successful check." : "The action couldn’t finish. Check Details before trying again.").foregroundStyle(LB.warning)
                DisclosureGroup("Details") {
                    let detail = [readError, action.error].compactMap { $0 }.joined(separator: "\n")
                    Text(detail).font(LBFont.code).textSelection(.enabled)
                    Button("Copy details") { copyText(detail) }
                }
            }
        }
    }
    private func run(_ requested: RuntimeAction, confirmed: Bool = false) {
        Task { await action.perform { try await store.performRuntimeAction(requested, confirmed: confirmed) } }
    }
    private func refresh() async {
        guard store.canViewInstance, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do { _ = try await store.refreshInstance(); readError = nil }
        catch is CancellationError {}
        catch { if (error as? URLError)?.code != .cancelled { readError = error.localizedDescription } }
    }
}

func instanceUptime(_ milliseconds: Double) -> String {
    let seconds = Int(max(0, milliseconds) / 1000)
    if seconds >= 86_400 { return "\(seconds / 86_400)d \(seconds % 86_400 / 3600)h" }
    if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
    if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds)s"
}
