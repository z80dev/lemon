import Foundation
import Dispatch

extension LemonBotStore {
    func stopSocket() {
        socketTask?.cancel(); socketTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        connectionState = "disconnected"
    }
    func startSocket() {
        stopSocket()
        guard account != nil else { return }
        let current = generation
        socketTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.generation == current, let account = self.account, let transport = self.transport else { return }
                self.connectionState = "connecting"
                do {
                    var c = URLComponents(url: try transport.url("/realtime"), resolvingAgainstBaseURL: false)!
                    c.scheme = c.scheme == "https" ? "wss" : "ws"
                    guard let url = c.url else { throw ClientError.invalidPath }
                    let task = transport.session.webSocketTask(with: url)
                    self.socket = task; task.resume()
                    try await self.sendSocket(.auth(RealtimeClientFrameAuth(token: account.token, deviceId: self.deviceID)), on: task)
                    var heartbeat: Task<Void, Never>?
                    defer { heartbeat?.cancel(); task.cancel(with: .goingAway, reason: nil) }
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard !Task.isCancelled else { return }
                        try self.assertGeneration(current)
                        let data: Data
                        switch message {
                        case .string(let text): data = Data(text.utf8)
                        case .data: throw ClientError.invalidFrame
                        @unknown default: throw ClientError.invalidFrame
                        }
                        guard data.count <= 1024 * 1024 else { throw ClientError.invalidFrame }
                        let frame = try JSONDecoder().decode(RealtimeServerFrame.self, from: data)
                        self.lastServerActivity = DispatchTime.now().uptimeNanoseconds
                        if case .ready(let ready) = frame {
                            guard ready.userId == account.userID, ready.workspaceId == account.workspaceID else { throw ClientError.accountChanged }
                            _ = try WorkspaceCursor.normalized(ready.cursor)
                            self.connectionState = "syncing"
                            try await self.sendSocket(.subscribe(RealtimeClientFrameSubscribe(requestId: UUID().uuidString, cursor: self.cursor, conversationIds: [])), on: task)
                            heartbeat?.cancel()
                            heartbeat = Task { [weak self] in
                                let interval = UInt64(max(1000, min(ready.heartbeatMs, 25000))) * 1_000_000
                                var nextPing = DispatchTime.now().uptimeNanoseconds + interval
                                while !Task.isCancelled {
                                    do {
                                        try await Task.sleep(nanoseconds: min(interval, 5_000_000_000))
                                        guard let self, self.generation == current else { return }
                                        let now = DispatchTime.now().uptimeNanoseconds
                                        guard now - self.lastServerActivity < 60_000_000_000 else { task.cancel(with: .goingAway, reason: nil); return }
                                        guard now >= nextPing else { continue }
                                        nextPing = now + interval
                                        try await self.sendSocket(.ping(RealtimeClientFramePing(requestId: UUID().uuidString)), on: task)
                                        if self.connectionState == "online" { try await self.sendSocket(.presence(RealtimeClientFramePresence(foreground: self.foreground, conversationId: self.visibleConversationID)), on: task) }
                                    } catch { task.cancel(with: .goingAway, reason: nil); return }
                                }
                            }
                        } else {
                            try await self.process(frame, on: task)
                            if case .caughtUp = frame { attempt = 0 }
                        }
                    }
                    return
                } catch {
                    guard !Task.isCancelled, self.generation == current else { return }
                    self.connectionState = "disconnected"; self.errorMessage = error.localizedDescription
                    let close = self.socket?.closeCode.rawValue
                    if close == 4401 || close == 4403 || (error as? BackendError)?.failure.code == "unauthenticated" || (error as? BackendError)?.failure.code == "forbidden" { return }
                    attempt += 1
                    let seconds = min(30.0, pow(2.0, Double(min(attempt, 5)))) + Double.random(in: 0...0.5)
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                }
            }
        }
    }
    func sendSocket(_ frame: RealtimeClientFrame, on task: URLSessionWebSocketTask) async throws {
        let bytes = try JSONEncoder().encode(frame)
        guard let text = String(data: bytes, encoding: .utf8) else { throw ClientError.invalidFrame }
        try await task.send(.string(text))
    }
    public func sendFrame(_ body: JSONObject) async throws {
        let frame = try JSONDecoder().decode(RealtimeClientFrame.self, from: JSONEncoder().encode(body))
        if case .presence(let value) = frame { foreground = value.foreground; visibleConversationID = value.conversationId }
        guard connectionState == "online", let socket else { throw ClientError.offline }
        switch frame {
        case .auth, .subscribe, .ack: throw ClientError.invalidFrame
        case .presence(let value):
            foreground = value.foreground; visibleConversationID = value.conversationId
            try await sendSocket(frame, on: socket)
        case .terminalSubscribe(let value):
            terminalSubscriptions.insert(value.terminalId)
            let last = terminalSequences[value.terminalId] ?? value.afterSeq ?? 0
            terminalSequences[value.terminalId] = last
            try await sendSocket(.terminalSubscribe(RealtimeClientFrameTerminalSubscribe(terminalId: value.terminalId, afterSeq: last)), on: socket)
        case .voice:
            // Voice lifecycle is an explicit foreground action, not a replayable reconnect command.
            try await sendSocket(frame, on: socket)
        default: try await sendSocket(frame, on: socket)
        }
    }
    public func setPresence(foreground: Bool, conversationID: ID? = nil) async throws {
        self.foreground = foreground
        visibleConversationID = conversationID
        guard connectionState == "online", let socket else { return }
        try await sendSocket(.presence(RealtimeClientFramePresence(foreground: foreground, conversationId: conversationID)), on: socket)
    }
    func process(_ frame: RealtimeServerFrame, on socket: URLSessionWebSocketTask) async throws {
        switch frame {
        case .event(let event):
            guard try WorkspaceCursor.isAfter(event.seq, cursor) else { return }
            try await apply(event)
            try await advanceCursor(event.seq, on: socket)
        case .caughtUp(let value):
            try await advanceCursor(value.cursor, on: socket)
            connectionState = "online"; errorMessage = nil
            try await setPresence(foreground: foreground, conversationID: visibleConversationID)
            for id in terminalSubscriptions {
                try await sendSocket(.terminalSubscribe(RealtimeClientFrameTerminalSubscribe(terminalId: id, afterSeq: terminalSequences[id] ?? 0)), on: socket)
            }
        case .watermark(let value): try await advanceCursor(value.cursor, on: socket)
        case .error(let value):
            if value.error.code == "cursor_expired" {
                try await recoverExpiredCursor()
                try await sendSocket(.subscribe(RealtimeClientFrameSubscribe(requestId: UUID().uuidString, cursor: cursor, conversationIds: [])), on: socket)
            } else { throw BackendError(status: value.error.code == "unauthenticated" ? 401 : 400, failure: value.error) }
        case .terminalOutput(let output):
            guard terminalSubscriptions.contains(output.terminalId), Data(base64Encoded: output.dataBase64) != nil else { throw ClientError.invalidFrame }
            let last = terminalSequences[output.terminalId] ?? 0
            if output.seq <= last { return }
            if output.seq != last + 1 {
                try await sendSocket(.terminalSubscribe(RealtimeClientFrameTerminalSubscribe(terminalId: output.terminalId, afterSeq: last)), on: socket)
                return
            }
            terminalSequences[output.terminalId] = output.seq
            var values = terminalFrames[output.terminalId] ?? []
            values.append(output)
            var bytes = values.reduce(0) { $0 + $1.dataBase64.utf8.count }
            while values.count > 10_000 || bytes > 1_400_000 { bytes -= values.removeFirst().dataBase64.utf8.count }
            terminalFrames[output.terminalId] = values
        case .terminalGap(let gap):
            terminalGaps[gap.terminalId] = gap
            terminalSequences[gap.terminalId] = max(terminalSequences[gap.terminalId] ?? 0, gap.earliestSeq - 1)
        case .terminalExit(let value):
            terminalExitFrames[value.terminalId] = value
            if let code = value.code { terminalExits[value.terminalId] = code }
            terminalSubscriptions.remove(value.terminalId)
        case .typing(let value):
            var users = typingByConversation[value.conversationId] ?? [:]
            if value.active, value.expiresAtMs > Date().timeIntervalSince1970 * 1000 { users[value.userId] = value }
            else { users[value.userId] = nil }
            typingByConversation[value.conversationId] = users
        case .ready, .subscribed, .pong: break
        }
    }
    public func typingUsers(in conversationID: ID) -> [RealtimeTyping] {
        (typingByConversation[conversationID] ?? [:]).values.filter { $0.expiresAtMs > Date().timeIntervalSince1970 * 1000 }.sorted { $0.userId < $1.userId }
    }
    func clearConversationAccess(_ id: ID) {
        conversations.removeAll { $0.id == id }; entries[id] = nil; drafts[id] = nil
        runs.removeAll { $0.conversationId == id }; typingByConversation[id] = nil
        if selectedConversationID == id { selectedConversationID = nil }
        if visibleConversationID == id { visibleConversationID = nil }
        if let account {
            do { try persistence.clearDraft(conversationID: id, accountID: account.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func advanceCursor(_ value: Cursor, on socket: URLSessionWebSocketTask) async throws {
        try commitCursor(value)
        try await sendSocket(.ack(RealtimeClientFrameAck(cursor: cursor)), on: socket)
    }
    func commitCursor(_ value: Cursor) throws {
        let normalized = try WorkspaceCursor.normalized(value)
        let previous = cursor
        if try WorkspaceCursor.isAfter(normalized, cursor) { cursor = normalized }
        do { try persistCache() }
        catch { cursor = previous; throw error }
    }
    func recoverExpiredCursor() async throws {
        // A new atomic snapshot replaces derived state. Unsent drafts and independent
        // terminal replay cursors are never treated as a workspace mutation queue.
        let opened = Array(entries.keys)
        latestResources = [:]
        entries = Dictionary(uniqueKeysWithValues: opened.map { ($0, []) })
        connectionState = "syncing"
        try await synchronize()
    }
    func apply(_ event: RealtimeEvent) async throws {
        switch event.payload {
        case .userUpdated(let value): if value.id == user?.id, value.revision >= (user?.revision ?? 0) { user = value }
        case .workspaceUpdated(let value): if value.id == workspace?.id, value.revision >= (workspace?.revision ?? 0) { workspace = value }
        case .memberUpserted(let value): if value.userId == user?.id, value.revision >= (member?.revision ?? 0) { member = value }
        case .machineUpserted(let value): upsert(&machines, value, id: { $0.id }, revision: { $0.revision })
        case .machineDeleted(let value): machines.removeAll { $0.id == value.id }
        case .botUpserted(let value): upsert(&bots, value, id: { $0.id }, revision: { $0.revision })
        case .botDeleted(let value): bots.removeAll { $0.id == value.id }
        case .sectionUpserted(let value): upsert(&sections, value, id: { $0.id }, revision: { $0.revision })
        case .sectionDeleted(let value): sections.removeAll { $0.id == value.id }
        case .conversationUpserted(let value): upsert(&conversations, value, id: { $0.id }, revision: { $0.revision })
        case .conversationDeleted(let value):
            clearConversationAccess(value.id)
        case .conversationLeft(let value):
            if value.userId == (user?.id ?? account?.userID) {
                clearConversationAccess(value.conversationId)
                if let account {
                    let path = "/conversations/\(try HTTPTransport.pathID(value.conversationId))/leave"
                    for intent in pendingIntents.filter({ $0.method == "POST" && $0.path == path }) {
                        finishIntent((account.id, intent.clientNonce))
                    }
                }
            }
            else if conversations.contains(where: { $0.id == value.conversationId }) {
                do {
                    let updated: Conversation = try await read("/conversations/\(HTTPTransport.pathID(value.conversationId))")
                    upsert(&conversations, updated, id: { $0.id }, revision: { $0.revision })
                } catch let error as BackendError where error.status == 404 { clearConversationAccess(value.conversationId) }
            }
        case .conversationRead(let value):
            if value.userId == user?.id, let index = conversations.firstIndex(where: { $0.id == value.conversationId }) {
                conversations[index].lastReadSeq = value.throughSeq
                conversations[index].unreadCount = value.unread ? max(1, conversations[index].unreadCount) : 0
            }
        case .composerUpdated(let value):
            // Retain current local edits; cross-device server changes only replace an untouched local draft.
            if drafts[value.conversationId] == nil { drafts[value.conversationId] = LocalComposerDraft(text: value.text, attachmentIDs: value.attachmentIds, replyToEntryID: value.replyToEntryId, revision: value.revision) }
            if let account, let draft = drafts[value.conversationId] { try persistence.saveDraft(draft, conversationID: value.conversationId, accountID: account.id) }
        case .entryUpserted(let value): upsertEntry(value)
        case .entryDeleted(let value): entries[value.conversationId]?.removeAll { $0.id == value.id }
        case .entryDelta(let delta):
            if let index = entries[delta.conversationId]?.firstIndex(where: { $0.id == delta.entryId }),
               case .message(var message) = entries[delta.conversationId]![index], message.runId == delta.runId, message.streaming,
               message.text.utf16.count == delta.offset {
                message.text += delta.text; entries[delta.conversationId]![index] = .message(message)
            } else {
                let authoritative: TranscriptEntry = try await read("/entries/\(HTTPTransport.pathID(delta.entryId))")
                guard authoritative.conversationId == delta.conversationId, authoritative.runId == delta.runId else { throw ClientError.invalidFrame }
                upsertEntry(authoritative)
            }
        case .runUpserted(let value): upsert(&runs, value, id: { $0.id }, revision: { $0.revision })
        case .notificationUpserted(let value): upsert(&notifications, value, id: { $0.id }, revision: { $0.revision })
        case .notificationDeleted(let value): notifications.removeAll { $0.id == value.id }
        case .voiceUpserted(let value): if value.userId == user?.id { voiceSession = value }
        case .botPresence(let value): if let index = bots.firstIndex(where: { $0.id == value.botId }) { bots[index].activity = value.status }
        default: break
        }
        latestResources[event.event] = event.payload
        if case .entryDelta = event.payload { return }
        eventVersion += 1
    }
}
