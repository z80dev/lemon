import SwiftUI
import LemonBotKit

struct MachineBotGrantsView: View {
    let store: LemonBotStore
    let bot: Bot
    @State private var grants: [BotGrant] = []
    @State private var capabilities: MachineCapabilities?
    @State private var connectors: [Connector] = []
    @State private var cursor: String?
    @State private var action = HubAction()
    private var canManage: Bool { bot.ownerUserId == store.user?.id }
    var body: some View {
        DisclosureGroup("\(bot.name) · Bot access") {
            HubError(action: action, store: store)
            ForEach(GrantPresentation.groups, id: \.self) { group in
                let items = grants.filter { GrantPresentation.group($0.capabilityId, capability($0)) == group }
                if !items.isEmpty {
                    if group == "Control this Mac" {
                        DisclosureGroup(group) { ForEach(items) { grantRow($0) } }
                    } else {
                        Text(group).font(.headline)
                        ForEach(items) { grantRow($0) }
                    }
                }
            }
            if cursor != nil { Button("More grants") { Task { await load(more: true) } } }
            Button("Refresh access") { Task { await load() } }.disabled(action.busy)
            DisclosureGroup("Why") {
                Text("Machine configuration, OS permissions and workspace policy can narrow access. A Bot persona is not an OS sandbox. Terminal and browser evaluation can reach other host resources. Granting access does not remove required approvals.").font(LBFont.meta)
                ForEach(grants) { grant in
                    Text("\(name(grant)): \(grant.capabilityId) — \(grant.reasons.first ?? "")").font(LBFont.meta)
                }
                ForEach(Array(Set(grants.flatMap(\.reasons))).sorted(), id: \.self) { Text($0).font(LBFont.meta) }
            }
        }.task(id: bot.id) { await load() }
    }
    private func capability(_ grant: BotGrant) -> MachineCapability? {
        capabilities?.items.first { $0.id == grant.capabilityId }
    }
    private func name(_ grant: BotGrant) -> String {
        GrantPresentation.name(grant.capabilityId, capability(grant), connectorName: connectors.first { "connector:\($0.id)" == grant.capabilityId }?.name)
    }
    private func grantRow(_ grant: BotGrant) -> some View {
        let measured = capability(grant)
        let title = name(grant)
        let limited = grant.requestedLevel != grant.effectiveLevel
        let restrictions = Array(Set(GrantPresentation.levels.compactMap { GrantPresentation.controlReason(grant.capabilityId, $0, measured) })).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(spacing: 0) {
                ForEach(GrantPresentation.levels, id: \.self) { level in
                    Button {
                        Task { await action.perform {
                            let current: BotGrant = try await store.mutate("PATCH", "/bots/\(hubID(bot.id))/grants/\(hubID(grant.id))", body: ["revision": .number(Double(grant.revision)), "requestedLevel": .string(level)])
                            if let index = grants.firstIndex(where: { $0.id == current.id }) { grants[index] = current }
                        } }
                    } label: {
                        Text(GrantPresentation.label(level)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(grant.requestedLevel == level ? Color.accentColor : Color.secondary)
                    .accessibilityLabel("\(title): \(GrantPresentation.label(level))")
                    .accessibilityAddTraits(grant.requestedLevel == level ? [.isSelected] : [])
                    .help(GrantPresentation.controlReason(grant.capabilityId, level, measured) ?? "Set \(title) access")
                    .disabled(!canManage || action.busy || action.uncertain || store.connectionState != "online" || GrantPresentation.controlReason(grant.capabilityId, level, measured) != nil)
                }
            }
            Text((limited ? "Requested \(GrantPresentation.label(grant.requestedLevel)); currently \(GrantPresentation.label(grant.effectiveLevel)). " : "") + GrantPresentation.status(grant, measured))
                .font(LBFont.meta)
                .foregroundStyle(limited ? Color.orange : Color.secondary)
            ForEach(restrictions, id: \.self) { Text($0).font(LBFont.meta).foregroundStyle(.secondary) }
        }.padding(.vertical, 8)
    }
    private func load(more: Bool = false) async { await action.perform(readOnly: true) {
        let page: Page<BotGrant> = try await store.read("/bots/\(hubID(bot.id))/grants", query: more ? ["cursor": cursor ?? ""] : [:]); grants = hubMerged(grants, page.items, append: more, id: \.id); cursor = page.nextCursor
        if !more {
            capabilities = try await store.read("/machines/\(hubID(bot.machineId))/capabilities")
            var items: [Connector] = []
            var next: String?
            repeat {
                let connections: Page<Connector> = try await store.read("/bots/\(hubID(bot.id))/connectors", query: next.map { ["cursor": $0] } ?? [:])
                items.append(contentsOf: connections.items)
                next = connections.nextCursor
            } while next != nil
            connectors = items
        }
    } }
}
