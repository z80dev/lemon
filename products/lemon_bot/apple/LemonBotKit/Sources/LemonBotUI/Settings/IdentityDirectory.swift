import SwiftUI
import AuthenticationServices
import CryptoKit
import Security
import LemonBotKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

private struct AdminOIDCSummary: Decodable, Identifiable { let id: String; let name: String; let enabled: Bool; let requireSSO: Bool }

@MainActor final class AdminWebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "lemonbot") { url, error in
                if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: error ?? CocoaError(.userCancelled)) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session
            if !session.start() { self.session = nil; continuation.resume(throwing: CocoaError(.featureUnsupported)) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(iOS)
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #else
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #endif
    }
}

struct OIDCVerificationView: View {
    let store: LemonBotStore
    let purpose: String
    @Binding var reauthToken: String
    @State private var control = AdminControl()
    @State private var providers: [AdminOIDCSummary] = []
    @State private var provider = ""
    @State private var authentication = AdminWebAuthentication()
    var body: some View {
        VStack(alignment: .leading) {
            Picker("Verified identity provider", selection: $provider) {
                Text("Choose provider").tag("")
                ForEach(providers.filter { $0.enabled }) { Text("\($0.name)\($0.requireSSO ? " · SSO required" : "")").tag($0.id) }
            }
            AdminAction(title: purpose == "link" ? "Verify and link identity" : "Reauthenticate with OIDC", store: store, control: control) {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.coderInvalidValue) }
                let verifier = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                let flow = try await store.mutate("POST", "/auth/oidc/start", body: ["providerId": .string(provider), "redirectUri": .string("lemonbot://auth/complete"), "codeChallenge": .string(challenge), "purpose": .string(purpose)], as: OIDCFlow.self)
                guard let url = URL(string: flow.authorizationUrl), url.scheme == "https" else { throw CocoaError(.coderInvalidValue) }
                let callback = try await authentication.authenticate(url)
                guard callback.scheme == "lemonbot", callback.host == "auth", callback.path == "/complete", let components = URLComponents(url: callback, resolvingAgainstBaseURL: false), let returnedFlow = components.queryItems?.first(where: { $0.name == "flowId" })?.value, returnedFlow == flow.id, let code = components.queryItems?.first(where: { $0.name == "completionCode" })?.value else { throw CocoaError(.coderInvalidValue) }
                var body: JSONObject = ["flowId": .string(flow.id), "completionCode": .string(code), "codeVerifier": .string(verifier)]
                if purpose == "link" {
                    body["reauthToken"] = .string(reauthToken)
                    _ = try await store.mutate("POST", "/auth/oidc/link", body: body, as: IdentityLink.self)
                    reauthToken = ""; control.notice = "Verified identity linked. Refresh identities."
                } else {
                    let result = try await store.mutate("POST", "/auth/oidc/complete", body: body, as: ReauthResult.self)
                    reauthToken = result.reauthToken; control.notice = "Reauthenticated; token is single-use and expires in five minutes."
                }
            }.disabled(provider.isEmpty || (purpose == "link" && reauthToken.isEmpty))
            if let error = control.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let notice = control.notice { Text(notice) }
        }.task { await control.perform { providers = try await store.read("/auth/oidc/providers", as: [AdminOIDCSummary].self) } }
    }
}

