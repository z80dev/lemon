import Foundation

extension LemonBotStore {
    public func navigate(_ url: URL) async throws {
        let target = try DeepLinkTarget(url: url)
        if account?.workspaceID != target.workspaceID {
            let saved = accounts.filter { $0.workspaceID == target.workspaceID }
            guard saved.count == 1, let account = saved.first else { throw ClientError.foreignWorkspace }
            try await restoreAccount(account)
        }
        let current = generation
        let workspace: Workspace = try await read("/workspace")
        guard workspace.id == target.workspaceID else { throw ClientError.foreignWorkspace }
        var bot: Bot?
        if let id = target.botID { bot = try await read("/bots/\(HTTPTransport.pathID(id))") }
        if let id = target.machineID {
            let machine: Machine = try await read("/machines/\(HTTPTransport.pathID(id))")
            guard bot == nil || bot?.machineId == machine.id else { throw ClientError.invalidDeepLink }
        }
        var conversation: Conversation?
        if let id = target.conversationID {
            conversation = try await read("/conversations/\(HTTPTransport.pathID(id))")
            guard let bot, conversation?.botIds.contains(bot.id) == true else { throw ClientError.invalidDeepLink }
        }
        var selectedID = conversation?.id
        if let id = target.taskConversationID {
            let task: Conversation
            if let conversation, conversation.id == id { task = conversation }
            else { task = try await read("/conversations/\(HTTPTransport.pathID(id))") }
            guard task.kind == "task", let bot, task.botIds.contains(bot.id),
                  task.id == conversation?.id || task.parentConversationId == conversation?.id else { throw ClientError.invalidDeepLink }
            selectedID = task.id
        }
        var targetEntry: TranscriptEntry?
        if let id = target.entryID {
            let entry: TranscriptEntry = try await read("/entries/\(HTTPTransport.pathID(id))")
            guard entry.conversationId == selectedID else { throw ClientError.invalidDeepLink }
            targetEntry = entry
        }
        if let id = target.approvalID {
            let approval: Approval = try await read("/approvals/\(HTTPTransport.pathID(id))")
            guard approval.botId == bot?.id, approval.conversationId == selectedID, approval.entryId == target.entryID else { throw ClientError.invalidDeepLink }
        }
        if let id = target.routineID {
            let routine: Routine = try await read("/routines/\(HTTPTransport.pathID(id))")
            guard routine.botId == bot?.id else { throw ClientError.invalidDeepLink }
            if let runID = target.routineRunID {
                let run: RoutineRun = try await read("/routine-runs/\(HTTPTransport.pathID(runID))")
                guard run.routineId == routine.id else { throw ClientError.invalidDeepLink }
                let result: Conversation = try await read("/conversations/\(HTTPTransport.pathID(run.conversationId))")
                guard result.botIds.contains(routine.botId) else { throw ClientError.invalidDeepLink }
                selectedID = result.id
            }
        }
        try assertGeneration(current)
        if let id = selectedID { try await openConversation(id) }
        if let targetEntry { upsertEntry(targetEntry) }
        // Only publish after every referenced resource has passed backend ACL and relationship checks.
        navigationTarget = target
    }
}
