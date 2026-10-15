import SwiftUI
import LemonBotKit

// MARK: - Layout model

/// One visual row of the transcript: a divider, a (possibly collapsed) set of entries, or an inline run failure.
struct TranscriptRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case separator(Date)
        case unread
        case entry(TranscriptEntry)
        case tools([ToolCallEntry])
        case failure(Run)
    }
    let id: String
    let kind: Kind
    /// Space above the row: grouped bubbles sit close, groups are separated by `blockGap`.
    var topGap: CGFloat
    /// First bubble of a same-actor run (shows the actor name in group chats).
    var startsGroup: Bool
    var seq: Int
    /// Transcript entry IDs this row stands for, so deep links and Find can scroll to it.
    var entryIDs: [ID]
}

enum TranscriptLayout {
    static let separatorGap: TimeInterval = 30 * 60
    static let groupWindow: TimeInterval = 5 * 60

    /// Failed runs leave an empty assistant message behind; it is replaced by an inline failure row.
    static func isHiddenEmpty(_ entry: TranscriptEntry) -> Bool {
        guard case .message(let message) = entry else { return false }
        return message.role != "user" && message.attachmentIds.isEmpty && !message.streaming
            && message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    static func isFailure(_ run: Run) -> Bool { run.status == "failed" || run.status == "outcome_unknown" }
    /// Kinds that render as chat bubbles and group with neighbours from the same actor.
    static func isBubble(_ entry: TranscriptEntry) -> Bool {
        switch entry {
        case .message, .card, .userAttachment, .mcpApp, .voiceCall, .unsupported: return true
        case .toolCall, .notice, .event, .feedback: return false
        }
    }
    static func actorKey(_ entry: TranscriptEntry) -> String { entry.actor.kind + ":" + (entry.actor.id ?? entry.actor.displayName) }

    private enum Item {
        case entry(TranscriptEntry)
        case tools([ToolCallEntry])
        case failure(Run)
        var time: Date {
            switch self {
            case .entry(let entry): return timestamp(Double(entry.timestampMs))
            case .tools(let tools): return timestamp(Double(tools[0].timestampMs))
            case .failure(let run): return timestamp(Double(run.completedAtMs ?? run.updatedAtMs))
            }
        }
        var seq: Int? {
            switch self {
            case .entry(let entry): return entry.seq
            case .tools(let tools): return tools[0].seq
            case .failure: return nil
            }
        }
        var id: String {
            switch self {
            case .entry(let entry): return entry.id
            case .tools(let tools): return tools[0].id
            case .failure(let run): return "run-" + run.id
            }
        }
    }

    static func rows(entries: [TranscriptEntry], runs: [Run], unreadFromSeq: Int?, calendar: Calendar = .current) -> [TranscriptRow] {
        let failures = runs.filter(isFailure).sorted { $0.createdAtMs < $1.createdAtMs }
        let failuresByID = Dictionary(failures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let failedRequestIDs = Set(failures.compactMap { $0.error?.requestId })
        var batchAttachments: [ID: Set<ID>] = [:]
        for case .message(let message) in entries { if let batch = message.batchId { batchAttachments[batch, default: []].formUnion(message.attachmentIds) } }

        var emitted = Set<ID>()
        var items: [Item] = []
        for entry in entries {
            if isHiddenEmpty(entry) {
                if let runID = entry.runId, let run = failuresByID[runID], emitted.insert(runID).inserted { items.append(.failure(run)) }
                continue
            }
            if case .userAttachment(let attachment) = entry, let batch = entry.batchId, batchAttachments[batch]?.contains(attachment.attachmentId) == true { continue }
            if case .notice(let notice) = entry, notice.severity == "error", let request = notice.requestId, failedRequestIDs.contains(request) { continue }
            if case .toolCall(let tool) = entry, case .tools(let existing)? = items.last { items[items.count - 1] = .tools(existing + [tool]); continue }
            if case .toolCall(let tool) = entry { items.append(.tools([tool])); continue }
            items.append(.entry(entry))
        }
        for run in failures where !emitted.contains(run.id) {
            let index: Int
            if let last = items.lastIndex(where: { item in
                switch item {
                case .entry(let entry): return entry.runId == run.id
                case .tools(let tools): return tools.contains { $0.runId == run.id }
                case .failure: return false
                }
            }) { index = last + 1 }
            else {
                let time = timestamp(Double(run.completedAtMs ?? run.updatedAtMs))
                index = (items.lastIndex { $0.time <= time } ?? -1) + 1
            }
            items.insert(.failure(run), at: index)
        }

        var rows: [TranscriptRow] = []
        var previousTime: Date?
        var previousGroup: (key: String, time: Date)?
        var unreadPending = unreadFromSeq != nil
        var lastSeq = 0
        for item in items {
            let time = item.time
            var afterDivider = rows.isEmpty
            if let previousTime, time.timeIntervalSince(previousTime) <= separatorGap, calendar.isDate(time, inSameDayAs: previousTime) {} else {
                rows.append(TranscriptRow(id: "sep-" + item.id, kind: .separator(time), topGap: 0, startsGroup: false, seq: lastSeq, entryIDs: []))
                previousGroup = nil
                afterDivider = true
            }
            if unreadPending, let from = unreadFromSeq, let seq = item.seq, seq >= from {
                unreadPending = false
                rows.append(TranscriptRow(id: "unread-divider", kind: .unread, topGap: 0, startsGroup: false, seq: lastSeq, entryIDs: []))
                previousGroup = nil
                afterDivider = true
            }
            previousTime = time
            if let seq = item.seq { lastSeq = seq }
            switch item {
            case .entry(let entry):
                let groupable = isBubble(entry)
                let key = actorKey(entry)
                let grouped = groupable && previousGroup?.key == key && time.timeIntervalSince(previousGroup?.time ?? .distantPast) <= groupWindow
                rows.append(TranscriptRow(id: entry.id, kind: .entry(entry), topGap: afterDivider ? 0 : grouped ? LBMetric.groupGap : LBMetric.blockGap,
                                          startsGroup: !grouped, seq: entry.seq, entryIDs: [entry.id]))
                previousGroup = groupable ? (key, time) : nil
            case .tools(let tools):
                rows.append(TranscriptRow(id: tools[0].id, kind: .tools(tools), topGap: afterDivider ? 0 : 10, startsGroup: true, seq: tools[tools.count - 1].seq, entryIDs: tools.map(\.id)))
                previousGroup = nil
            case .failure(let run):
                rows.append(TranscriptRow(id: item.id, kind: .failure(run), topGap: afterDivider ? 0 : 10, startsGroup: true, seq: lastSeq, entryIDs: []))
                previousGroup = nil
            }
        }
        return rows
    }
}

// MARK: - Markdown and code

enum MessageSegment: Equatable {
    case text(String)
    case code(String, language: String?)
}

/// Splits fenced ``` blocks from prose. An unclosed fence (streaming) renders as code so far.
func messageSegments(_ text: String) -> [MessageSegment] {
    var segments: [MessageSegment] = []
    var buffer: [Substring] = []
    var inCode = false
    var language: String?
    func flush() {
        let body = buffer.joined(separator: "\n")
        buffer = []
        if inCode { segments.append(.code(body, language: language)); return }
        let trimmed = body.trimmingCharacters(in: .newlines)
        if !trimmed.trimmingCharacters(in: .whitespaces).isEmpty { segments.append(.text(trimmed)) }
    }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") {
            flush()
            if inCode { inCode = false; language = nil }
            else { inCode = true; let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces); language = tag.isEmpty ? nil : tag }
            continue
        }
        buffer.append(line)
    }
    if !buffer.isEmpty || inCode { flush() }
    return segments
}

