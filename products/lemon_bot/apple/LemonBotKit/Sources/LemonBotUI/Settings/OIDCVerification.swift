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

