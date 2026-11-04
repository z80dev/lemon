import SwiftUI
import LemonBotKit

struct AgentHandleView: View {
    let store: LemonBotStore
    let bot: Bot
    @State private var identity: AgentIdentity?
    @State private var handle = ""
    @State private var action = UIActionState()
    @State private var readAction = UIActionState()
    var body: some View {
        SwiftUI.Section("Agent handle — separate from display name") {
            if let identity {
                Text(identity.name.map { "@" + $0 } ?? "No handle set")
                Text(verbatim: identity.id).font(LBFont.meta).textSelection(.enabled)
            }
            TextField("Handle, e.g. @bob", text: $handle)
            HStack {
                Button("Set handle") { Task { await rename(handle.trimmingCharacters(in: .whitespacesAndNewlines)) } }.disabled(handle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear handle") { Task { await rename(nil) } }
            }.disabled(action.busy || store.connectionState != "online")
            Button("Refresh handle") { Task { await load() } }.disabled(readAction.inFlight)
            ActionErrorView(message: action.error)
            ActionErrorView(message: readAction.error)
            Text("In this Bot’s chat, send /agents to discover reachable agents, /tell @bob your message to address one, /agent-name bob to set a handle, or /agent-name --clear to clear it. Accepted is not completed; an unknown outcome must not be resent.").font(LBFont.meta)
        }.task(id: bot.id) { await load() }
    }
    private func load() async {
        await readAction.perform {
            let result: AgentIdentityResult = try await store.read(resourcePath("bots", bot.id, "/agent-identity"))
            identity = result.agent
        }
    }
    private func rename(_ name: String?) async {
        guard !action.busy, store.connectionState == "online" else { return }
        await action.perform {
            let result: AgentIdentityResult = try await store.mutate("PATCH", resourcePath("bots", bot.id, "/agent-identity"), body: ["clientNonce": .string(UUID().uuidString), "name": name.map(JSONValue.string) ?? .null])
            identity = result.agent
        }
    }
}