struct IdentitySettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var providers: [OIDCProvider] = []
    @State private var identities: [IdentityLink] = []
    @State private var tokens: [IntegrationToken] = []
    @State private var name = ""
    @State private var issuer = ""
    @State private var client = ""
    @State private var secretRef = ""
    @State private var scopes = "openid,email,profile"
    @State private var domains = ""
    @State private var groupClaim = ""
    @State private var requireSSO = false
    @State private var tokenName = ""
    @State private var kind = "scim"
    @State private var tokenScopes = "scim.users,scim.groups"
    @State private var tokenExpiring = true
    @State private var tokenDays = 30
    @State private var issued: IntegrationTokenIssued?
    @State private var password = ""
    @State private var reauth = ""
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Own verified identities") {
                Text("Linking requires fresh reauthentication and verified provider subject. Matching email alone never silently merges accounts. Unlink revokes product provider sessions, not proof external IdP sessions ended.")
                SecureField("Current password for reauthentication", text: $password)
                AdminAction(title: "Reauthenticate with password", store: store, control: control) {
                    let result = try await store.mutate("POST", "/auth/reauth", body: ["password": .string(password)], as: ReauthResult.self); password = ""; reauth = result.reauthToken
                }
                OIDCVerificationView(store: store, purpose: "reauth", reauthToken: $reauth)
                OIDCVerificationView(store: store, purpose: "link", reauthToken: $reauth)
                ForEach(identities) { identity in
                    Text("\(identity.issuer) · subject \(identity.subject)").textSelection(.enabled)
                    AdminAction(title: "Unlink verified identity", store: store, control: control, destructive: true) {
                        _ = try await store.mutate("DELETE", "/auth/identities/\(adminPath(identity.id))", body: ["revision": .number(Double(identity.revision)), "reauthToken": .string(reauth)], as: Deleted.self); reauth = ""; try await load()
                    }.disabled(reauth.isEmpty)
                }
            }
            if store.member?.role == "owner" {
                Section("OIDC providers — owner authority") {
                    Text("Requires a registered confidential IdP client, pinned HTTPS discovery/JWKS/token origins, a private serverSecrets reference and callback at PUBLIC_URL/v1/auth/oidc/callback/providerId. Native redirect lemonbot://auth/complete must be operator-allowlisted. Provider failures below show actual backend prerequisite.")
                    ForEach(providers) { value in NavigationLink("\(value.name) · \(value.enabled ? "enabled" : "disabled") · \(value.requireSSO ? "SSO required" : "optional")") { OIDCProviderSettingsView(store: store, provider: value) } }
                    TextField("Provider name", text: $name); TextField("HTTPS issuer", text: $issuer); TextField("Client ID", text: $client)
                    TextField("Operator server secret reference (not secret value)", text: $secretRef)
                    TextField("Scopes", text: $scopes); TextField("Allowed email domains", text: $domains); TextField("Group claim (optional)", text: $groupClaim)
                    Toggle("Require SSO for managed users", isOn: $requireSSO)
                    AdminAction(title: "Register OIDC provider", store: store, control: control) {
                        var body: JSONObject = ["name": .string(name), "issuer": .string(issuer), "clientId": .string(client), "clientSecretRef": .string(secretRef), "scopes": adminArray(adminStrings(scopes)), "allowedEmailDomains": adminArray(adminStrings(domains)), "requireSSO": .bool(requireSSO)]
                        if !groupClaim.isEmpty { body["groupClaim"] = .string(groupClaim) }
                        _ = try await store.mutate("POST", "/admin/oidc/providers", body: body, as: OIDCProvider.self); try await load()
                    }
                }
                Section("Scoped integration tokens / SCIM") {
                    Text("SCIM base: \(store.account?.baseURL.appendingPathComponent("scim/v2").absoluteString ?? "Sign in first"). The token only authorizes selected integration scopes, never chats or general admin APIs. Provisioned users/groups are directory identities, not host machines or conversation groups.").textSelection(.enabled)
                    NavigationLink("Inspect authenticated standard SCIM discovery") { SCIMDiscoveryView(store: store) }
                    TextField("Token name", text: $tokenName)
                    AdminChoice(label: "Kind", value: $kind, options: ["scim", "event_ingress", "audit_export"])
                    TextField("Exact scopes", text: $tokenScopes)
                    Toggle("Expire integration token", isOn: $tokenExpiring)
                    if tokenExpiring { Stepper("Expires after \(tokenDays) days", value: $tokenDays, in: 1...365) }
                    AdminAction(title: "Issue one-time token", store: store, control: control) {
                        var body: JSONObject = ["name": .string(tokenName), "kind": .string(kind), "scopes": adminArray(adminStrings(tokenScopes))]
                        if tokenExpiring { body["expiresInMs"] = .number(Double(tokenDays) * 86_400_000) }
                        issued = try await store.mutate("POST", "/integration-tokens", body: body, as: IntegrationTokenIssued.self); try await load()
                    }
                    if let issued { Text("Copy now; shown once").font(.headline); Text(issued.token).textSelection(.enabled); Button("Hide token") { self.issued = nil } }
                    ForEach(tokens) { token in
                        Text("\(token.name) · \(token.kind) · \(token.scopes.joined(separator: ", "))")
                        Text("Expires: \(token.expiresAtMs.map { adminDate(Double($0)) } ?? "no scheduled expiry")")
                        AdminAction(title: "Revoke token", store: store, control: control, destructive: true) {
                            _ = try await store.mutate("DELETE", "/integration-tokens/\(adminPath(token.id))", body: adminRevision(token.revision), as: Deleted.self); try await load()
                        }
                    }
                    Text("External SCIM client uses application/scim+json, bearer token, standard discovery ServiceProviderConfig/ResourceTypes/Schemas, ETag/If-Match and RFC7643/7644 Users/Groups. active=false revokes product access immediately; final owner cannot be deprovisioned. Configure group mappings in Directory.")
                }
            }
            Button("Refresh identities and configuration") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Identity").task { await control.perform { try await load() } }.onDisappear { issued = nil; password = ""; reauth = "" }
    }
    private func load() async throws {
        identities = try await adminReadAll(store, "/auth/identities", as: IdentityLink.self)
        if store.member?.role == "owner" { providers = try await adminReadAll(store, "/admin/oidc/providers", as: OIDCProvider.self); tokens = try await adminReadAll(store, "/integration-tokens", as: IntegrationToken.self) }
    }
}