/// Inline Markdown with newlines preserved; links with unsafe schemes are not made tappable.
func markdownString(_ text: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
    var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    for run in result.runs {
        guard let url = run.link else { continue }
        if safeExternalURL(url.absoluteString) == nil { result[run.range].link = nil }
        else { result[run.range].underlineStyle = .single }
    }
    return result
}

struct CodeBlock: View {
    let code: String
    var language: String?
    var inset: Color
    var ink: Color
    @State private var hovering = false
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code).font(LBFont.code).foregroundStyle(ink).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(inset))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { copyText(code) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(GhostCircleButtonStyle(size: 24, filled: true)).padding(6).accessibilityLabel("Copy code")
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .lbAnimation(LBMotion.fade, value: hovering)
        .contextMenu { Button("Copy code") { copyText(code) } }
        .accessibilityLabel(language.map { "\($0) code" } ?? "Code")
    }
}

/// A chat bubble: assistant (borderless `LB.bubble`) or the owner's (Bot tint).
struct MessageBubble: View {
    let text: String
    var streaming = false
    var mine = false
    var palette: BotPalette
    var body: some View {
        let ink = mine ? palette.onTint : LB.ink
        let segments = messageSegments(text)
        VStack(alignment: .leading, spacing: 8) {
            if segments.isEmpty && streaming { TypingDots(color: LB.muted).padding(.vertical, 5) }
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let value):
                    Text(markdownString(value)).font(LBFont.body).lineSpacing(LBFont.bodyLineSpacing)
                        .foregroundStyle(ink).tint(mine ? palette.onTint : LB.accent)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .code(let value, let language):
                    CodeBlock(code: value, language: language, inset: mine ? LB.tintedCodeInset : LB.codeInset, ink: ink)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: LBMetric.bubbleRadius, style: .continuous).fill(mine ? palette.tint : LB.bubble))
    }
}

