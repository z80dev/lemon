#if os(iOS)
import SwiftUI
import UIKit
import LemonBotKit

public struct PhonePairingView: View {
    private let store: LemonBotStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var scanning = false
    @State private var working = false
    @State private var action: PairingAction?
    @State private var error: String?
    @State private var lastChecked: Date?
    @State private var observationRevision = 0

    private enum PairingAction: Hashable { case preview, request, check }
    private struct ObservationID: Hashable {
        var requestID: ID?
        var foreground: Bool
        var reconciliation: Int
    }
    public init(store: LemonBotStore) { self.store = store }

    public var body: some View {
        Form {
            Section("1. Scan or paste") {
                Text("On your Mac choose Connect iPhone. Both devices connect to the same already running Lemon Bot backend. No desktop password is needed.")
                if store.pendingPairing == nil && !hasSavedConnection {
                    Button("Scan QR code") { scanning = true }.disabled(busy)
                    SecureField("Paste lemonbot://pair link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                        .disabled(busy)
                    Button("Check pasted link") { prepare(link) }.disabled(link.isEmpty || busy)
                }
            }
            if let preview = store.pendingPairing {
                Section("2. Verify this connection") {
                    if preview.expiresAtMs != nil {
                        Text(preview.clusterName).font(.headline)
                        if ["preview_ready", "pending_approval", "completing"].contains(store.pairingState) {
                            Label("QR backend and workspace preview checked", systemImage: "checkmark.shield")
                        } else {
                            Text("Saved preview — current connection is not verified.").font(LBFont.meta)
                        }
                    } else {
                        Text("Check the backend before requesting access.")
                    }
                    Text(preview.origin).textSelection(.enabled)
                    Text("Backend instance: \(preview.instanceID)").font(LBFont.meta).textSelection(.enabled)
                    Text("Workspace ID: \(preview.workspaceID)").font(LBFont.meta).textSelection(.enabled)
                    if let expiry = preview.expiresAtMs {
                        Text("Original expiry: \(Date(timeIntervalSince1970: expiry / 1000).formatted(date: .abbreviated, time: .standard))")
                    }
                    Text("The address and instance must match your Mac. Checking the preview does not consume the QR; Request connection is your separate consent.")
                        .font(LBFont.meta)
                }
                if let code = preview.verificationCode {
                    Section("3. Compare on your Mac") {
                        if let deviceName = preview.deviceName {
                            Text("This device: \(deviceName)").textSelection(.enabled)
                        }
                        Text(code).font(.largeTitle.monospaced()).textSelection(.enabled).privacySensitive()
                        Text("Compare this exact six-digit code and device name on both devices. Only then select the matching-device checkbox and Approve this iPhone on your Mac. Deny any mismatch.")
                    }
                }
            }
            if hasSavedConnection, let account = store.account {
                Section("Workspace on this iPhone") {
                    Label(savedConnectionLabel, systemImage: verifiedConnection ? "checkmark.circle" : "exclamationmark.circle")
                    Text(store.workspace?.id == account.workspaceID ? store.workspace?.name ?? account.workspaceID : account.workspaceID)
                        .font(.headline)
                    Text(account.baseURL.absoluteString).textSelection(.enabled)
                    Text("Workspace ID: \(account.workspaceID)").font(LBFont.meta).textSelection(.enabled)
                    if let instanceID = account.instanceID {
                        Text("Saved backend instance: \(instanceID)").font(LBFont.meta).textSelection(.enabled)
                    }
                    if verifiedConnection {
                        Text("Your own device credential is saved in Keychain. You are connected to the verified workspace, not a copy of the Mac's session.")
                    } else if store.connectionState == "reconnect_required" {
                        Text("Saved access could not be verified or was revoked. Cached workspace content stays available, but this is not a connected session. Open connection recovery and reconnect explicitly.")
                    } else {
                        Text("Your device credential is saved, but the workspace is not online. Initial synchronization may still be running or may have failed. Cached content is not proof of a live connection.")
                    }
                    Button(verifiedConnection ? "Open workspace" : "Open saved workspace and connection status") { dismiss() }
                    if !verifiedConnection {
                        Button("Start a new connection with a desktop QR") {
                            do { try store.cancelPairing(); error = nil; lastChecked = nil }
                            catch { self.error = humanErrorText(error) }
                        }.disabled(busy)
                    }
                }
            }
            Section("Connection status") {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusLabel(at: context.date))
                    if ["preview", "preview_ready"].contains(store.pairingState) {
                        Button("Check workspace") { perform(.preview) }.disabled(busy)
                        Button("Request connection") { perform(.request) }
                            .disabled(busy || store.pairingState != "preview_ready" || !previewReady(at: context.date))
                    }
                    if store.pairingState == "pending_approval" {
                        if PhonePairingProgress.shouldObserve(state: store.pairingState, expiresAtMs: store.pendingPairing?.expiresAtMs, now: context.date) {
                            Text("Approval and completion update automatically while this screen is active. After approval, your phone verifies its own session before saving it.")
                                .font(LBFont.meta)
                        }
                        Text("Live checks pause when you leave this screen or the app. The original expiry never extends.").font(LBFont.meta)
                    }
                }
                if ["claim_unknown", "completion_unknown"].contains(store.pairingState) {
                    Text("Automatic checks stopped because the outcome is unknown. Reopening does not retry it. Check my request explicitly reconciles the original saved receipt, without creating a second request.")
                        .font(LBFont.meta)
                }
                if ["claim_unknown", "pending_approval", "completion_unknown", "completing"].contains(store.pairingState) {
                    Button("Check my request") {
                        perform(store.pairingState == "claim_unknown" ? .request : .check)
                    }.disabled(busy || store.pairingState == "completing")
                }
                if let lastChecked {
                    Text("Last checked \(lastChecked.formatted(date: .omitted, time: .standard))").font(LBFont.meta)
                }
                if store.pendingPairing != nil {
                    Button("Discard local pairing request", role: .destructive) {
                        do { try store.cancelPairing(); link = ""; error = nil; lastChecked = nil }
                        catch { self.error = humanErrorText(error) }
                    }.disabled(busy || ["claiming", "completing", "previewing"].contains(store.pairingState))
                }
                ActionErrorView(message: error ?? store.pairingError)
                if busy { ProgressView("Checking connection…") }
            }
        }.navigationTitle("Connect to desktop")
            .sheet(isPresented: $scanning) {
                PairingQRScanner { result in
                    scanning = false
                    switch result {
                    case .success(let raw): prepare(raw)
                    case .failure(let failure): error = humanErrorText(failure)
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { scanning = false }
                if phase != .active { action = nil }
            }
            .onDisappear { scanning = false; link = ""; action = nil }
            .task(id: action) {
                if let action { await run(action) }
            }
            .task(id: ObservationID(requestID: store.pendingPairing?.pairingID, foreground: scenePhase == .active, reconciliation: observationRevision)) {
                await observeRequest()
            }
    }
    private var busy: Bool { working || action != nil }
    private var hasSavedConnection: Bool {
        store.pendingPairing == nil && store.account != nil && ["connected", "failed"].contains(store.pairingState)
    }
    private var verifiedConnection: Bool {
        store.pairingState == "connected" && store.isOnline && store.account?.instanceID != nil &&
            store.workspace?.id == store.account?.workspaceID
    }
    private var savedConnectionLabel: String {
        if verifiedConnection { return "Connected to verified workspace" }
        if store.connectionState == "reconnect_required" { return "Reconnect required — not connected" }
        return "Credential saved — workspace not online"
    }
    private func statusLabel(at now: Date) -> String {
        if hasSavedConnection { return savedConnectionLabel }
        if store.pairingState == "pending_approval", let expiry = store.pendingPairing?.expiresAtMs,
           expiry <= now.timeIntervalSince1970 * 1000 { return pairingStatusLabel("expired") }
        return pairingStatusLabel(store.pairingState)
    }
    private func previewReady(at now: Date) -> Bool {
        guard let preview = store.pendingPairing, !preview.clusterName.isEmpty,
              let expiry = preview.expiresAtMs else { return false }
        return expiry.isFinite && expiry > now.timeIntervalSince1970 * 1000
    }
    private func prepare(_ raw: String) {
        guard !busy, scenePhase == .active else { return }
        do {
            try store.preparePairing(raw)
            link = ""; error = nil; lastChecked = nil
            perform(.preview)
        } catch { self.error = humanErrorText(error) }
    }
    private func perform(_ requestedAction: PairingAction) {
        guard !busy, scenePhase == .active else { return }
        error = nil
        action = requestedAction
    }
    private func run(_ requestedAction: PairingAction) async {
        guard !working, !Task.isCancelled, scenePhase == .active else {
            action = nil
            return
        }
        working = true
        defer { working = false; action = nil }
        do {
            switch requestedAction {
            case .preview:
                try await store.previewPairing()
            case .request:
                try await store.requestPairing(deviceName: UIDevice.current.name, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1")
            case .check:
                try await store.completePairing()
                lastChecked = Date()
            }
            if !Task.isCancelled,
               PhonePairingProgress.shouldObserve(state: store.pairingState, expiresAtMs: store.pendingPairing?.expiresAtMs) {
                // A successful explicit reconciliation may resume confirmed pending observation.
                observationRevision += 1
            }
        } catch {
            if !Task.isCancelled { self.error = store.pairingError ?? humanErrorText(error) }
        }
    }
    private func observeRequest() async {
        guard scenePhase == .active, let requestID = store.pendingPairing?.pairingID,
              let originalExpiry = store.pendingPairing?.expiresAtMs, originalExpiry.isFinite else { return }
        // The task identity deliberately excludes pairingState: completing is transient.
        while !Task.isCancelled, scenePhase == .active, store.pendingPairing?.pairingID == requestID {
            if busy {
                guard originalExpiry > Date().timeIntervalSince1970 * 1000 else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                continue
            }
            let shouldObserve = PhonePairingProgress.shouldObserve(state: store.pairingState, expiresAtMs: originalExpiry)
            let expiredPending = store.pairingState == "pending_approval" && originalExpiry <= Date().timeIntervalSince1970 * 1000
            guard shouldObserve || expiredPending else { return }
            working = true
            do {
                // At the deadline this reports local expiry without sending another request.
                try await store.observePhonePairing()
                if !Task.isCancelled { lastChecked = Date(); error = nil }
            } catch {
                working = false
                if !Task.isCancelled { self.error = store.pairingError ?? humanErrorText(error) }
                return
            }
            working = false
            guard !Task.isCancelled,
                  PhonePairingProgress.shouldObserve(state: store.pairingState, expiresAtMs: originalExpiry) else { return }
            let remaining = max(0, originalExpiry / 1000 - Date().timeIntervalSince1970)
            do { try await Task.sleep(for: .seconds(min(2, remaining))) } catch { return }
        }
    }
}
#endif
