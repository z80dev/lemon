#if os(macOS)
import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import LemonBotKit

public struct OwnerPairingView: View {
    private let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    public init(store: LemonBotStore) { self.store = store }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Connect your iPhone") {
                    Text("Use a reachable HTTPS desktop backend, such as Tailscale Serve. On iPhone choose Scan, check the exact origin, then request connection. Compare both verification codes before approving.")
                    Button("Create one-use QR code") { perform { try await store.createPairing() } }
                        .disabled(busy || store.pendingIntents.contains { $0.path == "/pairings" })
                    if store.pendingIntents.contains(where: { $0.path == "/pairings" }) {
                        Button("Reconcile original QR request") {
                            perform { try await store.reconcilePairingIssuance() }
                        }.disabled(busy)
                        Text("Recover the original one-use link with its fixed request nonce. This does not create another QR or extend its five-minute expiry. If expired, create a new QR explicitly.").font(.caption)
                    }
                    if let link = store.pairingURL, let image = qrImage(link) {
                        Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 256, height: 256)
                            .accessibilityLabel("One-use pairing QR code. Scan with Lemon Bot on your iPhone.")
                            .padding(24).background(.white)
                            .privacySensitive()
                    }
                    if let link = store.pairingURL {
                        Button("Copy one-use pairing link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        }
                        Text("Copy only for your phone's secure paste field. The clipboard contains a temporary secret.").font(.caption)
                    }
                    Text("The QR is a temporary secret. Do not share screenshots. It is not your desktop session or password.").font(.caption)
                    Button("Refresh requests · read only") { perform { try await store.refreshPairings() } }.disabled(busy)
                }
                ForEach(store.pairings) { pairing in
                    Section(pairing.clusterName) {
                        Text(pairing.backendUrl).textSelection(.enabled)
                        Text("Expires \(Date(timeIntervalSince1970: pairing.expiresAtMs / 1000).formatted(date: .abbreviated, time: .standard))")
                        Text("Status: \(pairing.status)")
                        if let device = pairing.deviceName { Text("Device: \(device)").textSelection(.enabled) }
                        if let code = pairing.verificationCode {
                            Text(code).font(.title.monospaced()).textSelection(.enabled)
                            Text("Only approve if this exact code and device name match your phone.").font(.caption)
                        }
                        if pairing.status == "pending_approval" {
                            Button("Approve this device once") { perform { try await store.approvePairing(pairing) } }
                                .disabled(busy || fenced(pairing.id) || pairing.expiresAtMs <= Date().timeIntervalSince1970 * 1000)
                            Button("Deny", role: .destructive) { perform { try await store.denyPairing(pairing) } }
                                .disabled(busy || fenced(pairing.id))
                        }
                        if fenced(pairing.id) { Text("Outcome unconfirmed. Refresh reads the authoritative state; it never repeats approval or denial.").font(.caption) }
                    }
                }
                Section("Paired device access") {
                    Text("Manage or revoke this phone in Settings → Account → Devices / sessions. Revoking its device or session removes its access; pairing again requires explicit desktop approval.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                if busy { ProgressView() }
            }.formStyle(.grouped).navigationTitle("Connect iPhone")
                .toolbar { Button("Done") { dismiss() } }
                .task { perform { try await store.refreshPairings() } }
        }.frame(minWidth: 480, minHeight: 580)
    }
    private func fenced(_ id: ID) -> Bool {
        store.pendingIntents.contains { $0.path == "/pairings/\(id)/approve" || $0.path == "/pairings/\(id)/deny" }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task { defer { busy = false }; do { try await operation() } catch { self.error = error.localizedDescription } }
    }
    private func qrImage(_ link: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
#endif
