import SwiftUI
import LemonBotKit

/// The same explanation and recovery actions in the workspace, sidebar popover and phone sheet.
public struct ConnectionStatusView: View {
    let store: LemonBotStore
    @State private var action = UIActionState()
    @State private var connectElsewhere = false
    @State private var signIn = false
    @State private var pairing = false
    @State private var restart = false
    @State private var instanceDetails = false
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let issue = store.connectionIssue {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: issue.layer == .signedOutOrRevoked ? "person.crop.circle.badge.exclamationmark" : "network.slash").foregroundStyle(LB.warning).font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.title).font(LBFont.rowTitle).foregroundStyle(LB.ink)
                        Text("Trying to reach \(URL(string: issue.origin)?.host ?? issue.origin)\(URL(string: issue.origin)?.port.map { ":\($0)" } ?? "")").font(LBFont.rowSubtitle)
                        if !issue.email.isEmpty { Text(issue.email).font(LBFont.meta).foregroundStyle(LB.muted) }
                    }
                    Spacer(minLength: 0)
                }
                Text(issue.reason).font(LBFont.body)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let deadline = store.nextRetryAt ?? issue.nextRetryAt, deadline > context.date {
                        Text("Retrying in \(Int(ceil(deadline.timeIntervalSince(context.date))))s").font(LBFont.meta).foregroundStyle(LB.muted)
                    } else if store.connectionState == "connecting" || store.connectionState == "syncing" {
                        Label("Trying to connect…", systemImage: "arrow.triangle.2.circlepath").font(LBFont.meta).foregroundStyle(LB.muted)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { recoveryButtons }
                    VStack(alignment: .leading, spacing: 8) { recoveryButtons }
                }
                if issue.layer == .controllerDown { controllerActions }
                if store.canViewInstance, issue.layer != .signedOutOrRevoked { Button("View instance details") { instanceDetails = true }.buttonStyle(.borderless) }
                #if os(macOS)
                if issue.layer == .backendUnreachable, let account = store.account, account.route != nil || ConnectionIssue.isLoopback(account.baseURL) {
                    Button("Start Lemon Bot on \(account.route?.title ?? "this Mac")") { Task { await action.perform { try await store.startBackend() } } }
                        .buttonStyle(.lemonPrimary).disabled(action.inFlight)
                }
                #endif
                if let operation = store.instanceStatus?.runtime.operation { RuntimeOperationView(operation: operation) }
                if action.error != nil { Text("The action couldn’t finish. Check Details before trying again.").font(LBFont.meta).foregroundStyle(LB.danger) }
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(issue.origin).font(LBFont.code)
                        Text("Last attempt: \(issue.lastAttemptAt.formatted())").font(LBFont.meta)
                        Text(issue.detail).font(LBFont.code).textSelection(.enabled)
                        if let error = action.error { Text(error).font(LBFont.code).textSelection(.enabled) }
                        Button("Copy details") { copyText("\(issue.origin)\n\(issue.email)\n\(issue.lastAttemptAt.formatted())\n\(issue.detail)\n\(action.error ?? "")") }.buttonStyle(.pill(.secondary, compact: true))
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(LBFont.meta)
            } else {
                Label(store.connectionState == "online" ? "Connected to Lemon Bot" : "Connecting to Lemon Bot…", systemImage: "network").font(LBFont.body)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius).fill(LB.raised))
        .overlay(RoundedRectangle(cornerRadius: LBMetric.rowRadius).strokeBorder(LB.warning.opacity(0.3)))
        .sheet(isPresented: $connectElsewhere) { OnboardingView(store: store) }
        .sheet(isPresented: $signIn) { OnboardingView(store: store, initialURL: store.account?.baseURL) }
        .sheet(isPresented: $pairing) {
            NavigationStack {
                #if os(iOS)
                PhonePairingView(store: store).toolbar { Button("Close") { pairing = false } }
                #else
                OnboardingView(store: store, initialURL: store.account?.baseURL)
                #endif
            }
        }
        .sheet(isPresented: $instanceDetails) {
            NavigationStack { InstanceSettingsView(store: store).toolbar { Button("Close") { instanceDetails = false } } }
                .frame(minWidth: 320, minHeight: 400)
        }
        .confirmationDialog("Restart Lemon?", isPresented: $restart, titleVisibility: .visible) {
            Button("Restart Lemon", role: .destructive) { run(.restart) }
        } message: { Text(instanceConfirmation(.restart, via: store.instanceStatus?.runtime.via)) }
        .task(id: store.connectionIssue?.layer == .controllerDown) {
            guard store.connectionIssue?.layer == .controllerDown else { return }
            while !Task.isCancelled {
                do {
                    if store.canViewInstance {
                        let status = try await store.refreshInstance()
                        if status.controller.state == .connected { return }
                    } else {
                        let capabilities: Capabilities = try await store.read("/capabilities")
                        store.capabilities = capabilities
                        if capabilities.controlConnected { store.connectionIssue = nil; return }
                    }
                    try await Task.sleep(for: .seconds(store.instanceStatus?.runtime.operation?.state == .running ? 2 : 10))
                } catch is CancellationError { return }
                catch { action.error = error.localizedDescription; do { try await Task.sleep(for: .seconds(10)) } catch { return } }
            }
        }
        #if os(macOS)
        // A machine-key account never needs a password: re-sign in with the machine once, automatically.
        .task(id: store.connectionState) {
            guard store.connectionState == "reconnect_required", let route = store.account?.route else { return }
            await action.perform { try await store.connect(to: route) }
        }
        #endif
    }
    @ViewBuilder private var recoveryButtons: some View {
        if store.connectionState == "reconnect_required" {
            #if os(macOS)
            if let route = store.account?.route {
                Button("Reconnect") { Task { await action.perform { try await store.connect(to: route) } } }.buttonStyle(.lemonPrimary).disabled(action.inFlight)
            } else {
                Button("Sign in again") { signIn = true }.buttonStyle(.lemonPrimary)
            }
            #else
            Button("Sign in again") { signIn = true }.buttonStyle(.lemonPrimary)
            Button("Reconnect this device") { pairing = true }.buttonStyle(.pill(.secondary))
            #endif
        } else {
            Button("Try again") { Task { await action.perform { try await store.retryNow() } } }.buttonStyle(.lemonPrimary).disabled(action.inFlight)
        }
        Button("Connect somewhere else…") { connectElsewhere = true }.buttonStyle(.pill(.secondary))
    }
    @ViewBuilder private var controllerActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let runtime = store.instanceStatus?.runtime {
                if let copy = instanceLifecycleCopy(runtime.via) { Text(copy).font(LBFont.meta).foregroundStyle(LB.muted) }
                if let reason = runtime.reason { Text(reason).font(LBFont.meta).foregroundStyle(LB.muted) }
            }
            if store.canControlInstance {
                HStack {
                    if store.instanceStatus?.runtime.actions.contains(.start) == true { Button("Start Lemon") { run(.start) } }
                    if store.instanceStatus?.runtime.actions.contains(.restart) == true { Button("Restart Lemon") { restart = true } }
                }.buttonStyle(.pill(.secondary)).disabled(action.busy || store.instanceStatus?.runtime.operation?.state == .running || store.pendingIntents.contains { $0.path.hasPrefix("/instance/runtime/") })
            }
            if let state = store.instanceStatus?.controller.state, [.rejected, .stopped, .reconnecting].contains(state) {
                Button("Reconnect Lemon link") { Task { await action.perform { try await store.reconnectLemonLink() } } }.buttonStyle(.pill(.secondary)).disabled(action.busy)
            }
        }
    }
    private func run(_ runtimeAction: RuntimeAction) {
        Task { await action.perform { try await store.performRuntimeAction(runtimeAction, confirmed: runtimeAction != .start); try await store.waitForRuntimeOperation() } }
    }
}

