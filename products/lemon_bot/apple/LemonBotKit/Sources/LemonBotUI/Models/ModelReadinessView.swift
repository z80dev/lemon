import SwiftUI
import LemonBotKit

/// Model readiness for one execution target (the machine a Bot runs on), shared by Create Bot and
/// the first-run card. Every action is the owner's explicit confirmation, is fenced to the captured
/// (workspace, machine, target), and stops at the first failure or unconfirmed outcome: nothing is
/// retried, and no later step of a sequence runs on an unproven one.
public struct ModelReadinessView: View {
    private let store: LemonBotStore
    private let machineID: ID
    private let onReadyChange: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase

    private enum LoadState { case loading, unavailable, loaded }

    @State private var loadState: LoadState = .loading
    @State private var working = false
    @State private var statusMessage: String?
    @State private var autoCheckedTarget: String?
    @State private var handledDeviceLogin: String?
    @State private var isSkipped = false
    @State private var showConsent = false
    @State private var showApiKeyForm = false
    @State private var selectedApiKeyProvider = ""
    @State private var apiKeySecret = ""

    public init(store: LemonBotStore, machineID: ID, onReadyChange: @escaping (Bool) -> Void) {
        self.store = store
        self.machineID = machineID
        self.onReadyChange = onReadyChange
    }

    // MARK: - Target state

    private var machine: Machine? { store.machines.first { $0.id == machineID } }
    private var management: ProviderManagement? {
        store.providerSettings.machineID == machineID ? store.providerSettings.management : nil
    }
    private var readiness: ModelReadiness? { management?.readiness }
    private var hostname: String { management?.target.hostname ?? machine?.name ?? "this machine" }
    private var unresolved: Bool { !store.providerPendingIntents.isEmpty || store.providerSettings.deviceUnknown }
    /// A new action needs owner write access on this exact target, no in-flight work and no
    /// unconfirmed earlier operation. Observing status never releases that fence.
    private var actionsEnabled: Bool { store.canWriteProviders && !working && !unresolved }

    /// While the target is still loading, Create stays gated unless Skip was already chosen.
    /// A target whose readiness cannot be read never gates.
    private var effectiveReadyOrSkipped: Bool {
        switch loadState {
        case .loading: return isSkipped
        case .unavailable: return true
        case .loaded:
            return ModelReadinessGate.readyOrSkipped(readiness: readiness, canManage: store.canManageProviders,
                                                     machineOnline: machine?.status == "online", skipped: isSkipped)
        }
    }

    private var pollKey: String {
        "\(machineID)|\(store.providerSettings.deviceLogin?.loginId ?? "")|\(store.providerSettings.deviceUnknown)|\(store.providerSettings.visible)|\(store.providerSettings.active)"
    }