/// Soft quiet container for non-text entries (app snapshots, unsupported entries).
struct QuietBubble<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: LBMetric.bubbleRadius, style: .continuous).fill(LB.bubble))
    }
}

/// "The Bot is preparing a reply" bubble.
struct TypingBubble: View {
    var body: some View {
        TypingDots().padding(.horizontal, 16).padding(.vertical, 14)
            .background(Capsule().fill(LB.bubble))
            .accessibilityElement(children: .ignore).accessibilityLabel("Typing")
    }
}

// MARK: - Dividers

struct UnreadDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(LB.unread.opacity(0.55)).frame(height: 1)
            Text("Unread").font(LBFont.metaEmphasis).foregroundStyle(LB.unread)
            Rectangle().fill(LB.unread.opacity(0.55)).frame(height: 1)
        }.padding(.vertical, 12).accessibilityElement(children: .combine).accessibilityLabel("Unread messages")
    }
}

// MARK: - Inline issues (failed runs, error notices)

struct IssueField: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}
struct IssueDetail {
    var message: String?
    var fields: [IssueField] = []
    var note: String?
}

/// Subtle system row with an optional Retry and a Details disclosure. Technical IDs live only in Details.
struct IssueRow: View {
    let title: String
    var tint: Color = LB.danger
    var retry: (() -> Void)?
    var retryExplanation: String?
    var detail: IssueDetail?
    @State private var expanded = false
    @Environment(\.lbReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(tint).accessibilityHidden(true)
                Text(title).foregroundStyle(LB.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let retry {
                    Button("Retry", action: retry).buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(LB.ink)
                        .accessibilityHint(retryExplanation ?? "Try again")
                }
                if detail != nil {
                    if retry != nil { Text("·").foregroundStyle(LB.faint).accessibilityHidden(true) }
                    Button(expanded ? "Hide details" : "Details") { lbWithAnimation(reduceMotion, LBMotion.snappy) { expanded.toggle() } }
                        .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(LB.ink)
                }
            }.font(LBFont.meta)
            if expanded, let detail {
                VStack(alignment: .leading, spacing: 6) {
                    if let retryExplanation, retry != nil { Text(retryExplanation).font(LBFont.meta).foregroundStyle(LB.muted) }
                    if let message = detail.message { Text(message).font(LBFont.rowSubtitle).foregroundStyle(LB.ink).textSelection(.enabled) }
                    ForEach(detail.fields) { field in
                        HStack(spacing: 6) {
                            Text(field.label).font(LBFont.meta).foregroundStyle(LB.muted)
                            Text(field.value).font(LBFont.code).foregroundStyle(LB.ink).textSelection(.enabled).lineLimit(2)
                            Button { copyText(field.value) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(GhostCircleButtonStyle(size: 22, filled: false)).accessibilityLabel("Copy \(field.label.lowercased())")
                        }
                    }
                    if let note = detail.note { Text(note).font(LBFont.meta).foregroundStyle(LB.faint) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.fill))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Inline row for a failed or unconfirmed run, shown where the empty reply would have been.
struct RunFailureRow: View {
    let run: Run
    var retry: (() -> Void)?
    var loadError: String?
    var refresh: (() -> Void)?
    var body: some View {
        let unknown = run.status == "outcome_unknown"
        var fields: [IssueField] = []
        if let requestId = run.error?.requestId, !requestId.isEmpty { fields.append(IssueField(label: "Request ID", value: requestId)) }
        fields.append(IssueField(label: "Run ID", value: run.id))
        var notes: [String] = []
        if unknown { notes.append("Check the result before asking again; this was not resent.") }
        if loadError != nil { notes.append("Run history couldn't refresh. Any status shown may be out of date.") }
        let message = run.error?.message
        let detail = IssueDetail(message: message?.isEmpty == false ? message : (unknown ? "The Bot may or may not have finished this." : "No error message was recorded."),
                                 fields: [IssueField(label: "Status", value: humanizedStatus(run.status))] + fields,
                                 note: notes.isEmpty ? nil : notes.joined(separator: " "))
        return VStack(alignment: .leading, spacing: 8) {
            IssueRow(title: unknown ? "Not sure this finished." : "Couldn't finish this.", tint: unknown ? LB.warning : LB.danger,
                     retry: run.status == "failed" && run.error?.retrySafe == true ? retry : nil,
                     retryExplanation: "Restores your message to the composer. Nothing is sent automatically.", detail: detail)
            if let loadError {
                IssueRow(title: "Couldn't refresh run history.", retry: refresh, detail: IssueDetail(message: loadError))
            }
        }
    }
}

/// Error notice: subtle row with request ID behind Details; info notices are centered muted text.
struct NoticeRow: View {
    let notice: NoticeEntry
    var body: some View {
        if notice.severity == "error" {
            IssueRow(title: notice.text, detail: notice.requestId.map { IssueDetail(fields: [IssueField(label: "Request ID", value: $0)]) })
        } else {
            Text(notice.text).font(LBFont.meta).foregroundStyle(LB.muted).multilineTextAlignment(.center)
                .textSelection(.enabled).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Tool calls

struct ToolActivityRow: View {
    let tools: [ToolCallEntry]
    @State private var expanded = false
    @State private var openTools: Set<ID> = []
    @Environment(\.lbReduceMotion) private var reduceMotion
    var body: some View {
        let failedCount = tools.reduce(0) { $0 + ($1.status == "failed" ? 1 : 0) }
        VStack(alignment: .leading, spacing: 2) {
            if tools.count == 1, let tool = tools.first {
                line(tool)
            } else {
                Button { lbWithAnimation(reduceMotion, LBMotion.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver").frame(width: 14)
                        Text("Used \(tools.count) tools\(failedCount == 0 ? "" : " · \(failedCount) failed")")
                        status(for: tools)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .font(LBFont.meta).foregroundStyle(failedCount > 0 ? LB.danger : LB.muted)
                    .padding(.horizontal, 8).padding(.vertical, 4).rowHighlight(selected: false, radius: 8)
                }.buttonStyle(.plain)
                    .accessibilityHint(expanded ? "Hide tools" : "Show tools")
                if expanded {
                    VStack(alignment: .leading, spacing: 2) { ForEach(tools) { line($0) } }.padding(.leading, 14).transition(.opacity)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func title(_ tool: ToolCallEntry) -> String { tool.title.isEmpty ? humanizedStatus(tool.tool) : tool.title }
    private func line(_ tool: ToolCallEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { lbWithAnimation(reduceMotion, LBMotion.snappy) { if !openTools.insert(tool.id).inserted { openTools.remove(tool.id) } } } label: {
                HStack(spacing: 6) {
                    Image(systemName: toolSymbol(tool.tool)).frame(width: 14)
                    Text(title(tool)).lineLimit(1)
                    status(for: [tool])
                }
                .font(LBFont.meta).foregroundStyle(tool.status == "failed" ? LB.danger : LB.muted)
                .padding(.horizontal, 8).padding(.vertical, 4).rowHighlight(selected: false, radius: 8)
            }.buttonStyle(.plain)
            if openTools.contains(tool.id) {
                VStack(alignment: .leading, spacing: 3) {
                    if let detail = tool.detail, !detail.isEmpty { Text(detail).font(LBFont.meta).foregroundStyle(LB.ink).textSelection(.enabled) }
                    Text("Tool: \(tool.tool)").font(LBFont.meta).foregroundStyle(LB.faint)
                }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: LBMetric.rowRadius, style: .continuous).fill(LB.fill))
                    .padding(.leading, 8).transition(.opacity)
            }
        }
    }
    @ViewBuilder private func status(for tools: [ToolCallEntry]) -> some View {
        if tools.contains(where: { $0.status == "failed" }) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(LB.danger).accessibilityLabel("Failed")
        } else if tools.contains(where: { $0.status == "started" }) {
            if reduceMotion { Image(systemName: "circle.dotted").foregroundStyle(LB.faint).accessibilityLabel("In progress") }
            else { ProgressView().controlSize(.mini).scaleEffect(0.8).accessibilityLabel("In progress") }
        } else {
            Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(LB.faint).accessibilityLabel("Done")
        }
    }
}

// MARK: - Live working row

/// Compact "what the Bot is doing now" pill above the composer.
struct LiveWorkingRow: View {
    let step: LiveStep
    var canStop: Bool
    var stopping: Bool
    var onStop: () -> Void
    var onOpen: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            if step.needsInput { Image(systemName: step.symbol).font(LBFont.metaEmphasis).foregroundStyle(LB.warning) }
            else { TypingDots(color: LB.muted, dot: 4) }
            Text(step.title).font(LBFont.metaEmphasis).foregroundStyle(step.needsInput ? LB.warning : LB.ink).lineLimit(1)
            if let since = step.since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(compactDuration(from: since, to: context.date)).font(LBFont.meta).monospacedDigit().foregroundStyle(LB.faint)
                }
            }
            if canStop {
                Button(action: onStop) { Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon) }
                    .buttonStyle(PillButtonStyle(kind: .quiet, compact: true, minimumTouchSize: LBMetric.composerHitSize)).disabled(stopping).accessibilityLabel("Stop")
            }
        }
        .padding(.leading, 14).padding(.trailing, canStop ? 5 : 14).padding(.vertical, 5)
        .background(Capsule().fill(step.needsInput ? LB.warning.opacity(0.13) : LB.fill))
        .contentShape(Capsule())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Show activity", onOpen)
    }
}

/// Transient receipt line ("Stopping…", "Stopped") with exact detail one tap away.
struct StatusToast: Equatable {
    var text: String
    var detail: String?
}
struct ToastLine: View {
    let toast: StatusToast
    var persistent: Bool
    var onDismiss: () -> Void
    @State private var showDetail = false
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(toast.text).font(LBFont.meta).foregroundStyle(LB.muted)
                if toast.detail != nil { Button(showDetail ? "Hide details" : "Details") { showDetail.toggle() }.buttonStyle(.pill(.quiet, compact: true)) }
            }
            if showDetail, let detail = toast.detail { Text(detail).font(LBFont.meta).foregroundStyle(LB.faint).textSelection(.enabled).multilineTextAlignment(.center) }
        }
        .task(id: toast) {
            guard !persistent else { return }
            try? await Task.sleep(for: .seconds(5))
            if !showDetail && !Task.isCancelled { onDismiss() }
        }
    }
}

