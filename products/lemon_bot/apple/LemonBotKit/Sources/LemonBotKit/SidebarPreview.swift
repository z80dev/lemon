import Foundation

/// One-line last-message preview for a sidebar row.
public struct SidebarPreview: Equatable {
    public var entryID: ID
    public var text: String

    /// Markdown → single-line plain text ("**Done** — `x`" → "Done — x").
    static func plain(_ markdown: String) -> String {
        let lines = markdown.split(whereSeparator: \.isNewline).map { line in
            String(line).replacingOccurrences(of: #"^\s*(?:[#>]+|[-*+]|\d+[.)])\s+"#, with: "", options: .regularExpression)
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") }
        let joined = lines.joined(separator: " ")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let plain = (try? AttributedString(markdown: joined, options: options)).map { String($0.characters) } ?? joined
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init?(entry: TranscriptEntry) {
        entryID = entry.id
        switch entry {
        case .message(let message):
            let body = Self.plain(message.text)
            if body.isEmpty && message.attachmentIds.isEmpty {
                guard message.role != "user", !message.streaming else { return nil }
                text = "Couldn't finish the last request"
            } else {
                let content = body.isEmpty ? "Sent an attachment" : body
                text = message.role == "user" ? "You: \(content)" : content
            }
        case .userAttachment: text = "You: Sent an attachment"
        case .card: text = "Needs a look"
        case .voiceCall: text = "Voice chat"
        case .notice(let notice): text = notice.text
        default: return nil
        }
    }
}

extension LemonBotStore {
    /// Sync installs summaries before realtime becomes online. Retry uncached previews
    /// at that transition even when no conversation's last-entry ID has changed.
    public var sidebarPreviewKey: String {
        let summaries = conversations.map { "\($0.id):\(sidebarPreviewVersion($0) ?? "")" }.joined(separator: "|")
        return "\(account?.id ?? ""):\(connectionState == "online")|\(summaries)"
    }

    /// The last entry plus its cached revision. A reply first seen while still streaming (empty, so the
    /// preview falls back to an earlier entry) changes version when it settles, so the preview is re-read.
    public func sidebarPreviewVersion(_ room: Conversation) -> String? {
        guard let lastID = room.lastEntryId else { return nil }
        let revision = entries[room.id]?.last(where: { $0.id == lastID })?.revision
        return "\(lastID)#\(revision.map(String.init) ?? "")"
    }

    /// Use the snapshot's last-entry ID without opening the chat. Tool events can
    /// follow a reply, so inspect the preceding sequence window when needed.
    public func sidebarPreview(in room: Conversation) async throws -> SidebarPreview? {
        guard let lastID = room.lastEntryId else { return nil }
        let cached = entries[room.id]?.last(where: { $0.id == lastID })
        guard connectionState == "online" else {
            guard cached != nil else { return nil }
            return entries[room.id]?.reversed().lazy.compactMap { SidebarPreview(entry: $0) }.first
        }
        let entry: TranscriptEntry
        if let cached { entry = cached }
        else { entry = try await read("/entries/\(HTTPTransport.pathID(lastID))") }
        if let preview = SidebarPreview(entry: entry) { return preview }
        // The endpoint sorts ascending: beforeSeq alone would return the oldest
        // page. Bound both ends to get the 20 sequences immediately before it.
        let page: Page<TranscriptEntry> = try await read("/conversations/\(HTTPTransport.pathID(room.id))/entries", query: [
            "beforeSeq": String(entry.seq), "afterSeq": String(max(0, entry.seq - 21)), "limit": "20"
        ])
        return page.items.reversed().lazy.compactMap { SidebarPreview(entry: $0) }.first
    }
}
