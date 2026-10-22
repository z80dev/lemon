import SwiftUI
import LemonBotKit
import CryptoKit
import Security

private struct PublicOIDCProvider: Decodable, Identifiable {
    let id: ID
    let name: String
    let enabled: Bool
    let requireSSO: Bool
}

private enum OnboardingStep: Hashable { case account }

/// First run and "connect somewhere else". On a Mac the machine you own is the credential:
/// this Mac or any SSH host connects in one click. Email/password accounts stay one step away.
public struct OnboardingView: View {
    private let store: LemonBotStore
    private let initialURL: URL?
    @State private var path: [OnboardingStep]

    public init(store: LemonBotStore, initialURL: URL? = nil) {
        self.store = store
        self.initialURL = initialURL
        // Re-signing a password account goes straight to its form.
        _path = State(initialValue: initialURL == nil ? [] : [.account])
    }

    public var body: some View {
        #if os(macOS)
        NavigationStack(path: $path) {
            MachineConnectView(store: store) { path.append(.account) }
                .navigationDestination(for: OnboardingStep.self) { _ in AccountSignInView(store: store, initialURL: initialURL) }
        }
        .frame(minWidth: 560, minHeight: 640)
        #else
        NavigationStack { AccountSignInView(store: store, initialURL: initialURL) }
        #endif
    }
}

#if os(macOS)
private enum ConnectTarget: Equatable { case thisMac, remote }

private struct MachineConnectView: View {
    let store: LemonBotStore
    let signInWithAccount: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var local: LocalState = .checking
    @State private var host = ""
    @State private var busy: ConnectTarget?
    @State private var step: LemonBotStore.ConnectStep?
    @State private var failure: (target: ConnectTarget, error: Error)?
    @State private var reopening: ID?

