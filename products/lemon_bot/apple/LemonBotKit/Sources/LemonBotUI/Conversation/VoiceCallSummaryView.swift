import SwiftUI
import LemonBotKit

struct VoiceCallSummaryView: View {
    let store: LemonBotStore
    let session: VoiceSession
    init(store: LemonBotStore, session: VoiceSession) { self.store = store; self.session = session }
    @State private var updated: VoiceSession?
    @State private var action = UIActionState()
    private var current: VoiceSession { (updated?.revision ?? 0) > session.revision ? updated! : session }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Voice chat · \(current.state)", systemImage: "phone")
            Text("\(Int(current.durationMs / 1000)) seconds · voice \(current.settings.voiceId) · speed \(current.settings.speed)")
            Text("Feedback: \(current.feedback ?? "not provided")").font(.caption)
            ForEach(current.transcriptEntryIds, id: \.self) { id in
                Button("Open exact transcript entry \(id)") { Task { await action.perform { try await openEntry(id) } } }.font(.caption)
            }
            if current.userId == store.user?.id {
                HStack { Button("Good call") { Task { await feedback("good") } }; Button("Bad call") { Task { await feedback("bad") } } }
            }
            Text("Ending voice does not cancel work already running in chat. Voice memo playback and ordinary reviewed dictation are separate.").font(.caption)
            ActionErrorView(message: action.error)
        }.disabled(action.busy || store.connectionState != "online")
    }
    private func feedback(_ value: String) async {
        await action.perform { updated = try await store.mutate("PATCH", resourcePath("voice/sessions", current.id), body: ["revision": .number(Double(current.revision)), "feedback": .string(value)]) }
    }
    private func openEntry(_ id: ID) async throws {
        let room: Conversation = try await store.read(resourcePath("conversations", current.conversationId))
        guard let workspace = store.workspace, let botID = room.botIds.first else { throw ClientError.invalidDeepLink }
        var components = URLComponents()
        components.scheme = "lemonbot"; components.host = "workspace"
        components.percentEncodedPath = "/" + (workspace.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "") + "/bot/" + (botID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        var query = [URLQueryItem(name: "entryId", value: id)]
        if room.kind == "task" {
            guard let parent = room.parentConversationId else { throw ClientError.invalidDeepLink }
            query.append(URLQueryItem(name: "conversationId", value: parent)); query.append(URLQueryItem(name: "taskConversationId", value: room.id))
        } else { query.append(URLQueryItem(name: "conversationId", value: room.id)) }
        components.queryItems = query
        guard let url = components.url else { throw ClientError.invalidDeepLink }
        try await store.navigate(url)
    }
}