// MARK: - Chrome

/// Conversation identity pill (floating on macOS, in the navigation bar on iOS). Opens the inspector.
struct ConversationHeaderPill: View {
    let store: LemonBotStore
    let bots: [Bot]
    let title: String
    let working: Bool
    var floating = true
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                avatars
                Text(title).font(LBFont.rowTitle).foregroundStyle(LB.ink).lineLimit(1)
                if working, let tint = bots.first?.palette.tint {
                    Circle().fill(tint).frame(width: 7, height: 7).accessibilityLabel("Working")
                }
            }
            .padding(.leading, 6).padding(.trailing, 13).padding(.vertical, 5)
            .background(Capsule().fill(floating ? LB.raised : LB.fill))
            .shadow(color: floating && scheme == .light ? LB.shadow : .clear, radius: 10, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(bots.isEmpty)
        .accessibilityLabel("Show Bot details")
        .accessibilityValue(title)
    }
    @ViewBuilder private var avatars: some View {
        if bots.count > 1 {
            HStack(spacing: -8) {
                ForEach(Array(bots.prefix(3).enumerated()), id: \.element.id) { index, bot in
                    BotAvatarView(store: store, bot: bot).frame(width: 22, height: 22)
                        .padding(1.5).background(Circle().fill(floating ? LB.raised : LB.canvas))
                        .zIndex(Double(-index))
                }
            }
        } else if let bot = bots.first {
            BotAvatarView(store: store, bot: bot).frame(width: 22, height: 22)
        } else {
            Image(systemName: "person.2").font(.system(size: 12)).foregroundStyle(LB.muted).frame(width: 22, height: 22)
        }
    }
}

