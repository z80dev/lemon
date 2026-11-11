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
        let summaries = conversations.map { "\($0.id):\($0.lastEntryId ?? "")" }.joined(separator: "|")
        return "\(account?.id ?? ""):\(connectionState == "online")|\(summaries)"
    }

    /// Use the snapshot's last-entry ID, just like web, without opening the chat.
    public func sidebarPreview(in room: Conversation) async throws -> SidebarPreview? {
        guard let lastID = room.lastEntryId else { return nil }
        if let cached = entries[room.id]?.last(where: { $0.id == lastID }) {
            return SidebarPreview(entry: cached)
        }
        guard connectionState == "online" else { return nil }
        let entry: TranscriptEntry = try await read("/entries/\(HTTPTransport.pathID(lastID))")
        return SidebarPreview(entry: entry)
    }
}
