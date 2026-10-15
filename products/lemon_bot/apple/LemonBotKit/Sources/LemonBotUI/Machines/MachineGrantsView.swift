import SwiftUI
import LemonBotKit

struct MachineBotGrantsView: View {
    let store: LemonBotStore
    let bot: Bot
    @State private var grants: [BotGrant] = []
    @State private var cursor: String?
    @State private var action = HubAction()
    private var canManage: Bool { bot.ownerUserId == store.user?.id }
    var body: some View {
        DisclosureGroup("\(bot.name) · requested vs effective authorization") {
            HubError(action: action, store: store)
            ForEach(grants) { grant in
                VStack(alignment: .leading) {
                    Text(grant.capabilityId).font(.headline)
                    Text("Requested \(grant.requestedLevel) · effective \(grant.effectiveLevel)")
                    ForEach(grant.reasons, id: \.self) { Text($0).font(.caption) }
                    if canManage {
                        Menu("Set requested access") {
                            ForEach(["off", "read_only", "read_interact"], id: \.self) { level in
                                Button(level) { Task { await action.perform {
                                    let current: BotGrant = try await store.mutate("PATCH", "/bots/\(hubID(bot.id))/grants/\(hubID(grant.id))", body: ["revision": .number(Double(grant.revision)), "requestedLevel": .string(level)])
                                    if let index = grants.firstIndex(where: { $0.id == current.id }) { grants[index] = current }
                                } } }
                            }
                        }.disabled(action.busy || action.uncertain || store.connectionState != "online")
                    }
                }
            }
            if cursor != nil { Button("More grants") { Task { await load(more: true) } } }
            Button("Refresh effective grants") { Task { await load() } }
            Text("Requested access cannot exceed the measured machine capability, actual OS permission or required policy. Unsupported native policy mapping is reported by the backend, not a cosmetic permission switch.").font(.caption)
        }.task { await load() }
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) {
        let page: Page<BotGrant> = try await store.read("/bots/\(hubID(bot.id))/grants", query: more ? ["cursor": cursor ?? ""] : [:]); grants = hubMerged(grants, page.items, append: more, id: \.id); cursor = page.nextCursor
    } }
}
