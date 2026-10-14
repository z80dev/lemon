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


public struct OnboardingView: View {
    private let store: LemonBotStore
    @Environment(\.dismiss) private var dismiss
    @State private var backend = "http://127.0.0.1:4080"
    @State private var mode = "login"
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var workspaceName = ""
    @State private var setupCode = ""
    @State private var inviteToken = ""
    @State private var providers: [PublicOIDCProvider] = []
    @State private var checkedURL: URL?
    @State private var setupRequired = false
    @State private var action = UIActionState()
    @State private var browser = AdminWebAuthentication()
    @AppStorage("LemonBot.safeAccountCleanupDiagnostics") private var cleanupDiagnostics = ""
    public init(store: LemonBotStore) { self.store = store }
    public var body: some View {
        NavigationStack {
            Form {
                SwiftUI.Section("Your persistent teammates") {
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
                                    Text("\(account.email) · \(account.baseURL.host ?? account.baseURL.absoluteString)").font(.caption)
                                }
                            }.disabled(action.busy)
                        }
                    }
                }
                SwiftUI.Section("Product backend") {
                    TextField("https://bot.example", text: $backend).autocorrectionDisabled()
                    Button("Check setup and sign-in methods · read only") { Task { await discover() } }.disabled(action.inFlight)
                    if checkedURL != nil {
                        Text(setupRequired ? "Owner setup required. Obtain the one-use setup code from the backend operator terminal." : "Use your local account, invitation, or configured identity provider.").font(.caption)
                    }
                }
                if checkedURL != nil {
                    SwiftUI.Section("Account") {
                        Picker("Sign in method", selection: $mode) {
                            Text("Sign in").tag("login")
                            Text("Accept invitation").tag("invite")
                            if setupRequired { Text("Create owner").tag("setup") }
                        }
                        TextField("Email", text: $email).autocorrectionDisabled()
                        SecureField("Password (at least 12 bytes for a new account)", text: $password)
                        if mode != "login" { TextField("Display name", text: $displayName) }
                        if mode == "invite" { SecureField("Invitation token", text: $inviteToken) }
                        if mode == "setup" {
                            SecureField("One-use setup code", text: $setupCode)
                            TextField("Workspace name", text: $workspaceName)
                        }
                        Button(mode == "setup" ? "Create workspace" : mode == "invite" ? "Accept invitation" : "Sign in") {
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
                            Text("The system browser verifies your identity. PKCE protects the one-use completion code; no password is shared with this app.").font(.caption)
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
                ActionErrorView(message: action.error)
                if action.inFlight { ProgressView("Connecting…") }
            }.formStyle(.grouped).navigationTitle("Welcome to Lemon Bot")
                .frame(maxWidth: 700)
                .toolbar { if store.account != nil { Button("Close") { dismiss() } } }
                .onChange(of: backend) { _, _ in checkedURL = nil; providers = [] }
        }
    }
    private func validatedURL() throws -> URL {
        guard let url = URL(string: backend) else { throw LoginError.message("Enter a product backend URL, not controller credentials.") }
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
            let setup: SetupStatus = try await publicRequest(url, "/setup")
            setupRequired = setup.setupRequired
            if !setup.setupRequired { action.uncertain = false }
            mode = setup.setupRequired ? "setup" : "login"
            checkedURL = url
            providers = try await publicRequest(url, "/auth/oidc/providers")
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
            case "invite":
                path = "/auth/invites/accept"
                body["inviteToken"] = .string(inviteToken); body["displayName"] = .string(displayName)
            default: path = "/auth/login"
            }
            defer { password = ""; setupCode = ""; inviteToken = "" }
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