    public var body: some View {
        SwiftUI.Section("Model readiness") {
            switch loadState {
            case .unavailable:
                Text("Model status unavailable.").font(LBFont.meta).foregroundStyle(LB.muted)
            case .loading:
                progressRow(statusMessage ?? "Checking this machine's model status…")
            case .loaded:
                if working {
                    progressRow(statusMessage ?? "Working on this machine's model…")
                } else if readiness?.isReady == true {
                    readyContent
                } else if isSkipped {
                    skippedContent
                } else {
                    notReadyContent
                }
                unresolvedContent
                if let message = store.providerSettings.message {
                    Text(message).font(LBFont.meta).foregroundStyle(LB.warning)
                }
            }
        }
        .task(id: "\(machineID)|\(store.account?.id ?? "")|\(store.connectionState)") {
            await handleTargetLoad()
        }
        .task(id: pollKey) {
            while !Task.isCancelled {
                if store.providerSettings.busy {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    continue
                }
                guard let delay = store.providerSettings.nextPollDelay else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, !store.providerSettings.busy, store.providerSettings.nextPollDelay != nil else { return }
                await store.pollProviderDeviceLogin()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            store.providerSettings.setPresentation(visible: true, active: phase == .active)
        }
        .onDisappear {
            apiKeySecret = ""
            store.providerSettings.setPresentation(visible: false, active: scenePhase == .active)
        }
        .onChange(of: store.providerSettings.deviceLogin?.status) { _, status in
            deviceLoginStatusChanged(status)
        }
        .confirmationDialog("Copy Codex CLI login", isPresented: $showConsent, titleVisibility: .visible) {
            Button("Copy login and connect") { Task { await connectCodexCLI() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Copy your Codex CLI ChatGPT login on \(hostname) into Lemon. Lemon keeps and refreshes its own copy; your ~/.codex/auth.json is not changed. If either app later asks you to sign in again, sign in there — or use Sign in with ChatGPT to give Lemon its own login.")
        }
    }

    // MARK: - Sections

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(LBFont.meta).foregroundStyle(LB.muted)
        }
    }

    @ViewBuilder private var readyContent: some View {
        if let readiness {
            HStack {
                Text("Model status")
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: readiness.state == .verified ? "checkmark.circle.fill" : "info.circle")
                    Text(readiness.state == .verified ? "Verified" : "Saved")
                }
                .font(LBFont.chip)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(readiness.state == .verified ? LB.success.opacity(0.15) : LB.fill, in: Capsule())
                .foregroundStyle(readiness.state == .verified ? LB.success : LB.ink)
            }
            if let model = readiness.modelId ?? management?.default.modelId {
                let provider = readiness.providerId ?? management?.default.providerId ?? "the provider"
                Text(readiness.state == .verified
                    ? "Model: \(model) (verified with \(provider); no message was sent)."
                    : "Model: \(model) (saved; Lemon checks it on your first message).")
                    .font(LBFont.meta).foregroundStyle(LB.muted)
            }
            if readiness.reason == .providerUnreachable {
                Text("The provider could not be reached; the credential is saved.").font(LBFont.meta).foregroundStyle(LB.warning)
            } else if readiness.reason == .checkFailed {
                Text("The live check could not complete; the credential is saved.").font(LBFont.meta).foregroundStyle(LB.warning)
            }
        }
    }

    @ViewBuilder private var skippedContent: some View {
        Text("Model skipped on \(hostname) — replies will fail until you connect one.")
            .font(LBFont.meta).foregroundStyle(LB.muted)
        Button("Connect a model") { setSkipped(false) }
            .buttonStyle(.pill(.secondary, compact: true))
    }

    @ViewBuilder private var notReadyContent: some View {
        Text("Connect a model on \(hostname)").font(LBFont.rowTitle).foregroundStyle(LB.ink)
        Text("Replies on this machine will fail until a model is connected.")
            .font(LBFont.meta).foregroundStyle(LB.muted)
        if let reason = readiness?.reason {
            Text(reasonLabel(reason)).font(LBFont.meta).foregroundStyle(LB.warning)
        }
        if let detected = management?.detected {
            if detected.contains(where: { $0.source == .codexCLI && $0.providerId == "openai_codex" }) {
                Button("Use your Codex CLI login") { showConsent = true }
                    .buttonStyle(.lemonPrimary).disabled(!actionsEnabled)
            }
            ForEach(detected.filter { $0.source == .environment }, id: \.self) { detectedEnv in
                let variableName = detectedEnv.variable ?? "the detected API key"
                Button("Use \(variableName) found on \(hostname)") {
                    Task { await connectDetectedEnvironment(providerID: detectedEnv.providerId) }
                }
                .buttonStyle(.lemonPrimary).disabled(!actionsEnabled)
            }
        }
        if management?.providers.first(where: { $0.id == "openai_codex" })?.methods.contains(.deviceCode) == true {
            if let login = store.providerSettings.deviceLogin, !login.terminal {
                deviceLoginInProgressView(login)
            } else {
                Button("Sign in with ChatGPT (device code)") { Task { await store.startProviderDeviceLogin() } }
                    .buttonStyle(.pill(.secondary, compact: true)).disabled(!actionsEnabled)
            }
        }
        apiKeySection
        Button("Skip for now") { setSkipped(true) }
            .buttonStyle(.pill(.quiet, compact: true))
    }

    @ViewBuilder private var apiKeySection: some View {
        DisclosureGroup(isExpanded: $showApiKeyForm) {
            if let providers = management?.providers.filter({ $0.methods.contains(.apiKey) }), !providers.isEmpty {
                Picker("Provider", selection: $selectedApiKeyProvider) {
                    ForEach(providers) { provider in Text(provider.displayName).tag(provider.id) }
                }
            }
            SecureField("API key (write-only)", text: $apiKeySecret)
                .privacySensitive().autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            Button("Save API key") { Task { await connectApiKey() } }
                .buttonStyle(.pill(.secondary, compact: true))
                .disabled(!actionsEnabled || apiKeySecret.isEmpty || selectedApiKeyProvider.isEmpty)
            Text("Sent once to this machine's encrypted store. Input clears immediately on submit, failure and when this step closes; it is never kept on this device.")
                .font(LBFont.meta).foregroundStyle(LB.muted)
        } label: {
            Text("Paste an API key").font(LBFont.rowSubtitle).foregroundStyle(LB.ink)
        }
    }

    @ViewBuilder private func deviceLoginInProgressView(_ login: ProviderDeviceLogin) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device sign-in started").font(LBFont.rowTitle).foregroundStyle(LB.ink)
            if let code = login.userCode {
                Text(code).font(.system(.title3, design: .monospaced, weight: .bold))
                    .foregroundStyle(LB.accent).textSelection(.enabled)
            }
            if let value = login.verificationUrl, let url = URL(string: value), url.scheme == "https" {
                Link("Open the sign-in page", destination: url).font(LBFont.metaEmphasis).foregroundStyle(LB.accent)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(login.status.label).font(LBFont.meta).foregroundStyle(LB.muted)
            }
            Button("Cancel device sign-in", role: .cancel) { Task { await store.cancelProviderDeviceLogin() } }
                .buttonStyle(.pill(.quiet, compact: true)).disabled(working || store.providerSettings.busy)
        }
        .padding(8).background(LB.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// An unconfirmed earlier operation is never retried here. Status can be re-read, and only a
    /// separately chosen new action may follow after that review.
    @ViewBuilder private var unresolvedContent: some View {
        if unresolved {
            Text("An earlier provider action is unconfirmed. Reading status does not prove it settled, and nothing is resubmitted.")
                .font(LBFont.meta).foregroundStyle(LB.warning)
            Button("Check status") {
                Task {
                    await store.reloadProviders(reviewingUnknownChange: true)
                    await store.reconcileProviderDeviceLogin()
                }
            }
            .buttonStyle(.pill(.quiet, compact: true)).disabled(working || store.providerSettings.busy)
            if store.providerSettings.reviewedUnknownChange {
                Button("I’ve checked — start a new change") { store.beginNewProviderChangeAfterReview() }
                    .buttonStyle(.pill(.quiet, compact: true)).disabled(working || store.providerSettings.busy)
            }
            if store.providerSettings.reviewedUnreachableDeviceLogin {
                Button("Retire the previous session’s local login fence") { store.retireUnreachableProviderDeviceLoginAfterReview() }
                    .buttonStyle(.pill(.quiet, compact: true)).disabled(working || store.providerSettings.busy)
            }
        }
    }

    // MARK: - Loading

    private func handleTargetLoad() async {
        isSkipped = ModelReadinessSkipStore.isSkipped(workspaceID: store.workspace?.id, machineID: machineID)
        loadState = .loading
        onReadyChange(effectiveReadyOrSkipped)
        store.providerSettings.setPresentation(visible: true, active: scenePhase == .active)
        guard store.canManageProviders, machine?.status == "online" else { return markUnavailable() }
        if store.providerSettings.machineID != machineID {
            await store.selectProviderTarget(machineID: machineID)
        }
        guard !Task.isCancelled, store.providerSettings.machineID == machineID else { return }
        guard let listing = management, listing.readiness != nil else { return markUnavailable() }
        loadState = .loaded
        if selectedApiKeyProvider.isEmpty || !listing.providers.contains(where: { $0.id == selectedApiKeyProvider }) {
            selectedApiKeyProvider = listing.providers.first(where: { $0.methods.contains(.apiKey) })?.id ?? ""
        }
        await autoCheckIfUnproven(listing)
        onReadyChange(effectiveReadyOrSkipped)
    }

    private func markUnavailable() {
        loadState = .unavailable
        onReadyChange(true)
    }

    /// One automatic check per target: a saved credential, or action_required with a credential
    /// present, is the only state a non-generating check can still improve.
    private func autoCheckIfUnproven(_ listing: ProviderManagement) async {
        guard let current = listing.readiness, autoCheckedTarget != listing.target.id, actionsEnabled else { return }
        let hasCredential = listing.providers.contains(where: { $0.configured }) || listing.default.providerId != nil
        guard current.state == .saved || (current.state == .actionRequired && hasCredential) else { return }
        autoCheckedTarget = listing.target.id
        working = true
        statusMessage = "Checking your model credential with the provider — no message is sent…"
        _ = await store.checkProviders()
        working = false
        statusMessage = nil
    }

    // MARK: - Fencing

    private struct TargetFence: Equatable {
        let workspaceID: String?
        let machineID: ID
        let targetID: String
    }

    private func currentFence() -> TargetFence? {
        guard store.providerSettings.machineID == machineID, let target = store.providerSettings.management?.target else { return nil }
        return TargetFence(workspaceID: store.workspace?.id, machineID: machineID, targetID: target.id)
    }

    /// The exact workspace, machine and execution target must still be selected, with owner write
    /// access and no unconfirmed operation, before another step of a sequence may be sent.
    private func fenceHolds(_ fence: TargetFence) -> Bool {
        store.workspace?.id == fence.workspaceID &&
        store.providerSettings.machineID == fence.machineID &&
        store.providerSettings.management?.target.id == fence.targetID &&
        store.canWriteProviders
    }

    // MARK: - Connect actions

    private func connectCodexCLI() async {
        guard actionsEnabled, let fence = currentFence() else { return }
        working = true
        statusMessage = "Copying the Codex CLI login into Lemon…"
        let imported = await store.importCodexLogin()
        guard imported != nil, fenceHolds(fence) else { return finishSequence() }
        await completeConnectSequence(providerID: "openai_codex", fence: fence)
    }

    /// A key already visible to the target process needs no write: the sequence only proves it.
    private func connectDetectedEnvironment(providerID: String) async {
        guard actionsEnabled, let fence = currentFence() else { return }
        await completeConnectSequence(providerID: providerID, fence: fence)
    }

    private func connectApiKey() async {
        let providerID = selectedApiKeyProvider, key = apiKeySecret
        apiKeySecret = "" // Cleared before validation and before the first suspension, on every path.
        guard actionsEnabled, !providerID.isEmpty, let fence = currentFence() else { return }
        working = true
        statusMessage = "Saving the API key to this machine's encrypted store…"
        let saved = await store.submitProviderApiKey(providerID: providerID, key: key)
        guard saved != nil, fenceHolds(fence) else { return finishSequence() }
        await completeConnectSequence(providerID: providerID, fence: fence)
    }

    private func deviceLoginStatusChanged(_ status: ProviderDeviceLogin.Status?) {
        guard status == .completed, let login = store.providerSettings.deviceLogin,
              login.status == .completed, handledDeviceLogin != login.loginId,
              !store.providerSettings.deviceUnknown, let fence = currentFence() else { return }
        handledDeviceLogin = login.loginId
        Task { await completeConnectSequence(providerID: login.providerId, fence: fence) }
    }

    /// The single owner click authorizes the whole sequence: check the connected provider, then,
    /// only when the target's *default* is missing or itself not ready, set and re-check it.
    /// Any failure, unconfirmed outcome or fence change stops the sequence where it is.
    private func completeConnectSequence(providerID: String, fence: TargetFence) async {
        working = true
        statusMessage = "Checking the credential with the provider — no message is sent…"
        guard fenceHolds(fence) else { return finishSequence() }
        guard let checked = await store.checkProviders(providerID: providerID), fenceHolds(fence) else { return finishSequence() }

        var defaultIsReady = false
        if store.providerSettings.management?.default.providerId != nil {
            statusMessage = "Checking the default model — no message is sent…"
            guard let defaultCheck = await store.checkProviders(), fenceHolds(fence) else { return finishSequence() }
            defaultIsReady = defaultCheck.readiness.isReady
        }
        guard !defaultIsReady, let suggested = checked.readiness.suggestedModelId else { return finishSequence() }

        statusMessage = "Setting the default model on this machine…"
        guard await store.setProviderDefault(providerID: providerID, modelID: suggested) != nil, fenceHolds(fence) else { return finishSequence() }
        statusMessage = "Checking the default model — no message is sent…"
        _ = await store.checkProviders()
        finishSequence()
    }

    private func finishSequence() {
        working = false
        statusMessage = nil
        if loadState == .loaded { onReadyChange(effectiveReadyOrSkipped) }
    }

    private func setSkipped(_ skipped: Bool) {
        isSkipped = skipped
        ModelReadinessSkipStore.setSkipped(skipped, workspaceID: store.workspace?.id, machineID: machineID)
        onReadyChange(effectiveReadyOrSkipped)
    }

    private func reasonLabel(_ reason: ModelReadiness.Reason) -> String {
        switch reason {
        case .credentialMissing: return "No credential is saved for this provider."
        case .credentialExpired: return "The saved credential has expired."
        case .credentialRejected: return "The provider rejected the saved credential."
        case .modelUnavailable: return "The configured model is not available for this account."
        case .providerUnreachable: return "The provider could not be reached."
        case .checkUnavailable: return "This provider has no lightweight live check."
        case .checkFailed: return "The live check could not complete."
        case .noDefault: return "No default model is configured on this machine."
        case .modelProviderMismatch: return "The configured model does not match the default provider."
        }
    }
}