struct OIDCProviderSettingsView: View {
    let store: LemonBotStore
    let provider: OIDCProvider
    @State private var control = AdminControl()
    @State private var current: OIDCProvider?
    @State private var enabled = true
    @State private var sso = false
    @State private var domains = ""
    @State private var scopes = ""
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Text(provider.issuer); Text("Client \(provider.clientId) · claim \(provider.groupClaim ?? "none")")
            Toggle("Enabled", isOn: $enabled); Toggle("Require SSO", isOn: $sso)
            TextField("Allowed email domains", text: $domains); TextField("Scopes", text: $scopes)
            AdminAction(title: "Save provider", store: store, control: control) {
                current = try await store.mutate("PATCH", "/admin/oidc/providers/\(adminPath(provider.id))", body: ["revision": .number(Double((current ?? provider).revision)), "enabled": .bool(enabled), "requireSSO": .bool(sso), "allowedEmailDomains": adminArray(adminStrings(domains)), "scopes": adminArray(adminStrings(scopes))], as: OIDCProvider.self)
            }
            AdminAction(title: "Delete provider configuration", store: store, control: control, destructive: true) {
                _ = try await store.mutate("DELETE", "/admin/oidc/providers/\(adminPath(provider.id))", body: adminRevision((current ?? provider).revision), as: Deleted.self); control.notice = "Provider removed."
            }
        }.navigationTitle(provider.name).onAppear { enabled = provider.enabled; sso = provider.requireSSO; domains = provider.allowedEmailDomains.joined(separator: ","); scopes = provider.scopes.joined(separator: ",") }
    }
}

