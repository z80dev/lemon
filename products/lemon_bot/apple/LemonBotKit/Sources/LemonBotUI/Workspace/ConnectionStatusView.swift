import SwiftUI
import LemonBotKit
#if os(macOS)
import AppKit
#endif

/// The same explanation and recovery actions in the workspace, sidebar popover and phone sheet.
public struct ConnectionStatusView: View {
    let store: LemonBotStore
    @State private var action = UIActionState()
    @State private var chooseBackend = false
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
                if issue.layer == .backendUnreachable, let url = URL(string: issue.origin), ConnectionIssue.isLoopback(url) { LocalLemonStartHelp() }
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
        .sheet(isPresented: $chooseBackend) { ChooseLemonBotView(store: store) }
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
        } message: { Text("Bots stop working while Lemon restarts. They can work again once it reconnects.") }
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
    }
    @ViewBuilder private var recoveryButtons: some View {
        if store.connectionState == "reconnect_required" {
            Button("Sign in again") { signIn = true }.buttonStyle(.lemonPrimary)
            #if os(iOS)
            Button("Reconnect this device") { pairing = true }.buttonStyle(.pill(.secondary))
            #endif
        } else {
            Button("Try again") { Task { await action.perform { try await store.retryNow() } } }.buttonStyle(.lemonPrimary).disabled(action.inFlight)
        }
        Button("Choose another Lemon Bot…") { chooseBackend = true }.buttonStyle(.pill(.secondary))
    }
    @ViewBuilder private var controllerActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.canControlInstance {
                HStack {
                    Button("Start Lemon") { run(.start) }
                    Button("Restart Lemon") { restart = true }
                }.buttonStyle(.pill(.secondary)).disabled(action.busy || store.instanceStatus?.runtime.operation?.state == .running)
            } else if let reason = store.instanceStatus?.runtime.reason { Text(reason).font(LBFont.meta).foregroundStyle(LB.muted) }
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
                Text("Lemon \(operation.action.rawValue) · \(operation.state.rawValue)").font(LBFont.metaEmphasis)
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

 #if os(macOS)
struct LocalLemonStartHelp: View {
    private let backendCommand = "bun run --cwd products/lemon_bot/backend start"
    var body: some View {
        DisclosureGroup("Start it on this Mac") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open Terminal in your Lemon checkout. Start Lemon, then start Lemon Bot in another tab with your existing backend environment configured. This app will detect it when it comes online.").font(LBFont.meta)
                command("lemon daemon")
                command(backendCommand)
                HStack {
                    Button("Open Terminal") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                    }.buttonStyle(.pill(.secondary, compact: true))
                    Link("Setup instructions", destination: URL(string: "https://github.com/z80dev/lemon/blob/main/products/lemon_bot/README.md#running-an-integrated-checkout")!)
                }
            }.padding(.top, 8)
        }.font(LBFont.meta)
    }
    private func command(_ value: String) -> some View {
        HStack { Text(value).font(LBFont.code).textSelection(.enabled); Spacer(minLength: 8); Button("Copy") { copyText(value) }.buttonStyle(.pill(.secondary, compact: true)) }
    }
}
#endif

struct ChooseLemonBotView: View {
    let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var discovered: [DiscoveredBackend] = []
    @State private var discovering = false
    @State private var address: URL?
    @State private var onboarding = false
    @State private var action = UIActionState()
    var body: some View {
        NavigationStack {
            List {
                Section("Saved accounts") {
                    ForEach(store.accounts) { account in
                        Button { Task { await action.perform { try await store.restoreAccount(account); dismiss() } } } label: {
                            VStack(alignment: .leading) { Text(account.email); Text(ConnectionIssue.origin(for: account.baseURL)).font(LBFont.meta).foregroundStyle(LB.muted) }
                        }
                    }
                }
                Section("Reachable Lemon Bots") {
                    if discovering { ProgressView("Looking for Lemon Bot…") }
                    ForEach(discovered) { backend in
                        Button { address = backend.baseURL; onboarding = true } label: {
                            VStack(alignment: .leading) { Text(ConnectionIssue.origin(for: backend.baseURL)); Text("Version \(backend.version) · \(backend.setupRequired ? "Needs setup" : "Ready to sign in")").font(LBFont.meta) }
                        }
                    }
                    if !discovering && discovered.isEmpty { Text("No services found at your saved addresses or localhost.").foregroundStyle(LB.muted) }
                    Button("Look again") { Task { await discover() } }.disabled(discovering)
                }
                Button("Enter address…") { address = nil; onboarding = true }
                ActionErrorView(message: action.error)
            }.navigationTitle("Choose Lemon Bot").toolbar { Button("Close") { dismiss() } }
        }.frame(minWidth: 320, minHeight: 400)
            .task { await discover() }
            .sheet(isPresented: $onboarding) { OnboardingView(store: store, initialURL: address) }
    }
    private func discover() async { discovering = true; discovered = await store.discoverBackends(); discovering = false }
}

