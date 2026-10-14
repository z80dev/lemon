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
                    Button("Scan desktop QR") { scanning = true }.disabled(busy)
                    SecureField("Paste lemonbot://pair link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                    Button("Preview pasted link · read only") { prepare(link) }.disabled(link.isEmpty || busy)
                }
            }
            if let preview = store.pendingPairing {
                Section("Verify this connection") {
                    Text(preview.clusterName).font(.headline)
                    Text(preview.origin).textSelection(.enabled)
                    Text("Cluster: \(preview.workspaceID)").font(.caption).textSelection(.enabled)
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
                    Text("Cluster: \(preview.workspaceID)").font(.caption).textSelection(.enabled)
                    Text("Check the exact origin before contacting it. The read-only preview confirms the cluster name and expiry without claiming or consuming the code.")
                }
            }
            Section("Connection status") {
                Text(store.pairingState.replacingOccurrences(of: "_", with: " "))
                if store.pairingState == "preview" {
                    Button("Check cluster · read only") { perform { try await store.previewPairing() } }.disabled(busy)
                    Button("Request connection to this desktop") { request() }
                        .disabled(busy || !previewReady)
                }
                if ["claim_unknown", "pending_approval", "completion_unknown", "completing"].contains(store.pairingState) {
                    Text("The pending request is saved on this phone. Reopening does not claim another code or automatically repeat a mutation.").font(.caption)
                    Button(store.pairingState == "claim_unknown" ? "Reconcile original request" : "Check approval / finish connection") {
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
                if let error = error ?? store.pairingError { Text(error).foregroundStyle(.red) }
                if busy { ProgressView("Connecting…") }
            }
        }.navigationTitle("Connect to desktop")
            .sheet(isPresented: $scanning) {
                PairingQRScanner { result in
                    scanning = false
                    switch result { case .success(let raw): prepare(raw); case .failure(let failure): error = failure.localizedDescription }
                }
            }
            .onChange(of: scenePhase) { _, phase in if phase != .active { scanning = false } }
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
        catch { error = "This is not a valid secure Lemon Bot pairing link."; link = "" }
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
        Task { defer { busy = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
}
#endif
