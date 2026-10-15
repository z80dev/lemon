import SwiftUI
import LemonBotKit

struct InspectorActivityTab: View {
    let store: LemonBotStore
    let bot: Bot
    let overview: BotOverview?
    let runs: [Run]
    let open: (InspectorDestination) -> Void
    @State private var action = UIActionState()

    private var liveRuns: [Run] {
        let live = store.liveRuns(forBot: bot.id)
        return live.isEmpty ? runs.filter { liveRunStatuses.contains($0.status) } : live
    }
    private var botConversations: [Conversation] { store.conversations.filter { $0.botIds.contains(bot.id) } }
    private var step: LiveStep? { botConversations.lazy.compactMap { store.currentStep(in: $0.id) }.first }
    private var liveToolCalls: [ToolCallEntry] {
        let ids = Set(liveRuns.map(\.id))
        let calls: [ToolCallEntry] = Set(liveRuns.map(\.conversationId)).flatMap { store.entries[$0] ?? [] }.compactMap {
            if case .toolCall(let call) = $0, let run = call.runId, ids.contains(run) { return call }
            return nil
        }
        return Array(calls.sorted { $0.timestampMs < $1.timestampMs }.suffix(8))
    }
    private var presenceStatus: String { overview?.presence.status ?? bot.activity }
    private var stale: Bool { (overview?.presence.stale ?? false) || !store.isOnline }
    private var machine: Machine? { store.machine(for: bot) ?? overview?.machine }
    private var tasks: [Conversation] {
        Array(store.conversations.filter { $0.kind == "task" && $0.botIds.contains(bot.id) }.sorted { $0.updatedAtMs > $1.updatedAtMs }.prefix(5))
    }
    private var recent: [Run] { Array(runs.filter { !liveRunStatuses.contains($0.status) }.sorted { $0.createdAtMs > $1.createdAtMs }.prefix(8)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            nowCard
            machineRow
            if !recent.isEmpty {
                InspectorSection(title: "Recent runs") { VStack(spacing: 4) { ForEach(recent) { RunRow(run: $0) } } }
            }
            if let overview, !overview.upcoming.items.isEmpty {
                InspectorSection(title: "Upcoming") {
                    VStack(spacing: 4) {
                        ForEach(overview.upcoming.items.prefix(4), id: \.id) { item in
                            InspectorRow(symbol: "clock", title: item.title,
                                         meta: item.blockedReason ?? zonedTimestamp(item.dueAtMs, timezone: item.timezone),
                                         chevron: false, tint: item.blockedReason == nil ? LB.muted : LB.warning)
                        }
                    }
                }
            }
            if let overview, !overview.activity.items.isEmpty {
                InspectorSection(title: "Recent activity") {
                    VStack(spacing: 4) {
                        ForEach(overview.activity.items.prefix(5)) { item in
                            let room = item.taskConversationId ?? item.conversationId
                            InspectorRow(symbol: "bolt.horizontal", title: item.title,
                                         meta: [item.summary, timestamp(item.occurredAtMs).formatted(.relative(presentation: .named))].filter { !$0.isEmpty }.joined(separator: " · "),
                                         chevron: room != nil, action: room.map { id in { store.selectedConversationID = id } })
                        }
                    }
                }
            }
            InspectorSection(title: "Tasks and threads") {
                VStack(spacing: 4) {
                    ForEach(tasks) { task in
                        InspectorRow(symbol: "checklist", title: task.name.isEmpty ? "Task" : task.name,
                                     meta: timestamp(task.updatedAtMs).formatted(.relative(presentation: .named))) { store.selectedConversationID = task.id }
                    }
                    if tasks.isEmpty { Text("No tasks yet").font(LBFont.meta).foregroundStyle(LB.faint).padding(.horizontal, 4) }
                    InspectorRow(symbol: "list.bullet.rectangle", title: "All activity") { open(.activityHub) }
                }
            }
        }
    }

    // MARK: Now card

    private var state: (label: String, tint: Color) {
        if !store.isOnline || presenceStatus == "offline" { return ("Offline", LB.faint) }
        if step?.needsInput == true || presenceStatus == "needs_input" { return ("Needs you", LB.warning) }
        if !liveRuns.isEmpty || step != nil || ["working", "making"].contains(presenceStatus) { return ("Working", LB.lemon) }
        return ("Idle", LB.success)
    }
    private var lastFinished: Date? {
        runs.filter { !liveRunStatuses.contains($0.status) }.map { timestamp($0.completedAtMs ?? $0.updatedAtMs) }.max()
    }

