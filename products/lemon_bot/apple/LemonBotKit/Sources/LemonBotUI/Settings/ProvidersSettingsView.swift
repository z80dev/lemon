import SwiftUI
import LemonBotKit
#if os(iOS)
import UIKit
#endif

/// Shared owner-only provider management for the already running backend, on iPhone and Mac.
public struct ProvidersSettingsView: View {
    private let store: LemonBotStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var defaultProvider = ""
    @State private var defaultModel = ""
    private var state: ProviderSettingsState { store.providerSettings }
    private var pollKey: String {
        "\(store.account?.id ?? "")|\(state.machineID ?? "controller")|\(state.deviceLogin?.loginId ?? "")|\(state.deviceUnknown)|\(state.visible)|\(state.active)"
    }
    public init(store: LemonBotStore) { self.store = store }

    public var body: some View {
        Form {
            if store.member?.role == "owner" {
                targetSection
                if let management = state.management {
                    Section("Current default") {
                        LabeledContent("Provider", value: management.default.providerId ?? "Not selected")
                        LabeledContent("Model", value: management.default.modelId ?? "Not selected")
                        Text("Effective on this target, including project and environment precedence. Credential actions never change it.")
                    }
                    ForEach(management.providers) { provider in providerSection(provider) }
                    defaultSection(management)
                }
                if let login = state.deviceLogin { deviceSection(login) }
                if let message = state.message { Section { Text(message).foregroundStyle(LB.warning) } }
                if !store.providerPendingIntents.isEmpty {
                    Section("Unconfirmed action") {
                        Text("The original operation remains fenced. Observing configured status does not prove that a previous key, disconnect or default change settled. Keys are never retained for retry.")
                        if state.reviewedUnknownChange {
                            Text("This does not confirm the earlier change. Continue only after reviewing the exact target's current provider configuration.")
                            Button("I’ve checked — start a new change") { store.beginNewProviderChangeAfterReview() }
                                .disabled(state.busy || !store.canManageProviders)
                        }
                        if state.reviewedUnreachableDeviceLogin {
                            Text("The initiating session is no longer available. Retiring its local fence does not settle or revoke that login. No old operation will be replayed.")
                            Button("Retire previous session’s local login fence") { store.retireUnreachableProviderDeviceLoginAfterReview() }
                                .disabled(state.busy || !store.canManageProviders)
                        }
                    }
                }
                Section {
                    Button("Check status") {
                        Task {
                            await store.reloadProviders(reviewingUnknownChange: true)
                            await store.reconcileProviderDeviceLogin()
                        }
                    }.disabled(state.busy || !store.canManageProviders)
                    if state.busy { ProgressView("Checking selected execution target…") }
                    Text("API keys are write-only and never saved on this device. Avoid screenshots. Disconnect is local only, not provider-side revocation.")
                        .font(LBFont.meta).foregroundStyle(LB.muted)
                }
            } else { Text("Only workspace owners can manage Providers.") }
        }
        .formStyle(.grouped)
        .navigationTitle("Providers")
        .privacySensitive()
        .overlay {
            if scenePhase != .active || !state.active {
                ZStack { LB.canvas; Label("Providers hidden while inactive", systemImage: "lock.fill") }
            }
        }
        .task(id: store.account?.id) {
            state.setPresentation(visible: true, active: scenePhase == .active)
            await store.reloadProviders()
        }
        .task(id: pollKey) {
            while !Task.isCancelled {
                if state.busy {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                guard let delay = state.nextPollDelay else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                if state.busy { continue }
                guard state.nextPollDelay != nil else { return }
                await store.pollProviderDeviceLogin()
            }
        }
        .onChange(of: scenePhase) { _, phase in state.setPresentation(visible: true, active: phase == .active) }
        .onChange(of: state.machineID) { _, _ in defaultProvider = ""; defaultModel = "" }
        .onChange(of: store.account?.id) { _, _ in defaultProvider = ""; defaultModel = "" }
        .onDisappear { state.setPresentation(visible: false, active: scenePhase == .active) }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            state.setPresentation(visible: state.visible, active: false)
        }
        #endif
        .confirmationDialog("Confirm provider change", isPresented: Binding(get: { state.confirmation != nil }, set: { if !$0 { state.cancelConfirmation() } }), titleVisibility: .visible) {
            if let confirmation = state.confirmation {
                switch confirmation {
                case .disconnect:
                    Button("Disconnect", role: .destructive) { Task { await store.confirmProviderChange(confirmation) } }
                case .changeDefault:
                    Button("Change default") { Task { await store.confirmProviderChange(confirmation) } }
                }
            }
            Button("Cancel", role: .cancel) { state.cancelConfirmation() }
        } message: { Text(confirmationText) }
    }
    private var targetSection: some View {
        Section("Execution target") {
            LabeledContent("Backend") { Text(store.account.map { ConnectionIssue.origin(for: $0.baseURL) } ?? "Not connected").textSelection(.enabled) }
            LabeledContent("Workspace", value: store.workspace?.name ?? "Unavailable")
            LabeledContent("Workspace ID", value: store.account?.workspaceID ?? "Unavailable")
            Picker("Execution target", selection: Binding(get: { state.machineID ?? "" }, set: { id in
                state.clearCredential(); state.cancelConfirmation()
                Task { await store.selectProviderTarget(machineID: id.isEmpty ? nil : id) }
            })) {
                Text("Controller").tag("")
                ForEach(store.ownedProviderMachines) { machine in Text("\(machine.name) · \(machine.status)").tag(machine.id) }
            }.disabled(state.busy)
            if let id = state.machineID { LabeledContent("Machine ID", value: id) }
            if let target = state.management?.target {
                LabeledContent("Hostname", value: target.hostname)
                LabeledContent("Target ID", value: target.id)
                LabeledContent("Node ID", value: target.nodeId ?? "Controller (no node)")
            }
            if !store.canManageProviders { Text("Selected target is offline, unavailable or no longer owned by this account. No changes can be submitted.").foregroundStyle(LB.warning) }
            Text("Review this exact backend, workspace and target before every write. Selecting a target never copies credentials.").font(LBFont.meta)
        }
    }
    private func providerSection(_ provider: ManagedProvider) -> some View {
        Section(provider.displayName) {
            LabeledContent("Status", value: provider.status.label)
            LabeledContent("Configured", value: provider.configured ? "Yes" : "No")
            LabeledContent("Provider ID", value: provider.id)
            Text("Sign-in methods: " + provider.methods.map { method in
                switch method { case .apiKey: "API key"; case .deviceCode: "Device code"; case .unsupported: "Unsupported" }
            }.joined(separator: ", "))
            if let validation = provider.lastValidation {
                Text("Last resolver validation: \(validation.ready ? "Ready" : "Not ready") · \(Date(timeIntervalSince1970: validation.atMs / 1000).formatted())")
            } else { Text("Last resolver validation: Not checked") }
            Text("Resolver validation is static, not a live account, quota or model-call check.").font(LBFont.meta).foregroundStyle(LB.muted)
            if !provider.environmentOverrides.isEmpty {
                Text("Environment overrides: " + provider.environmentOverrides.joined(separator: ", ")).foregroundStyle(LB.warning)
            }
            if !provider.configurationOverrides.isEmpty {
                Text("Configuration overrides: " + provider.configurationOverrides.map { $0.rawValue.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ")).foregroundStyle(LB.warning)
            }
            if !provider.environmentOverrides.isEmpty || !provider.configurationOverrides.isEmpty {
                Text("Higher-priority credentials/configuration may prevent a saved key or default from taking effect. Resolve overrides deliberately on this target.").foregroundStyle(LB.warning)
            }
            if state.editingProviderID == provider.id {
                SecureField("API key (write-only)", text: Binding(get: { state.secret }, set: { state.secret = $0 }))
                    .privacySensitive().autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button(provider.configured ? "Replace credential" : "Add API key") { Task { await store.submitProviderCredential() } }
                    .disabled(!store.canWriteProviders || state.secret.isEmpty)
                Button("Cancel", role: .cancel) { state.clearCredential() }
                Text("Sent once to the target's encrypted secret store. Input clears immediately on submit, failure, cancel, navigation and backgrounding.").font(LBFont.meta)
            } else if provider.methods.contains(.apiKey) {
                Button(provider.configured ? "Replace credential" : "Add API key") { store.beginProviderCredential(provider.id) }.disabled(!store.canWriteProviders)
            }
            if provider.id == "openai_codex", provider.methods.contains(.deviceCode) {
                Button(provider.configured ? "Re-authenticate" : "Sign in with device code") { Task { await store.startProviderDeviceLogin() } }
                    .disabled(!store.canWriteProviders || state.deviceLogin?.terminal == false)
                Text("Your ChatGPT account or organization may need Codex device-code sign-in enabled.").font(LBFont.meta)
            }
            if provider.methods == [.unsupported] { Text("This provider has no supported phone-completable sign-in method.") }
            Button("Disconnect", role: .destructive) { store.requestProviderDisconnect(provider.id) }.disabled(!store.canWriteProviders || !provider.configured)
        }
    }
    private func defaultSection(_ management: ProviderManagement) -> some View {
        Section("Change default") {
            Picker("Provider", selection: $defaultProvider) {
                Text("Choose provider").tag("")
                ForEach(management.providers) { Text($0.displayName).tag($0.id) }
            }.disabled(state.confirmation != nil)
            TextField("Exact model ID", text: $defaultModel).autocorrectionDisabled().disabled(state.confirmation != nil)
            Button("Change default") { store.requestProviderDefault(providerID: defaultProvider, modelID: defaultModel) }
                .disabled(!store.canWriteProviders || defaultProvider.isEmpty || defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Separate confirmed action. Changes only the global target default; never rewrites Bots or profiles. Overrides may leave the effective Current default unchanged.").font(LBFont.meta)
        }
    }
    private func deviceSection(_ login: ProviderDeviceLogin) -> some View {
        Section("Codex device login") {
            LabeledContent("Status", value: login.status.label)
            if login.status == .pending, let expiry = login.expiresAtMs {
                TimelineView(.explicit([Date(timeIntervalSince1970: expiry / 1000)])) { context in
                if expiry > context.date.timeIntervalSince1970 * 1000 {
                    if let code = login.userCode { LabeledContent("User code") { Text(code).font(.system(.title3, design: .monospaced)).textSelection(.enabled).privacySensitive() } }
                    if let url = login.browserURL {
                        Text(url.absoluteString).textSelection(.enabled)
                        Link("Open sign-in in browser", destination: url)
                    }
                    Text("Enter this code in your normal browser. No passwords or provider tokens return to this app.")
                } else { Text("Device code expired. Automatic checks stopped. Check status explicitly.").foregroundStyle(LB.warning) }
                }
                Text("Expires: \(Date(timeIntervalSince1970: expiry / 1000).formatted())")
            }
            if login.terminal { Text("Provider status is reloaded after a terminal result. Completed does not itself mean Ready.") }
            else { Button("Cancel device login", role: .cancel) { Task { await store.cancelProviderDeviceLogin() } }.disabled(state.busy || state.deviceUnknown || !store.canManageProviders) }
        }
    }
    private var confirmationText: String {
        guard let confirmation = state.confirmation else { return "" }
        let target: ProviderManagement.Target
        let action: String
        switch confirmation {
        case .disconnect(let providerID, let value):
            target = value
            action = "Disconnect \(providerID) locally only. This does not revoke keys or grants at the provider. Environment/external credentials may still resolve. Revoke separately in the provider dashboard if needed. The default will not change."
        case .changeDefault(let providerID, let modelID, let value):
            target = value
            action = "Change the global default to \(providerID) / \(modelID). This does not rewrite any Bot or profile. Higher-priority overrides may leave the effective default unchanged."
        }
        return "\(action)\n\nBackend: \(store.account.map { ConnectionIssue.origin(for: $0.baseURL) } ?? "")\nWorkspace: \(store.account?.workspaceID ?? "")\nExecution target: \(target.hostname)\nTarget ID: \(target.id)\nNode ID: \(target.nodeId ?? "Controller")"
    }
}