    private enum LocalState: Equatable { case checking, running, stopped, missing }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    LemonMark(size: 64)
                    Text("Connect to Lemon Bot").font(.system(size: 26, weight: .semibold)).foregroundStyle(LB.ink)
                    Text("Your assistant runs on a machine you own. Pick which one.")
                        .font(LBFont.body).foregroundStyle(LB.muted).multilineTextAlignment(.center)
                }
                VStack(spacing: 12) {
                    thisMacCard
                    remoteCard
                }
                if !recent.isEmpty { recentList }
                Button("Sign in with an email and password instead") { signInWithAccount() }
                    .buttonStyle(.plain).font(LBFont.rowSubtitle).foregroundStyle(LB.muted)
            }
            .frame(maxWidth: 500)
            .padding(.horizontal, 40).padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
        .background(LB.canvas)
        .navigationTitle("")
        .toolbar { if store.account != nil { Button("Close") { dismiss() } } }
        .task { await checkThisMac() }
    }

    // MARK: Cards

    private var thisMacCard: some View {
        ConnectCard(symbol: "laptopcomputer", title: "This Mac") {
            if busy == .thisMac { progress }
            else if failure?.target == .thisMac, let error = failure?.error { FailureView(error: error, machine: "this Mac") }
            else {
                switch local {
                case .checking: status(nil, "Looking for Lemon Bot…")
                case .running: status(LB.success, "Lemon Bot is running")
                case .stopped: status(LB.warning, "Not running yet — connecting starts it")
                case .missing: InstallHint(machine: "this Mac")
                }
            }
        } action: {
            Button(busy == .thisMac ? "Connecting…" : "Connect") { connect(.thisMac) }
                .buttonStyle(.lemonPrimary).disabled(busy != nil)
        }
    }

    private var remoteCard: some View {
        ConnectCard(symbol: "server.rack", title: "Another machine") {
            Text("Anything you can reach with SSH. Lemon Bot starts there if it isn’t running.")
                .font(LBFont.rowSubtitle).foregroundStyle(LB.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("me@studio or an SSH alias", text: $host)
                    .textFieldStyle(.plain).font(LBFont.body).autocorrectionDisabled()
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LB.fill))
                    .onSubmit { connectRemote() }
                    .disabled(busy != nil)
                Button(busy == .remote ? "Connecting…" : "Connect") { connectRemote() }
                    .buttonStyle(.pill(.secondary))
                    .disabled(busy != nil || MachineRoute.sshHost(host) == nil)
            }
            if busy == .remote { progress }
            else if failure?.target == .remote, let error = failure?.error { FailureView(error: error, machine: MachineRoute.sshHost(host) ?? "that machine") }
        } action: { EmptyView() }
    }

    private var recent: [StoredAccount] { store.accounts.filter { $0.id != store.account?.id } }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Recent")
            VStack(spacing: 0) {
                ForEach(recent) { account in
                    Button { reopen(account) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(account.route)).font(.system(size: 15)).foregroundStyle(LB.muted).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName).font(LBFont.rowTitle).foregroundStyle(LB.ink)
                                Text(account.route == nil ? "\(account.email) · \(account.location)" : account.location).font(LBFont.meta).foregroundStyle(LB.muted)
                            }
                            Spacer(minLength: 8)
                            if reopening == account.id { ProgressView().controlSize(.small) }
                            else { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(LB.faint) }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(busy != nil || reopening != nil)
                    if account.id != recent.last?.id { Divider().padding(.leading, 48) }
                }
            }
            .background(RoundedRectangle(cornerRadius: LBMetric.cardRadius, style: .continuous).fill(LB.raised))
            .overlay(RoundedRectangle(cornerRadius: LBMetric.cardRadius, style: .continuous).strokeBorder(LB.separator))
        }
    }

    // MARK: Pieces

    private var progress: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(stepText).font(LBFont.rowSubtitle).foregroundStyle(LB.muted)
        }
    }

    private var stepText: String {
        switch (busy, step) {
        case (.remote, .preparing?): return "Connecting over SSH and starting Lemon Bot if needed…"
        case (_, .preparing?): return "Starting Lemon Bot if needed…"
        case (_, .tunneling?): return "Opening a secure tunnel…"
        case (_, .signingIn?): return "Signing in…"
        default: return "Connecting…"
        }
    }

    private func status(_ color: Color?, _ text: String) -> some View {
        HStack(spacing: 7) {
            if let color { Circle().fill(color).frame(width: 7, height: 7) } else { ProgressView().controlSize(.mini) }
            Text(text).font(LBFont.rowSubtitle).foregroundStyle(LB.muted)
        }
    }

    private func icon(_ route: MachineRoute?) -> String {
        switch route {
        case .thisMac?: return "laptopcomputer"
        case .ssh?: return "server.rack"
        case nil: return "person.crop.circle"
        }
    }

    // MARK: Actions

    private func connectRemote() {
        guard let value = MachineRoute.sshHost(host) else { failure = (.remote, MachineConnectionError.invalidHost); return }
        connect(.ssh(host: value, remotePort: 4100))
    }

    private func connect(_ route: MachineRoute) {
        let target: ConnectTarget = route == .thisMac ? .thisMac : .remote
        guard busy == nil else { return }
        busy = target; step = nil; failure = nil
        Task {
            defer { busy = nil; step = nil }
            do {
                try await store.connect(to: route) { step = $0 }
                dismiss()
            } catch is CancellationError {
            } catch {
                failure = (target, error)
                if target == .thisMac { await checkThisMac() }
            }
        }
    }

    private func reopen(_ account: StoredAccount) {
        reopening = account.id
        Task {
            defer { reopening = nil }
            do { try await store.restoreAccount(account) }
            catch {
                // An expired session on a machine-key account just signs in again.
                if let route = account.route, store.connectionState == "reconnect_required" { try? await store.connect(to: route) }
            }
            if store.account?.id != nil { dismiss() }
        }
    }

    private func checkThisMac() async {
        local = .checking
        if let client = try? HTTPTransport(baseURL: URL(string: "http://127.0.0.1:4100")!) {
            defer { client.session.invalidateAndCancel() }
            if (try? await client.read("/setup", timeout: 2, as: SetupStatus.self)) != nil { local = .running; return }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let checkout = UserDefaults.standard.string(forKey: MachineBootstrap.checkoutDefaultsKey) ?? home + "/lemon"
        let launchers = ["/.lemon/lemon_bot/current/bot/bin/lemon-bot", "/.local/bin/lemon-bot", "/.lemon/bin/lemon-bot"].map { home + $0 } + ["/opt/homebrew/bin/lemon-bot", "/usr/local/bin/lemon-bot"]
        let installed = launchers.contains { FileManager.default.isExecutableFile(atPath: $0) }
            || FileManager.default.fileExists(atPath: checkout + "/products/lemon_bot/backend/src/cli.ts")
        local = installed ? .stopped : .missing
    }
}

