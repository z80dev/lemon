#if os(macOS)
import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import LemonBotKit

public struct OwnerPairingView: View {
    private let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var observing = false
    @State private var error: String?
    @State private var lastChecked: Date?
    @State private var renderedQR: NSImage?
    @State private var comparedRequests: Set<String> = []
    private static let qrContext = CIContext()
    public init(store: LemonBotStore) { self.store = store }

    public var body: some View {
        NavigationStack {
            Form {
                prerequisites
                Section("2. Verify this workspace's phone address") {
                    if let account = store.account {
                        Text("Mac backend: \(account.baseURL.absoluteString)").textSelection(.enabled)
                        Text("Workspace: \(store.workspace?.name ?? account.workspaceID)").textSelection(.enabled)
                    }
                    Text("Read the advertised HTTPS address from your already configured backend, then verify that it serves the same Lemon Bot instance and workspace. No backend or account is replaced.")
                    Button("Check connection readiness") {
                        perform { try await store.verifyOwnerPairingOrigin(); try await store.refreshPairings(); lastChecked = Date() }
                    }.disabled(busy || observing)
                    if let ready = store.ownerPairingPreflight {
                        Label("Verified from this Mac", systemImage: "checkmark.shield")
                        Text(ready.origin).font(.headline.monospaced()).textSelection(.enabled)
                        Text("Backend: \(ready.setup.instanceId)").font(LBFont.meta).textSelection(.enabled)
                        Text("Workspace: \(ready.identity?.workspaceId ?? "Unavailable")").font(LBFont.meta).textSelection(.enabled)
                        Text("This exact address will be advertised in the QR. Your iPhone still needs its own Tailscale reachability.").font(.caption)
                    }
                }
                Section("3. Scan and request connection") {
                    Text("On your iPhone choose Scan QR code or paste the one-use link. Review the workspace, address and expiry, then choose Request connection.")
                    Button("Create QR code") { perform { try await store.createPairing() } }
                        .disabled(busy || observing || store.ownerPairingPreflight == nil || store.pendingIntents.contains { $0.path == "/pairings" })
                    if store.pendingIntents.contains(where: { $0.path == "/pairings" }) {
                        Button("Check previous QR code") { perform { try await store.reconcilePairingIssuance() } }
                            .disabled(busy || observing || store.ownerPairingPreflight == nil)
                        Text("Check the QR you already created first. This doesn't make a new one or extend its five-minute expiry.").font(LBFont.meta)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let link = activeLink(at: context.date), let image = renderedQR {
                            Image(nsImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 256, height: 256)
                                .accessibilityLabel("One-use pairing QR code. Scan with Lemon Bot on your iPhone.")
                                .padding(24).background(.white).privacySensitive()
                            Button("Copy one-use pairing link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(link, forType: .string)
                            }
                            Text("Copy only for your phone's secure paste field. The clipboard contains a temporary secret.").font(.caption)
                        }
                    }
                    Text("The QR is a temporary secret. Do not share screenshots. It is not your desktop session or password.").font(.caption)
                }
                Section("4. Compare, then approve") {
                    Text("Requests update while this window is active. Approval requires your explicit comparison; it is never automatic.")
                    Button("Refresh requests") {
                        perform { try await store.refreshOwnerPairingStatus(); lastChecked = Date() }
                    }.disabled(busy || observing || store.ownerPairingPreflight == nil)
                    if let lastChecked { Text("Last checked \(lastChecked.formatted(date: .omitted, time: .standard))").font(.caption) }
                }
                ForEach(store.pairings) { pairing in requestSection(pairing) }
                Section("Paired device access") {
                    Text("Connected means the phone completed its own session, not just that you approved. Both clients use the same server-backed workspace; closing this Mac window does not disconnect the phone.")
                    Text("Manage or revoke this phone in Settings → Account → Devices / sessions. Revoking its device or session removes its access; pairing again requires explicit desktop approval.")
                }
                ActionErrorView(message: error)
                if busy || observing { ProgressView() }
            }.formStyle(.grouped).navigationTitle("Connect iPhone")
                .toolbar { Button("Done") { dismiss() } }
                .task(id: "\(store.account?.id ?? "")|\(scenePhase == .active)") { await observeRequests() }
                .onAppear { renderedQR = store.pairingURL.flatMap(makeQRImage) }
                .onChange(of: store.pairingURL) { _, link in renderedQR = link.flatMap(makeQRImage) }
        }.frame(minWidth: 540, minHeight: 680)
    }
    private var prerequisites: some View {
        Section("1. Prepare both devices") {
            Text("Connect to the same already running Lemon Bot backend, not Lemon Web or the operator WebSocket. This app does not install or start services.")
            Link("Install Tailscale on Mac and iPhone", destination: URL(string: "https://tailscale.com/download")!)
            Text("Sign in on both devices to the same tailnet. Turn Tailscale on on iPhone. Ask your tailnet administrator to allow the phone to reach the Mac's HTTPS listener in ACLs.")
            Text("Enable MagicDNS and HTTPS certificates in Tailscale. DNS must resolve the Mac's .ts.net name, and TLS must validate normally. Never bypass certificate warnings.")
            Text("The backend's LEMON_BOT_PUBLIC_URL must advertise its exact HTTPS Tailscale origin, including the port. The Serve route must point to that running Bot backend, not another service. Localhost on an iPhone is the phone itself.")
            DisclosureGroup("Backend or HTTPS route not ready?") {
                Text("Use your existing operator workflow to start the selected Bot backend on its host. Starting Lemon alone is not starting the separate Bot backend. Keep your configured remote backend; do not create an empty local replacement.")
                Text("This app never changes Tailscale Serve. If you explicitly choose to configure it outside the app, inspect all existing Serve routes first and select an unused HTTPS listener/port. Preserve existing ports and routes; never reset Serve, overwrite a route, enable Funnel or expose the operator WebSocket. Recheck readiness afterward.")
                Link("Tailscale Serve setup documentation", destination: URL(string: "https://tailscale.com/kb/1312/serve")!)
            }
        }
    }
    private func requestSection(_ pairing: Pairing) -> some View {
        Section(pairing.clusterName) {
            Text(pairing.backendUrl).textSelection(.enabled)
            Text("Expires \(Date(timeIntervalSince1970: pairing.expiresAtMs / 1000).formatted(date: .abbreviated, time: .standard))")
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = pairing.expiresAtMs <= context.date.timeIntervalSince1970 * 1000
                Text(pairing.status == "consumed" ? "Connected — iPhone completed pairing" : (expired && ["waiting", "pending_approval", "approved"].contains(pairing.status) ? pairingStatusLabel("expired") : (pairing.status == "waiting" ? "Waiting for your iPhone to request connection" : pairingStatusLabel(pairing.status))))
                if pairing.status == "pending_approval" {
                    if let device = pairing.deviceName { Text("Device: \(device)").textSelection(.enabled) }
                    if let code = pairing.verificationCode { Text(code).font(.title.monospaced()).textSelection(.enabled) }
                    Toggle("The exact device name and code match my iPhone", isOn: Binding(
                        get: { comparedRequests.contains(comparisonKey(pairing)) },
                        set: { if $0 { comparedRequests.insert(comparisonKey(pairing)) } else { comparedRequests.remove(comparisonKey(pairing)) } }
                    ))
                    Button("Approve this iPhone") { perform { try await store.approvePairing(pairing) } }
                        .disabled(busy || observing || fenced(pairing.id) || expired || store.ownerPairingPreflight == nil || !comparedRequests.contains(comparisonKey(pairing)))
                    Button("Deny", role: .destructive) { perform { try await store.denyPairing(pairing) } }
                        .disabled(busy || observing || fenced(pairing.id))
                }
            }
            if fenced(pairing.id) { Text("We couldn't confirm whether this went through. Live status checks the saved receipt without approving again. Refresh if a check failed.").font(LBFont.meta) }
        }
    }
    private func comparisonKey(_ pairing: Pairing) -> String { "\(pairing.id)|\(pairing.revision)|\(pairing.deviceName ?? "")|\(pairing.verificationCode ?? "")" }
    private func activeLink(at now: Date) -> String? {
        guard store.ownerPairingPreflight != nil, let link = store.pairingURL,
              let parsed = try? PairingLink.parse(link),
              let pairing = store.issuedPairing, pairing.status == "waiting",
              pairing.expiresAtMs > now.timeIntervalSince1970 * 1000, pairing.backendUrl == parsed.origin else { return nil }
        return link
    }
    private func observeRequests() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !busy, !observing, store.ownerPairingPreflight != nil,
                  OwnerPairingProgress.shouldObserve(store.pairings) else { continue }
            observing = true
            do { try await store.refreshOwnerPairingStatus(); lastChecked = Date(); error = nil }
            catch { if !Task.isCancelled { self.error = humanErrorText(error) } }
            observing = false
        }
    }
    private func fenced(_ id: ID) -> Bool {
        store.pendingIntents.contains { $0.path == "/pairings/\(id)/approve" || $0.path == "/pairings/\(id)/deny" }
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy, !observing else { return }
        busy = true; error = nil
        Task { defer { busy = false }; do { try await operation() } catch { self.error = humanErrorText(error) } }
    }
    private func makeQRImage(_ link: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = Self.qrContext.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
#endif
