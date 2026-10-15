import SwiftUI
import LemonBotKit

struct InspectorLibraryTab: View {
    let store: LemonBotStore
    let bot: Bot
    let routines: [Routine]
    let open: (InspectorDestination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !bot.referenceAttachmentIds.isEmpty {
                InspectorSection(title: "Files") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(bot.referenceAttachmentIds, id: \.self) { AttachmentView(store: store, attachmentID: $0) }
                    }
                }
            }
            InspectorSection(title: "Memory") {
                InspectorRow(symbol: "brain", title: "Memory", meta: "What \(bot.name) remembers, import and export") { open(.memory) }
            }
            InspectorSection(title: "Routines") {
                VStack(spacing: 4) {
                    ForEach(routines) { routine in
                        InspectorRow(symbol: routine.enabled ? "repeat" : "pause.circle", title: routine.name,
                                     meta: routine.enabled ? routine.scheduleDescription : "Paused · \(routine.scheduleDescription)") { open(.routine(routine.id)) }
                    }
                    if routines.isEmpty { Text("No routines for this Bot").font(LBFont.meta).foregroundStyle(LB.faint).padding(.horizontal, 4) }
                }
            }
            InspectorSection(title: "Browse") {
                VStack(spacing: 4) {
                    InspectorRow(symbol: "sparkles", title: "Skills and routines", meta: "Library for every Bot") { open(.skillsLibrary) }
                    InspectorRow(symbol: "square.on.square", title: "Templates", meta: "Start a new Bot from a template") { open(.templates) }
                }
            }
        }
    }
}