/// A raised card with a lemon-tinted icon, a title, free-form content and a trailing action.
private struct ConnectCard<Content: View, Action: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var action: Action
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium)).foregroundStyle(LB.lemonInk)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(LB.lemon.opacity(0.55)))
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(LB.ink)
                    Spacer(minLength: 8)
                    action
                }
                content
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LBMetric.cardRadius, style: .continuous).fill(LB.raised))
        .overlay(RoundedRectangle(cornerRadius: LBMetric.cardRadius, style: .continuous).strokeBorder(LB.separator))
        .shadow(color: LB.shadow.opacity(0.5), radius: 8, y: 2)
    }
}

private struct FailureView: View {
    let error: Error
    let machine: String
    private var parts: (message: String, detail: String?) {
        let split = humanErrorText(error).components(separatedBy: "\nDetails: ")
        return (split[0], (error as? MachineConnectionError)?.detail ?? (split.count > 1 ? split.dropFirst().joined(separator: "\n") : nil))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(parts.message, systemImage: "exclamationmark.triangle.fill")
                .font(LBFont.rowSubtitle).foregroundStyle(LB.danger).fixedSize(horizontal: false, vertical: true)
            if case MachineConnectionError.notInstalled? = error as? MachineConnectionError { InstallHint(machine: machine) }
            if let detail = parts.detail {
                DisclosureGroup("Details") {
                    Text(detail).font(LBFont.code).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }.font(LBFont.meta).foregroundStyle(LB.muted)
            }
        }
    }
}

private struct InstallHint: View {
    let machine: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Install Lemon Bot on \(machine), then connect:").font(LBFont.rowSubtitle).foregroundStyle(LB.muted)
            HStack(spacing: 8) {
                Text(MachineBootstrap.installCommand).font(LBFont.code).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 4)
                Button("Copy") { copyText(MachineBootstrap.installCommand) }.buttonStyle(.pill(.secondary, compact: true))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LB.codeInset))
        }
    }
}
#endif