struct DirectorySettingsView: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var groups: [DirectoryGroup] = []
    @State private var governance: Governance?
    @State private var name = ""
    @State private var memberIDs = ""
    @State private var access = "all"
    @State private var allowedGroups = ""
    @State private var sudo = false
    @State private var egress = false
    @State private var lockedNetwork = true
    @State private var review = true
    @State private var channels: Set<String> = []
    @State private var x = false
    @State private var email = false
    @State private var content = false
    @State private var inactive = false
    @State private var days = 30
    @State private var inactiveAction = "stop_worker"
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Directory identities — not host inventory") {
                ForEach(groups) { group in NavigationLink("\(group.name) · \(group.source) · \(group.memberUserIds.count) members") { DirectoryGroupSettingsView(store: store, group: group) } }
                TextField("New local group name", text: $name); TextField("Existing user IDs", text: $memberIDs, axis: .vertical)
                AdminAction(title: "Create local directory group", store: store, control: control) {
                    _ = try await store.mutate("POST", "/directory/groups", body: ["name": .string(name), "memberUserIds": adminArray(adminStrings(memberIDs))], as: DirectoryGroup.self); try await load()
                }
            }
            Section("Workspace governance") {
                AdminChoice(label: "Product group access", value: $access, options: ["all", "selected"])
                TextField("Allowed directory group IDs", text: $allowedGroups)
                Toggle("Allow sudo with actual host enforcement", isOn: $sudo); Toggle("Allow egress with machine grants", isOn: $egress)
                Toggle("Lock network policy for groups", isOn: $lockedNetwork); Toggle("Require review", isOn: $review)
                ForEach(["email", "slack", "telegram", "discord", "whatsapp"], id: \.self) { adapter in
                    Toggle("Enable \(adapter) channel adapter", isOn: Binding(get: { channels.contains(adapter) }, set: { if $0 { channels.insert(adapter) } else { channels.remove(adapter) } }))
                }
                Toggle("X mentions enabled", isOn: $x); Toggle("Email enabled", isOn: $email); Toggle("Explicit participant-consented content export enabled", isOn: $content)
                Toggle("Inactive host policy", isOn: $inactive)
                Stepper("After \(days) days", value: $days, in: 30...365)
                AdminChoice(label: "Inactive action", value: $inactiveAction, options: ["stop_worker", "suspend"])
                Text("Only verified idle/sleeping supported hosts qualify; disk and trust stay intact. This is not access deprovisioning. Bulk host operations are in Machines.")
                AdminAction(title: "Save governance", store: store, control: control) {
                    guard let governance else { return }
                    _ = try await store.mutate("PATCH", "/governance", body: ["revision": .number(Double(governance.revision)), "groupAccess": .string(access), "allowedDirectoryGroupIds": adminArray(adminStrings(allowedGroups)), "allowSudo": .bool(sudo), "allowEgress": .bool(egress), "lockNetworkForGroups": .bool(lockedNetwork), "requireReview": .bool(review), "allowedChannelAdapters": adminArray(channels.sorted()), "xMentionsEnabled": .bool(x), "emailEnabled": .bool(email), "contentExportEnabled": .bool(content), "inactiveHostPolicy": .object(["enabled": .bool(inactive), "afterDays": .number(Double(days)), "action": .string(inactiveAction)])], as: Governance.self)
                    try await load()
                }.disabled(governance == nil)
            }
            Button("Refresh") { Task { await control.perform { try await load() } } }
        }.navigationTitle("Directory and governance").task { await control.perform { try await load() } }
    }
    private func load() async throws {
        groups = try await adminReadAll(store, "/directory/groups", as: DirectoryGroup.self)
        let value = try await store.read("/governance", as: Governance.self); governance = value
        access = value.groupAccess; allowedGroups = value.allowedDirectoryGroupIds.joined(separator: ","); sudo = value.allowSudo; egress = value.allowEgress; lockedNetwork = value.lockNetworkForGroups; review = value.requireReview; channels = Set(value.allowedChannelAdapters); x = value.xMentionsEnabled; email = value.emailEnabled; content = value.contentExportEnabled; inactive = value.inactiveHostPolicy.enabled; days = value.inactiveHostPolicy.afterDays; inactiveAction = value.inactiveHostPolicy.action
    }
}

