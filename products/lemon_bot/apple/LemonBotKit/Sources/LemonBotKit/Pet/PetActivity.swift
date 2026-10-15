import Foundation

/// Pure presentation of live state. Startup synchronization is not an offline error.
public enum PetActivity {
    public static func status(signedIn: Bool, connectionState: String, userID: ID?, workspaceID: ID?, bots: [Bot], runs: [Run], notifications: [BotNotification], entries: [ID: [TranscriptEntry]], now: Date = Date()) -> PetStatus {
        guard signedIn else { return PetStatus(mood: .signedOut, bubble: "Sign in to Lemon Bot") }
        if connectionState == "reconnect_required" { return PetStatus(mood: .offline, bubble: "Sign in again") }
        if connectionState == "disconnected" { return PetStatus(mood: .offline, bubble: "Offline") }
        let unread = notifications.filter { $0.userId == userID && $0.readAtMs == nil && $0.dismissedAtMs == nil }
        let attention = unread.filter { ["approval", "question", "human_step"].contains($0.kind) }.sorted { $0.createdAtMs > $1.createdAtMs }
        let waiting = runs.filter { $0.status == "awaiting_input" }.sorted(by: newest)
        // A notification and its waiting conversation represent one request, not two.
        let notifiedConversations = Set(attention.compactMap(\.conversationId))
        let count = attention.count + waiting.filter { !notifiedConversations.contains($0.conversationId) }.count
        if count > 0 {
            let notification = attention.first
            let bubble: String
            if count > 1 { bubble = "\(count) need you" }
            else {
                switch notification?.kind {
                case "approval": bubble = "Needs approval"
                case "question": bubble = "Has a question"
                default: bubble = "Needs your input"
                }
            }
            let run = notification.flatMap { note in runs.filter { $0.conversationId == note.conversationId }.sorted(by: newest).first } ?? waiting.first
            let link = notification.flatMap { validLink($0.deepLink) } ?? run.flatMap { runLink($0, workspaceID: workspaceID) }
            return PetStatus(mood: .needsInput, bubble: bubble, deepLink: link)
        }
        let failedRun = runs.filter { $0.status == "failed" && recent($0.completedAtMs, seconds: 60, now: now) }.max { ($0.completedAtMs ?? 0) < ($1.completedAtMs ?? 0) }
        let error = unread.filter { $0.kind == "error" && recent($0.createdAtMs, seconds: 60, now: now) }.max { $0.createdAtMs < $1.createdAtMs }
        if let error, error.createdAtMs > (failedRun?.completedAtMs ?? -Double.infinity) {
            let run = runs.filter { $0.conversationId == error.conversationId }.sorted(by: newest).first
            return PetStatus(mood: .failed, bubble: "Run failed", deepLink: validLink(error.deepLink) ?? run.flatMap { runLink($0, workspaceID: workspaceID) }, validUntil: date(error.createdAtMs).addingTimeInterval(60))
        }
        if let run = failedRun, let completed = run.completedAtMs {
            return PetStatus(mood: .failed, bubble: "Run failed", deepLink: runLink(run, workspaceID: workspaceID), validUntil: date(completed).addingTimeInterval(60))
        }
        let live = runs.filter { ["reserved", "queued", "running"].contains($0.status) }.sorted(by: newest)
        for run in live {
            let recentEntries = (entries[run.conversationId] ?? []).reversed()
            let tool = recentEntries.compactMap { entry -> ToolCallEntry? in
                if case .toolCall(let value) = entry, value.status == "started", value.runId == run.id { return value }
                return nil
            }.first
            let writing = recentEntries.contains { if case .message(let value) = $0 { return value.streaming }; return false }
            if tool != nil || writing {
                let title = tool.map { $0.title.isEmpty ? humanized($0.tool) : $0.title } ?? "Writing a reply"
                return PetStatus(mood: .working, detail: "\(botName(run, bots: bots)) · \(title)", deepLink: runLink(run, workspaceID: workspaceID))
            }
        }
        if let run = live.first {
            let title = run.status == "running" ? "Thinking" : "Queued"
            return PetStatus(mood: .thinking, detail: "\(botName(run, bots: bots)) · \(title)", deepLink: runLink(run, workspaceID: workspaceID))
        }
        if let run = runs.filter({ $0.status == "succeeded" && recent($0.completedAtMs, seconds: 6, now: now) }).max(by: { ($0.completedAtMs ?? 0) < ($1.completedAtMs ?? 0) }), let completed = run.completedAtMs {
            return PetStatus(mood: .done, bubble: "Done!", deepLink: runLink(run, workspaceID: workspaceID), validUntil: date(completed).addingTimeInterval(6))
        }
        return PetStatus(mood: .idle)
    }

    private static func newest(_ lhs: Run, _ rhs: Run) -> Bool {
        let a = lhs.startedAtMs ?? lhs.createdAtMs, b = rhs.startedAtMs ?? rhs.createdAtMs
        return a == b ? lhs.id < rhs.id : a > b
    }
    private static func date(_ ms: TimestampMs) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }
    private static func recent(_ ms: TimestampMs?, seconds: Double, now: Date) -> Bool {
        guard let ms else { return false }
        let age = now.timeIntervalSince(date(ms))
        return age >= 0 && age < seconds
    }
    private static func botName(_ run: Run, bots: [Bot]) -> String { bots.first { $0.id == run.botId }?.name ?? "Bot" }
    private static func humanized(_ raw: String) -> String {
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
    private static func validLink(_ string: String) -> URL? {
        guard let url = URL(string: string), (try? DeepLinkTarget(url: url)) != nil else { return nil }
        return url
    }
    private static func runLink(_ run: Run, workspaceID: ID?) -> URL? {
        guard let workspaceID else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let workspace = workspaceID.addingPercentEncoding(withAllowedCharacters: allowed), let bot = run.botId.addingPercentEncoding(withAllowedCharacters: allowed), let conversation = run.conversationId.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return validLink("lemonbot://workspace/\(workspace)/bot/\(bot)?conversationId=\(conversation)")
    }
}

@MainActor public extension LemonBotStore {
    func petStatus(now: Date = Date()) -> PetStatus {
        PetActivity.status(signedIn: account != nil, connectionState: connectionState, userID: user?.id ?? account?.userID, workspaceID: workspace?.id ?? account?.workspaceID, bots: bots, runs: runs, notifications: notifications, entries: entries, now: now)
    }
}
