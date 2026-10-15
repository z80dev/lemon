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
            HStack(spacing: 10) {
                Image(systemName: "phone.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(LB.accent)
                    .frame(width: 26, height: 26).background(Circle().fill(LB.accent.opacity(0.14))).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voice chat · \(humanizedStatus(current.state))").font(LBFont.bodyEmphasis).foregroundStyle(LB.ink)
                    Text("\(compactDuration(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: Double(current.durationMs) / 1000))) · Speed \(current.settings.speed, specifier: "%.1f")×").cardMeta().lineLimit(1)
                }
                Spacer(minLength: 8)
                if current.userId == store.user?.id {
                    HStack(spacing: 6) {
                        Button { Task { await feedback("good") } } label: { Label("Good call", systemImage: "hand.thumbsup") }.buttonStyle(.pill(.secondary, compact: true))
                        Button { Task { await feedback("bad") } } label: { Label("Bad call", systemImage: "hand.thumbsdown") }.buttonStyle(.pill(.secondary, compact: true))
                    }.labelStyle(.iconOnly).disabled(action.busy || store.connectionState != "online")
                }
            }
            if !current.transcriptEntryIds.isEmpty || current.feedback != nil {
                CardDetails {
                    Text("Feedback: \(current.feedback.map(humanizedStatus) ?? "Not provided")")
                    Text("Voice: \(current.settings.voiceId)").textSelection(.enabled)
                    ForEach(current.transcriptEntryIds, id: \.self) { id in
                        Button("Open transcript entry") { Task { await action.perform { try await openEntry(id) } } }
                            .buttonStyle(.pill(.quiet, compact: true)).disabled(action.busy || store.connectionState != "online")
                        Button("Copy entry ID") { copyText(id) }.buttonStyle(.pill(.quiet, compact: true))
                    }
                }
            }
            CardNote(symbol: "info.circle", text: "Ending voice chat doesn't stop work already running. Dictation stays unsent until you review and send it.")
            ActionErrorView(message: action.error)
        }.padding(12).frame(maxWidth: LBMetric.bubbleMaxWidth, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: LBMetric.cardRadius, style: .continuous).fill(LB.bubble))
            .frame(maxWidth: .infinity, alignment: .leading)
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
