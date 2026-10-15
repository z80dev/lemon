import SwiftUI
import LemonBotKit

/// Inspector tabs: what the Bot is doing, who it is, and what it keeps.
enum InspectorTab: String, CaseIterable, Identifiable {
    case activity, details, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activity: return "Activity"
        case .details: return "Details"
        case .library: return "Library"
        }
    }
}

/// Shared presentation state for the right inspector. Owned by the root so it survives Bot switches.
@MainActor @Observable final class InspectorPresentation {
    var isPresented = false
    var tab: InspectorTab = .activity
    init(isPresented: Bool = false, tab: InspectorTab = .activity) { self.isPresented = isPresented; self.tab = tab }
    func toggle() { isPresented.toggle() }
    func show(_ tab: InspectorTab) { self.tab = tab; isPresented = true }
}

/// One compact live step for the "working…" row and the Activity timeline.
struct LiveStep: Equatable {
    var title: String
    var symbol: String
    var since: Date?
    var needsInput = false
}

/// Run statuses that mean work is in progress (not unknown, not finished).
let liveRunStatuses: Set<String> = ["reserved", "queued", "running", "awaiting_input"]
/// Statuses the server still considers active for Stop (includes unconfirmed outcomes).
let stoppableRunStatuses: Set<String> = ["reserved", "queued", "running", "awaiting_input", "outcome_unknown"]

extension LemonBotStore {
    func liveRuns(in conversationID: ID) -> [Run] {
        runs.filter { $0.conversationId == conversationID && liveRunStatuses.contains($0.status) }
    }
    func liveRuns(forBot botID: ID) -> [Run] {
        runs.filter { $0.botId == botID && liveRunStatuses.contains($0.status) }
    }
    func machine(for bot: Bot) -> Machine? { machines.first { $0.id == bot.machineId } }
    func bot(for conversation: Conversation?) -> Bot? {
        guard let id = conversation?.leadBotId ?? conversation?.botIds.first else { return nil }
        return bots.first { $0.id == id }
    }
    var isOnline: Bool { connectionState == "online" }

    /// The current human-readable step for live work in a conversation, or nil when idle.
    func currentStep(in conversationID: ID) -> LiveStep? {
        let live = liveRuns(in: conversationID)
        let conversation = conversations.first { $0.id == conversationID }
        let phases = conversation?.activity ?? []
        guard !live.isEmpty || !phases.isEmpty else { return nil }
        let runIDs = Set(live.map(\.id))
        let started = live.compactMap { $0.startedAtMs }.min().map { timestamp(Double($0)) }
        if live.contains(where: { $0.status == "awaiting_input" }) {
            return LiveStep(title: "Waiting for you", symbol: "hand.raised", since: started, needsInput: true)
        }
        let recent = (entries[conversationID] ?? []).reversed()
        if let tool = recent.lazy.compactMap({ entry -> ToolCallEntry? in
            if case .toolCall(let value) = entry, value.status == "started", value.runId.map(runIDs.contains) ?? runIDs.isEmpty { return value }
            return nil
        }).first {
            return LiveStep(title: tool.title.isEmpty ? humanizedStatus(tool.tool) : tool.title, symbol: toolSymbol(tool.tool), since: timestamp(Double(tool.timestampMs)))
        }
        if recent.contains(where: { if case .message(let m) = $0, m.streaming { return true }; return false }) {
            return LiveStep(title: "Writing a reply", symbol: "text.cursor", since: started)
        }
        if let phase = phases.first?.phase {
            switch phase {
            case "reading": return LiveStep(title: "Reading", symbol: "eye", since: started)
            case "typing": return LiveStep(title: "Writing a reply", symbol: "text.cursor", since: started)
            default: return LiveStep(title: "Working", symbol: "sparkles", since: started)
            }
        }
        if live.allSatisfy({ ["reserved", "queued"].contains($0.status) }) { return LiveStep(title: "Queued", symbol: "clock", since: nil) }
        return LiveStep(title: "Thinking", symbol: "sparkles", since: started)
    }
}

/// SF Symbol for a tool name, used in compact step rows.
func toolSymbol(_ tool: String) -> String {
    let t = tool.lowercased()
    if t.contains("search") || t.contains("web") || t.contains("browse") { return "globe" }
    if t.contains("read") || t.contains("file") || t.contains("open") { return "doc.text" }
    if t.contains("write") || t.contains("edit") || t.contains("patch") { return "pencil" }
    if t.contains("bash") || t.contains("shell") || t.contains("exec") || t.contains("terminal") || t.contains("command") { return "terminal" }
    if t.contains("mail") || t.contains("email") { return "envelope" }
    if t.contains("calendar") { return "calendar" }
    if t.contains("memory") { return "brain" }
    if t.contains("message") || t.contains("slack") || t.contains("send") { return "paperplane" }
    return "wrench.and.screwdriver"
}

/// Compact relative duration: "4s", "2m", "1h 5m".
public func compactDuration(from start: Date, to end: Date = .now) -> String {
    let seconds = max(0, Int(end.timeIntervalSince(start)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    let minutes = (seconds % 3600) / 60
    return minutes == 0 ? "\(seconds / 3600)h" : "\(seconds / 3600)h \(minutes)m"
}

/// Human date for separators: "Today 11:29 AM", "Yesterday 9:02 PM", "Sun, Aug 30 11:11 AM".
func separatorDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return "Today \(time)" }
    if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " " + time
    }
    return date.formatted(.dateTime.month(.abbreviated).day().year()) + " " + time
}

/// Short sidebar time: "11:29 AM", "Yesterday", "Mon", "Aug 30".
func sidebarDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
    return date.formatted(.dateTime.month(.abbreviated).day())
}