struct TranscriptFindBar: View {
    @Binding var query: String
    let matchCount: Int
    /// 1-based position of the current match, 0 when none.
    let position: Int
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onClose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(LB.muted).accessibilityHidden(true)
            TextField("Find in chat", text: $query).textFieldStyle(.plain).font(LBFont.rowSubtitle).focused($focused)
                .onSubmit(onNext)
                .onKeyPress(.escape) { onClose(); return .handled }
            if !query.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(position) of \(matchCount)").font(LBFont.meta).monospacedDigit().foregroundStyle(LB.muted).fixedSize()
            }
            Button(action: onPrevious) { Image(systemName: "chevron.up") }.buttonStyle(GhostCircleButtonStyle(size: 24, filled: false))
                .disabled(matchCount == 0).accessibilityLabel("Previous match")
            Button(action: onNext) { Image(systemName: "chevron.down") }.buttonStyle(GhostCircleButtonStyle(size: 24, filled: false))
                .disabled(matchCount == 0).accessibilityLabel("Next match")
            Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(GhostCircleButtonStyle(size: 24, filled: false)).accessibilityLabel("Close find")
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: 380)
        .background(Capsule().fill(LB.raised))
        .shadow(color: scheme == .light ? LB.shadow : .clear, radius: 10, y: 3)
        .onAppear { focused = true }
    }
}

/// Floating "jump to latest" pill shown when the user has scrolled away from the bottom.
struct JumpToLatestPill: View {
    let hasNew: Bool
    let tint: BotPalette
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) { Label(hasNew ? "New messages" : "Latest", systemImage: "arrow.down") }
            .buttonStyle(.pill(.primary(tint.tint, tint.onTint), compact: true))
            .shadow(color: scheme == .light ? LB.shadow : .clear, radius: 8, y: 2)
            .accessibilityLabel(hasNew ? "New messages, jump to latest" : "Jump to latest")
    }
}