/// Email/password, owner setup code and configured SSO; iPhone pairing on iOS.
private struct AccountSignInView: View {
    private let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var backend: String
    @State private var connectionIssue: ConnectionIssue?
    @State private var mode = "login"
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var workspaceName = ""
    @State private var setupCode = ""
    @State private var providers: [PublicOIDCProvider] = []
    @State private var checkedURL: URL?
    @State private var setupRequired = false
    @State private var action = UIActionState()
    @State private var browser = AdminWebAuthentication()
    @AppStorage("LemonBot.safeAccountCleanupDiagnostics") private var cleanupDiagnostics = ""
    #if os(iOS)
    @State private var showPairing = false
    #endif
    init(store: LemonBotStore, initialURL: URL?) {
        self.store = store
        #if os(iOS) && !targetEnvironment(simulator)
        _backend = State(initialValue: initialURL.map(ConnectionIssue.origin(for:)) ?? "")
        #else
        _backend = State(initialValue: initialURL.map(ConnectionIssue.origin(for:)) ?? "http://127.0.0.1:4100")
        #endif
    }
    var body: some View {
        Form {
            #if os(iOS)
            SwiftUI.Section("Connect to your desktop") {
                Text("Connect to your Mac's workspace. Scan its QR code or paste the link, then compare verification codes before approving on your Mac.")
                Button(store.pendingPairing == nil ? "Scan QR code or paste link" : "Check my request") { showPairing = true }
            }
            SwiftUI.Section("Your persistent assistant") {
                Text("Give each Bot a name, a focused job and a machine you own.").font(.headline)
                Text("Work continues when you close the app, but requires the assigned machine to stay online. Bots on the same OS user share files, browser logins and CLI credentials; personas are not security sandboxes.")
            }
            if !store.accounts.isEmpty {
                SwiftUI.Section("Saved accounts · credentials in Keychain") {
                    ForEach(store.accounts) { account in
                        Button {
                            Task { await action.perform { try await store.restoreAccount(account); dismiss() } }
                        } label: {
                            VStack(alignment: .leading) {
                                Text(account.displayName)
                                Text("\(account.email) · \(account.location)").font(.caption)
                            }
                        }.disabled(action.busy)
                    }
                }
            }
            #endif
            SwiftUI.Section("Lemon Bot server") {
                TextField("https://your-desktop.your-tailnet.ts.net", text: $backend).autocorrectionDisabled()
                Button("Check setup and sign-in methods") { Task { await discover() } }.disabled(action.inFlight)
                if checkedURL != nil {
                    Text(setupRequired ? "Owner setup required. Obtain the one-use setup code from the backend operator terminal." : "Use your local account or configured identity provider.").font(.caption)
                }
                if let issue = connectionIssue {
                    Text(issue.title).font(LBFont.rowTitle).foregroundStyle(LB.warning)
                    Text(issue.reason).font(LBFont.body)
                    DisclosureGroup("Details") {
                        Text(issue.detail).font(LBFont.code).textSelection(.enabled)
                        Button("Copy details") { copyText(issue.detail) }
                    }
                }
            }
            if checkedURL != nil {
                SwiftUI.Section("Account") {
                    Picker("Sign in method", selection: $mode) {
                        Text("Sign in").tag("login")
                        if setupRequired { Text("Create workspace").tag("setup") }
                    }
                    TextField("Email", text: $email).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    if mode == "setup" { Text("Use at least 12 letters, numbers or symbols.").font(LBFont.meta) }
                    if mode != "login" { TextField("Display name", text: $displayName) }
                    if mode == "setup" {
                        SecureField("One-use setup code", text: $setupCode)
                        TextField("Workspace name", text: $workspaceName)
                    }
                    Button(mode == "setup" ? "Create workspace" : "Sign in") {
                        Task { await localLogin() }
                    }.disabled(action.busy || email.isEmpty || password.isEmpty)
                }
                if !providers.isEmpty {
                    SwiftUI.Section("Configured single sign-on") {
                        ForEach(providers) { provider in
                            Button("Continue with \(provider.name)\(provider.requireSSO ? " · required" : "")") {
                                Task { await oidcLogin(provider) }
                            }.disabled(action.busy || !provider.enabled)
                        }
                        Text("Your browser confirms your identity. Your sign-in password isn't shared with this app.").font(LBFont.meta)
                    }
                }
            }
            if !cleanupDiagnostics.isEmpty {
                SwiftUI.Section("Previous account cleanup · safe handoff metadata") {
                    Text(cleanupDiagnostics).font(.caption).textSelection(.enabled)
                    Text("Give these opaque identifiers to the workspace Owner for read-only cleanup observation. This is not a login, read capability or permission to retry deletion.").font(.caption)
                    Button("Copy safe diagnostics") { copyText(cleanupDiagnostics) }
                    Button("Clear local diagnostic copy") { cleanupDiagnostics = "" }
                }
            }
            if connectionIssue == nil { ActionErrorView(message: action.error) }
            if action.inFlight { ProgressView("Connecting…") }
        }.formStyle(.grouped)
            #if os(macOS)
            .navigationTitle("Sign in with an account")
            #else
            .navigationTitle("Welcome to Lemon Bot")
            .toolbar { if store.account != nil { Button("Close") { dismiss() } } }
            #endif
            .frame(maxWidth: 700)
            .onChange(of: backend) { _, _ in checkedURL = nil; providers = []; connectionIssue = nil }
            #if os(iOS)
            .sheet(isPresented: $showPairing) {
                NavigationStack {
                    PhonePairingView(store: store)
                        .toolbar { Button("Close") { showPairing = false } }
                }
            }
            .onAppear { showPairing = store.pendingPairing != nil }
            .onChange(of: store.pairingState) { _, state in
                if ["preview", "preview_ready", "pending_approval", "claim_unknown"].contains(state) { showPairing = true }
            }
            #endif
    }
    private func validatedURL() throws -> URL {
        guard let url = URL(string: backend) else { throw LoginError.message("Enter your Lemon Bot server address, for example https://bot.example.") }
        return try HTTPTransport.normalizeBaseURL(url)
    }
    private func publicRequest<T: Decodable>(_ base: URL, _ path: String, body: JSONObject? = nil) async throws -> T {
        let transport = try HTTPTransport(baseURL: base)
        if let body { return try await transport.mutate("POST", path, body: body) }
        return try await transport.read(path)
    }
    private func discover() async {
        await action.perform {
            let url = try validatedURL()
            do {
                let setup: SetupStatus = try await HTTPTransport(baseURL: url).read("/setup", timeout: 2)
                let methods: [PublicOIDCProvider] = try await publicRequest(url, "/auth/oidc/providers")
                try Task.checkCancellation()
                setupRequired = setup.setupRequired
                connectionIssue = nil
                if !setup.setupRequired { action.uncertain = false }
                mode = setup.setupRequired ? "setup" : "login"
                checkedURL = url
                providers = methods
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                connectionIssue = ConnectionIssue.classify(error, baseURL: url)
                throw error
            }
        }
    }
    private func localLogin() async {
        await action.perform {
            guard let url = checkedURL else { return }
            var body: JSONObject = ["email": .string(email), "password": .string(password), "clientNonce": .string(UUID().uuidString)]
            let path: String
            switch mode {
            case "setup":
                path = "/setup"
                body["setupCode"] = .string(setupCode); body["workspaceName"] = .string(workspaceName); body["displayName"] = .string(displayName)
            default: path = "/auth/login"
            }
            defer { password = ""; setupCode = "" }
            try await store.authenticate(baseURL: url, path: path, body: body)
            dismiss()
        }
    }
    private func oidcLogin(_ provider: PublicOIDCProvider) async {
        await action.perform {
            guard let url = checkedURL else { return }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw LoginError.message("Secure random generation failed.") }
            let verifier = Data(bytes).base64URLEncoded
            let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
            let flow: OIDCFlow = try await publicRequest(url, "/auth/oidc/start", body: ["providerId": .string(provider.id), "redirectUri": .string("lemonbot://auth/complete"), "codeChallenge": .string(challenge), "purpose": .string("login")])
            guard let authURL = safeExternalURL(flow.authorizationUrl), authURL.scheme == "https" else { throw LoginError.message("Identity provider returned an unsafe authorization URL.") }
            let callback = try await browser.authenticate(authURL)
            guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.scheme == "lemonbot", parts.host == "auth", parts.path == "/complete", callback.user == nil, callback.password == nil, callback.fragment == nil,
                  parts.queryItems?.map(\.name).sorted() == ["completionCode", "flowId"],
                  let code = parts.queryItems?.first(where: { $0.name == "completionCode" })?.value,
                  let flowID = parts.queryItems?.first(where: { $0.name == "flowId" })?.value, flowID == flow.id,
                  flow.expiresAtMs > Date().timeIntervalSince1970 * 1000 else { throw LoginError.message("The identity completion callback is invalid or expired.") }
            try await store.authenticate(baseURL: url, path: "/auth/oidc/complete", body: ["clientNonce": .string(UUID().uuidString), "flowId": .string(flow.id), "completionCode": .string(code), "codeVerifier": .string(verifier)])
            dismiss()
        }
    }
}
private enum LoginError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
private extension Data { var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") } }