    private var nowCard: some View {
        SoftCard {
            HStack(spacing: 8) {
                Circle().fill(state.tint).frame(width: 8, height: 8)
                Text(state.label).font(LBFont.rowTitle).foregroundStyle(LB.ink)
                Spacer()
                if !liveRuns.filter({ stoppableRunStatuses.contains($0.status) }).isEmpty {
                    Button { Task { await stop() } } label: { Label("Stop", systemImage: "stop.fill").font(LBFont.metaEmphasis) }
                        .buttonStyle(.pill(.destructive, compact: true)).disabled(action.busy || !store.isOnline)
                        .accessibilityLabel("Stop current work")
                }
            }
            if let step {
                HStack(spacing: 8) {
                    Image(systemName: step.symbol).foregroundStyle(step.needsInput ? LB.warning : LB.muted).frame(width: 20)
                    Text(step.title).font(LBFont.body).foregroundStyle(LB.ink).lineLimit(2)
                    Spacer(minLength: 4)
                    if let since = step.since { Text(compactDuration(from: since)).font(LBFont.meta).foregroundStyle(LB.muted) }
                }
            } else if liveRuns.isEmpty {
                Text("Idle — nothing running").font(LBFont.body).foregroundStyle(LB.muted)
                if let lastFinished { Text("Last finished \(lastFinished.formatted(.relative(presentation: .named)))").font(LBFont.meta).foregroundStyle(LB.faint) }
            }
            if !liveToolCalls.isEmpty {
                VStack(spacing: 2) { ForEach(liveToolCalls) { StepRow(call: $0) } }.padding(.top, 2)
            }
            if stale {
                Label(store.isOnline ? "Status may be out of date" : "Disconnected — showing last known status", systemImage: "clock.badge.exclamationmark")
                    .font(LBFont.meta).foregroundStyle(LB.warning)
            }
            ActionErrorView(message: action.error)
            if let receipt = action.receipt { Text(receipt).font(LBFont.meta).foregroundStyle(LB.muted) }
        }
    }

    private var machineRow: some View {
        let status = machine?.status ?? overview?.presence.machineStatus ?? "unknown"
        let seen = machine?.lastSeenAtMs.map { "seen " + timestamp($0).formatted(.relative(presentation: .named)) }
        return InspectorRow(symbol: "desktopcomputer", title: machine?.name ?? overview?.presence.machineLabel ?? "Machine",
                            meta: [humanizedStatus(status), seen].compactMap { $0 }.joined(separator: " · "), tint: StatusTone(status).color) {
            open(.machine(bot.machineId))
        }
    }

    private func stop() async {
        await action.perform {
            for run in liveRuns where stoppableRunStatuses.contains(run.status) {
                let receipt: Run = try await store.mutate("POST", resourcePath("runs", run.id, "/cancel"), body: ["reason": .string("Explicit user Stop")])
                if let index = store.runs.firstIndex(where: { $0.id == receipt.id }) { store.runs[index] = receipt }
            }
            action.receipt = "Stop requested. Completed external effects are not rolled back."
        }
    }
}

/// One tool step: icon, title, first detail line; expands to monospaced output.
private struct StepRow: View {
    let call: ToolCallEntry
    @State private var expanded = false
    private var detail: String { call.detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var firstLine: String { detail.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { if !detail.isEmpty { withAnimation(LBMotion.snappy) { expanded.toggle() } } } label: {
                HStack(spacing: 8) {
                    Image(systemName: toolSymbol(call.tool)).font(.system(size: 12)).foregroundStyle(LB.muted).frame(width: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(call.title.isEmpty ? humanizedStatus(call.tool) : call.title).font(LBFont.rowSubtitle).foregroundStyle(LB.ink).lineLimit(1)
                        if !firstLine.isEmpty && !expanded { Text(firstLine).font(LBFont.meta).foregroundStyle(LB.muted).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    trailing
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded {
                Text(detail).font(LBFont.code).foregroundStyle(LB.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(LB.fill))
            }
        }.padding(.vertical, 3)
    }
    @ViewBuilder private var trailing: some View {
        switch call.status {
        case "started": ProgressView().controlSize(.mini)
        case "failed": Image(systemName: "exclamationmark.circle.fill").font(.system(size: 12)).foregroundStyle(LB.danger).accessibilityLabel("Failed")
        default: Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(LB.faint).accessibilityLabel("Done")
        }
    }
}

/// Finished run: outcome dot, human outcome, relative time, duration; expands to error and request ID.
private struct RunRow: View {
    let run: Run
    @State private var expanded = false
    private var outcome: (text: String, color: Color) {
        switch run.status {
        case "succeeded": return ("Finished", LB.success)
        case "failed": return ("Couldn't finish", LB.danger)
        case "cancelled": return ("Stopped", LB.muted)
        case "outcome_unknown": return ("Unconfirmed", LB.warning)
        default: return (humanizedStatus(run.status), LB.lemon)
        }
    }
    private var expandable: Bool { run.error != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { if expandable { withAnimation(LBMotion.snappy) { expanded.toggle() } } } label: {
                HStack(spacing: 10) {
                    Circle().fill(outcome.color).frame(width: 8, height: 8).frame(width: 22)
                    Text(outcome.text).font(LBFont.rowTitle).foregroundStyle(LB.ink)
                    Spacer(minLength: 6)
                    Text(meta).font(LBFont.meta).foregroundStyle(LB.muted).lineLimit(1)
                    if expandable { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(LB.faint).rotationEffect(.degrees(expanded ? 90 : 0)) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if expanded, let error = run.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.message).font(LBFont.rowSubtitle).foregroundStyle(LB.ink).textSelection(.enabled)
                    Button("Copy request ID") { copyText(error.requestId) }.buttonStyle(.pill(.quiet, compact: true))
                }.padding(.leading, 32)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.bubble))
    }
    private var meta: String {
        let end = timestamp(run.completedAtMs ?? run.updatedAtMs)
        var parts = [end.formatted(.relative(presentation: .named))]
        if let start = run.startedAtMs { parts.append(compactDuration(from: timestamp(start), to: end)) }
        return parts.joined(separator: " · ")
    }
}
