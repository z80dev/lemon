import SwiftUI
import LemonBotKit

enum BotLifecyclePresentation {
    static func operations(_ lifecycle: BotLifecycle?) -> [String] {
        guard let lifecycle else { return ["duplicate", "move", "reset", "delete"] }
        var result: [String] = []
        if lifecycle.canFinishSetup { result.append("finish-setup") }
        if lifecycle.canReaddress { result.append("readdress") }
        if lifecycle.canDelete { result.append("delete") }
        return result
    }

    static func label(_ operation: String) -> String {
        switch operation {
        case "finish-setup": return "Finish setup"
        case "readdress": return "Update address"
        case "delete": return "Delete Bot"
        case "move": return "Move machine"
        case "reset": return "Reset selected scopes"
        default: return "Duplicate"
        }
    }

    static func status(_ lifecycle: BotLifecycle) -> String {
        switch lifecycle.status {
        case "running": return "In progress"
        case "outcome_unknown": return "Result not confirmed"
        default: return "Needs attention"
        }
    }

    static func step(_ lifecycle: BotLifecycle) -> String {
        let words = lifecycle.step.components(separatedBy: CharacterSet(charactersIn: "_.-"))
            .filter { !$0.isEmpty }.joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

struct BotLifecycleNotice: View {
    let lifecycle: BotLifecycle
    var manage: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(BotLifecyclePresentation.status(lifecycle)).font(.headline)
            Text(verbatim: BotLifecyclePresentation.step(lifecycle)).font(LBFont.metaEmphasis)
            Text(verbatim: lifecycle.message).textSelection(.enabled)
            if let manage {
                let operation = BotLifecyclePresentation.operations(lifecycle).first
                Button(operation.map { BotLifecyclePresentation.label($0) + "…" } ?? "Manage Bot…", action: manage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