struct RuntimeOperationView: View {
    let operation: RuntimeOperation
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if operation.state == .running { ProgressView().controlSize(.small) }
                Text(runtimeOperationLabel(operation.action, state: operation.state)).font(LBFont.metaEmphasis)
            }
            DisclosureGroup("Details · command output") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Started \(timestamp(operation.startedAtMs).formatted())")
                    if let completed = operation.completedAtMs { Text("Finished \(timestamp(completed).formatted())") }
                    if let code = operation.exitCode { Text("Exit code: \(code)") }
                    if !operation.output.isEmpty {
                        Text(operation.output).font(LBFont.code).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy output") { copyText(operation.output) }
                    }
                }.padding(.top, 4)
            }.font(LBFont.meta)
        }
    }
}

func runtimeOperationLabel(_ action: RuntimeAction, state: RuntimeOperation.State) -> String {
    switch (action, state) {
    case (.start, .running): return "Starting Lemon…"
    case (.stop, .running): return "Stopping Lemon…"
    case (.restart, .running): return "Restarting Lemon…"
    case (.start, .succeeded): return "Lemon started"
    case (.stop, .succeeded): return "Lemon stopped"
    case (.restart, .succeeded): return "Lemon restarted"
    case (.start, .failed): return "Lemon couldn’t start"
    case (.stop, .failed): return "Lemon couldn’t stop"
    case (.restart, .failed): return "Lemon couldn’t restart"
    }
}
