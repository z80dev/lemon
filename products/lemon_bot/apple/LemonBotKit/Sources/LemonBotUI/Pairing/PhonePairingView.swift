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
    @State private var busy = false
    @State private var error: String?
    public init(store: LemonBotStore) { self.store = store }

    public var body: some View {
        Form {
            Section("Connect to your desktop") {
                Text("On your Mac choose Connect iPhone. Scan its one-use QR, check the backend origin, then explicitly request connection. No desktop password is needed.")
                if store.pendingPairing == nil && store.pairingState != "connected" {
                    Button("Scan QR code") { scanning = true }.disabled(busy)
                    TextField("Paste lemonbot://pair link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                    Button("Check pasted link") { prepare(link) }.disabled(link.isEmpty || busy)
                }
            }
            if let preview = store.pendingPairing {
                Section("Verify this connection") {
                    Text(preview.clusterName).font(.headline)
                    Text(preview.origin).textSelection(.enabled)
                    DisclosureGroup("Details") { Text("Workspace ID: \(preview.workspaceID)"); Button("Copy") { copyText(preview.workspaceID) } }
                    if let deviceName = preview.deviceName { Text("This device: \(deviceName)").textSelection(.enabled) }
                    if let expiry = preview.expiresAtMs {
                        Text("Expires \(Date(timeIntervalSince1970: expiry / 1000).formatted(date: .abbreviated, time: .standard))")
                    }
                    if let code = preview.verificationCode {
                        Text(code).font(.largeTitle.monospaced()).textSelection(.enabled)
                        Text("Compare this exact code and your device name with the Mac before approving there.")
                    }
                }
            } else if let preview = store.pairingLink {
                Section("Check before requesting") {
                    Text(preview.origin).textSelection(.enabled)
                    DisclosureGroup("Details") { Text("Workspace ID: \(preview.workspaceID)"); Button("Copy") { copyText(preview.workspaceID) } }
                    Text("Check the server address before contacting it. This checks the desktop's name and expiry without using up the code.")
                }
            }
            Section("Connection status") {
                Text(pairingStatusLabel(store.pairingState))
                if store.pairingState == "preview" || store.pairingState == "preview_ready" {
                    Button("Check workspace") { perform { try await store.previewPairing() } }.disabled(busy)
                    Button("Request connection") { request() }
                        .disabled(busy || store.pairingState != "preview_ready" || !previewReady)
                }
                if ["claim_unknown", "pending_approval", "completion_unknown", "completing"].contains(store.pairingState) {
                    Text("Your request is saved on this phone. Reopening won't use another code or send it twice.").font(LBFont.meta)
                    Button("Check my request") {
                        if store.pairingState == "claim_unknown" { request() }
                        else { perform { try await store.completePairing() } }
                    }.disabled(busy)
                }
                if store.pairingState == "connected" { Button("Open Lemon Bot") { dismiss() } }
                if store.pairingState != "connected" {
                    Button("Discard local pairing request", role: .destructive) {
                        do { try store.cancelPairing(); link = ""; error = nil } catch { self.error = error.localizedDescription }
                    }.disabled(busy)
                }
                ActionErrorView(message: error ?? store.pairingError)
                if busy { ProgressView("Connecting…") }
            }
        }.navigationTitle("Connect to desktop")
            .sheet(isPresented: $scanning) {
                PairingQRScanner { result in
                    scanning = false
                    switch result { case .success(let raw): prepare(raw); case .failure(let failure): error = failure.localizedDescription }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase == .background { scanning = false } }
            .onDisappear { scanning = false; link = "" }
            .task(id: store.pairingState) {
                if store.pairingState == "preview", !previewReady {
                    perform { try await store.previewPairing() }
                }
            }
    }
    private func prepare(_ raw: String) {
        do {
            try store.preparePairing(raw); link = ""; error = nil
            perform { try await store.previewPairing() }
        }
        catch { self.error = humanErrorText(error) }
    }
    private var previewReady: Bool {
        guard let preview = store.pendingPairing,
              !preview.clusterName.isEmpty,
              let expiry = preview.expiresAtMs else { return false }
        return expiry > Date().timeIntervalSince1970 * 1000
    }
    private func request() {
        perform { try await store.requestPairing(deviceName: UIDevice.current.name, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { defer { busy = false }; do { try await operation() } catch { self.error = humanErrorText(error) } }
    }
}
#endif