struct DirectoryGroupSettingsView: View {
    let store: LemonBotStore
    let group: DirectoryGroup
    @State private var control = AdminControl()
    @State private var current: DirectoryGroup?
    @State private var policy: GroupPolicy?
    @State private var name = ""
    @State private var members = ""
    @State private var access = true
    @State private var defaults = ""
    @State private var requiredRules = ""
    @State private var ceiling = "ask"
    @State private var sudo = false
    @State private var egress = false
    @State private var network = ""
    @State private var exemption = false
    @State private var modes: [String: String] = [:]
    var body: some View {
        Form {
            AdminStatus(control: control, store: store)
            Section("Provenance and membership") {
                Text("Source: \(group.source) · external mapping: \(group.externalId ?? "none")")
                TextField("Name", text: $name); TextField("Member user IDs", text: $members, axis: .vertical)
                Text("OIDC/SCIM-managed membership is not overwritten by local editing unless an operator-authorized owner override exists.")
                AdminAction(title: "Save local membership", store: store, control: control) {
                    current = try await store.mutate("PATCH", "/directory/groups/\(adminPath(group.id))", body: ["revision": .number(Double((current ?? group).revision)), "name": .string(name), "memberUserIds": adminArray(adminStrings(members))], as: DirectoryGroup.self)
                }.disabled(group.source != "local")
                AdminAction(title: "Delete directory group", store: store, control: control, destructive: true) {
                    _ = try await store.mutate("DELETE", "/directory/groups/\(adminPath(group.id))", body: adminRevision((current ?? group).revision), as: Deleted.self); control.notice = "Group removed."
                }
            }
            Section("Explainable group policy") {
                Toggle("Product access", isOn: $access); TextField("Default Bot IDs", text: $defaults); TextField("Required rule IDs", text: $requiredRules)
                AdminChoice(label: "Local execution ceiling", value: $ceiling, options: ["deny", "ask", "allow"])
                Toggle("Allow sudo", isOn: $sudo); Toggle("Allow egress", isOn: $egress); Toggle("Explicit reviewer exemption", isOn: $exemption)
                Text("Reviewer exemption does not override required ask-first rules, Draft Send, account consent, OS permissions or the network hard lock.")
                TextField("Network policy ID (empty clears)", text: $network)
                ForEach(adminCategories, id: \.self) { category in
                    AdminChoice(label: category, value: Binding(get: { modes[category] ?? "inherit" }, set: { modes[category] = $0 }), options: ["inherit", "ask_first", "auto_review", "allow"])
                }
                AdminAction(title: "Save group policy", store: store, control: control) {
                    guard let policy else { return }
                    let modesBody = modes.filter { $0.value != "inherit" }.mapValues(JSONValue.string)
                    self.policy = try await store.mutate("PATCH", "/directory/groups/\(adminPath(group.id))/policy", body: ["revision": .number(Double(policy.revision)), "productAccess": .bool(access), "defaultBotIds": adminArray(adminStrings(defaults)), "requiredRuleIds": adminArray(adminStrings(requiredRules)), "capabilityModes": .object(modesBody), "localExecutionCeiling": .string(ceiling), "allowSudo": .bool(sudo), "allowEgress": .bool(egress), "networkPolicyId": network.isEmpty ? .null : .string(network), "reviewExempt": .bool(exemption)], as: GroupPolicy.self)
                }.disabled(policy == nil)
            }
        }.navigationTitle(group.name).task {
            name = group.name; members = group.memberUserIds.joined(separator: ",")
            await control.perform {
                let value = try await store.read("/directory/groups/\(adminPath(group.id))/policy", as: GroupPolicy.self); policy = value
                access = value.productAccess; defaults = value.defaultBotIds.joined(separator: ","); requiredRules = value.requiredRuleIds.joined(separator: ","); ceiling = value.localExecutionCeiling; sudo = value.allowSudo; egress = value.allowEgress; network = value.networkPolicyId ?? ""; exemption = value.reviewExempt; modes = value.capabilityModes
            }
        }
    }
}
