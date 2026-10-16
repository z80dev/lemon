import SwiftUI
import Observation
import LemonBotKit
#if os(iOS)
import UIKit
#endif

// Settings: one calm place for everything that is not messaging. macOS shows a sidebar of panes
// beside the pane content; iOS pushes panes from a grouped list.

public enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case account, devices, instance, providers, machines, apps, library, policies, usage, network, workspace, preferences, platform, about

    public var id: String { rawValue }

    @MainActor public var title: String {
        switch self {
        case .account: "Account"
        case .devices: "Devices"
        case .instance: "Lemon instance"
        case .providers: "Providers"
        case .machines: "Machines"
        case .apps: "Apps & channels"
        case .library: "Library"
        case .policies: "Policies"
        case .usage: "Usage & exports"
        case .network: "Network"
        case .workspace: "Workspace"
        case .preferences: "Preferences"
        case .platform:
            #if os(macOS)
            "This Mac"
            #else
            UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone"
            #endif
        case .about: "About"
        }
    }

    public var symbol: String {
        switch self {
        case .account: "person.crop.circle"
        case .devices: "iphone"
        case .instance: "server.rack"
        case .providers: "key"
        case .machines: "desktopcomputer"
        case .apps: "square.grid.2x2"
        case .library: "books.vertical"
        case .policies: "checkmark.shield"
        case .usage: "chart.bar"
        case .network: "network"
        case .workspace: "briefcase"
        case .preferences: "slider.horizontal.3"
        case .platform:
            #if os(macOS)
            "laptopcomputer"
            #else
            "iphone"
            #endif
        case .about: "info.circle"
        }
    }

    /// System-Settings-style tile color for the pane icon.
    var tint: Color {
        switch self {
        case .account: Color(hex: 0x8A9A5B)
        case .devices: Color(hex: 0x3F6FA3)
        case .instance: Color(hex: 0x5F7847)
        case .providers: Color(hex: 0x5F7847)
        case .machines: Color(hex: 0x5F6B73)
        case .apps: Color(hex: 0x6A5CA8)
        case .library: Color(hex: 0xB0643A)
        case .policies: Color(hex: 0x4F7D55)
        case .usage: Color(hex: 0xA2557A)
        case .network: Color(hex: 0x2F7F8F)
        case .workspace: Color(hex: 0x7A6A3A)
        case .preferences: Color(hex: 0x6E766B)
        case .platform: Color(hex: 0x3C6248)
        case .about: Color(hex: 0x8E8E86)
        }
    }

    var summary: String {
        switch self {
        case .account: "Your profile, saved accounts and sign-in."
        case .devices: "Connect a phone and manage devices signed in to your account."
        case .instance: "The attached Lemon, its service and lifecycle controls."
        case .providers: "Manage sign-in and the default on your execution target."
        case .machines: "The computers your Bots work on."
        case .apps: "Connected apps, channels, email and X."
        case .library: "Skills, routines, templates and Bot memory."
        case .policies: "What Bots may do on their own and when they ask first."
        case .usage: "Spend and limits, plus exports of your data."
        case .network: "Outbound network rules for Bot work."
        case .workspace: "Workspace name, Bot sections, providers and cleanup."
        case .preferences: "Appearance, notifications, voice and accessibility."
        case .platform:
            #if os(macOS)
            "Shortcuts, microphone and voice on this Mac."
            #else
            "Settings that apply only to this device."
            #endif
        case .about: "Client version, compatibility and safe diagnostics."
        }
    }
}

/// Lets any surface open Settings on a specific pane before presenting it.
@MainActor @Observable public final class SettingsRouter {
    public static let shared = SettingsRouter()
    public var pane: SettingsPane = .account
    public init() {}
}

public struct LemonBotSettingsView<Platform: View>: View {
    private let store: LemonBotStore
    private let platform: Platform
    private let router = SettingsRouter.shared
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @State private var path: [SettingsPane] = []
    #endif

    public init(store: LemonBotStore, @ViewBuilder platform: () -> Platform) {
        self.store = store
        self.platform = platform()
    }

    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { ($0 != .platform || !(Platform.self is EmptyView.Type)) && ($0 != .providers || store.member?.role == "owner") }
    }

    @ViewBuilder private func content(_ pane: SettingsPane) -> some View {
        switch pane {
        case .account: AccountPane(store: store)
        case .devices: DevicesPane(store: store)
        case .instance: InstanceSettingsView(store: store)
        case .providers: ProvidersSettingsView(store: store)
        case .machines: MachineHubView(store: store)
        case .apps: IntegrationsHubView(store: store)
        case .library: LibraryHubView(store: store)
        case .policies: PolicySettingsView(store: store)
        case .usage: UsagePane(store: store)
        case .network: NetworkSettingsView(store: store)
        case .workspace: WorkspacePane(store: store)
        case .preferences: PreferencesPane(store: store)
        case .platform: platform
        case .about: AboutSettingsView(store: store)
        }
    }

    #if os(macOS)
    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SettingsAccountHeader(store: store).padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
                List(selection: Binding<SettingsPane?>(get: { router.pane }, set: { if let value = $0 { router.pane = value } })) {
                    ForEach(panes) { pane in
                        HStack(spacing: 8) {
                            Label { Text(pane.title).lineLimit(1) } icon: { SettingsPaneIcon(pane: pane) }
                            if pane == .workspace, !store.pendingIntents.isEmpty {
                                Spacer(minLength: 4)
                                LabelChip(text: "\(store.pendingIntents.count)", tint: LB.warning)
                                    .accessibilityLabel("\(store.pendingIntents.count) pending actions")
                            }
                        }.tag(pane)
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            .background(LB.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 236, max: 280)
        } detail: {
            ZStack {
                // Keep the editable Preferences navigation stack alive between pane switches.
                NavigationStack { macPane(.preferences) }
                    .opacity(router.pane == .preferences ? 1 : 0)
                    .allowsHitTesting(router.pane == .preferences)
                    .accessibilityHidden(router.pane != .preferences)
                NavigationStack { macPane(.platform) }
                    .opacity(router.pane == .platform ? 1 : 0)
                    .allowsHitTesting(router.pane == .platform)
                    .accessibilityHidden(router.pane != .platform)
                if router.pane != .preferences && router.pane != .platform {
                    NavigationStack { macPane(router.pane) }.id(router.pane)
                }
            }
        }
        .frame(minWidth: 780, minHeight: 540)
    }

    private func macPane(_ pane: SettingsPane) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pane.title).font(LBFont.title).foregroundStyle(LB.ink).accessibilityAddTraits(.isHeader)
                Text(pane.summary).font(LBFont.rowSubtitle).foregroundStyle(LB.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 6)
            // Text-style buttons keep embedded admin screens calm instead of rows of grey bezels.
            content(pane).buttonStyle(.borderless)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .background(LB.canvas)
        .navigationTitle(pane.title)
    }
    #else
    public var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: SettingsPane.account) { SettingsAccountHeader(store: store) }
                        .accessibilityHint("Opens account settings")
                }
                Section {
                    ForEach(panes.filter { $0 != .account }) { pane in
                        NavigationLink(value: pane) {
                            HStack {
                                Label { Text(pane.title) } icon: { SettingsPaneIcon(pane: pane) }
                                if pane == .workspace, !store.pendingIntents.isEmpty {
                                    Spacer(minLength: 4)
                                    LabelChip(text: "\(store.pendingIntents.count)", tint: LB.warning)
                                        .accessibilityLabel("\(store.pendingIntents.count) pending actions")
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(LB.canvas)
            .navigationTitle("Settings")
            .toolbar {
                if isPresented { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .navigationDestination(for: SettingsPane.self) { pane in
                content(pane)
                    .scrollContentBackground(.hidden)
                    .formStyle(.grouped)
                    .background(LB.canvas)
                    .navigationTitle(pane.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .onAppear { if router.pane != .account { path = [router.pane] } }
        .onChange(of: router.pane) { _, pane in if pane != .account, path.last != pane { path = [pane] } }
        .onChange(of: path) { _, value in if value.isEmpty { router.pane = .account } }
    }
    #endif
}

extension LemonBotSettingsView where Platform == EmptyView {
    public init(store: LemonBotStore) { self.init(store: store) { EmptyView() } }
}

// MARK: - Shared pieces

private struct SettingsAccountHeader: View {
    let store: LemonBotStore
    private var name: String { store.user?.displayName ?? store.account?.displayName ?? "Not signed in" }
    private var email: String? { store.user?.email ?? store.account?.email }
    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        return letters.isEmpty ? "L" : letters
    }
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(LB.lemon).frame(width: 40, height: 40)
                .overlay(Text(initials).font(LBFont.bodyEmphasis).foregroundStyle(LB.lemonInk))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(LBFont.rowTitle).foregroundStyle(LB.ink).lineLimit(1)
                if let email { Text(email).font(LBFont.meta).foregroundStyle(LB.muted).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Small rounded tile with a white glyph, like System Settings.
struct SettingsPaneIcon: View {
    let pane: SettingsPane
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: pane.symbol)
            .font(LBFont.metaEmphasis)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(pane.tint.gradient))
            .accessibilityHidden(true)
    }
}

/// A navigation row with a one-line muted explanation, used by panes that gather several screens.
private struct SettingsIndexRow<Destination: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var destination: Destination
    var body: some View {
        NavigationLink {
            destination
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(LBFont.body).foregroundStyle(LB.ink)
                    Text(subtitle).font(LBFont.meta).foregroundStyle(LB.muted)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(LB.accent)
            }
        }
    }
}

// MARK: - Panes

private struct AccountPane: View {
    let store: LemonBotStore
    @State private var action = UIActionState()
    @State private var addAccount = false
    @State private var deferredAccountChange = false
    @State private var confirmSignOut = false
    private var name: String { store.user?.displayName ?? store.account?.displayName ?? "this account" }
    var body: some View {
        Form {
            Section {
                SettingsAccountHeader(store: store).padding(.vertical, 4)
            }
            if store.accounts.count > 1 {
                Section("Accounts on this device") {
                    ForEach(store.accounts) { account in
                        let current = account.id == store.account?.id
                        Button {
                            Task { await action.perform { try await store.restoreAccount(account) } }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(account.displayName).font(LBFont.body).foregroundStyle(LB.ink)
                                    Text("\(account.email) · \(account.baseURL.host ?? account.baseURL.absoluteString)").font(LBFont.meta).foregroundStyle(LB.muted)
                                }
                                Spacer()
                                if current { Image(systemName: "checkmark").foregroundStyle(LB.accent).accessibilityLabel("Current account") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(current || action.busy)
                    }
                }
            }
            Section {
                SettingsIndexRow(title: "Profile, password and sessions", subtitle: "Name, email, password, signed-in sessions and account deletion.", symbol: "person.text.rectangle") { AccountSettingsView(store: store) }
                Button { addAccount = true } label: { Label("Add another account or backend", systemImage: "plus.circle") }
                Button { Task { await action.perform { try await store.refresh() } } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(action.busy || store.account == nil)
            }
            Section {
                Button(role: .destructive) { confirmSignOut = true } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                    .disabled(action.busy || store.account == nil)
            }
            if action.error != nil || store.errorMessage != nil {
                Section { ActionErrorView(message: action.error ?? store.errorMessage) }
            }
        }
        .sheet(isPresented: $addAccount) { OnboardingView(store: store) }
        .onChange(of: store.account?.id) { _, _ in
            if store.pairingState == "completing" { deferredAccountChange = true }
            else { addAccount = false }
        }
        .onChange(of: store.pairingState) { _, state in
            if state != "completing", deferredAccountChange {
                deferredAccountChange = false
                addAccount = false
            }
        }
        .confirmationDialog("Sign out of \(name)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await action.perform { try await store.signOut() } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to sign in again to use this account on this device.")
        }
    }
}

private struct DevicesPane: View {
    let store: LemonBotStore
    @State private var control = AdminControl()
    @State private var devices: [Device] = []
    @State private var showPairing = false
    private var needsReconnect: Bool {
        store.account == nil || store.connectionState == "reconnect_required" || store.pendingPairing != nil || !["idle", "connected"].contains(store.pairingState)
    }
    var body: some View {
        Form {
            #if os(macOS)
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Connect iPhone", systemImage: "iphone.gen3").font(LBFont.bodyEmphasis).foregroundStyle(LB.ink)
                    Text("Create a one-use QR code here, scan it with Lemon Bot on your iPhone, then compare the two verification codes before approving. No password is shared, and the code expires in five minutes.")
                        .font(LBFont.rowSubtitle).foregroundStyle(LB.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Connect iPhone") { showPairing = true }
                        .buttonStyle(.lemonPrimary).disabled(store.connectionState != "online")
                }.padding(.vertical, 6)
            }
            #else
            if needsReconnect {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Reconnect to your desktop", systemImage: "desktopcomputer").font(LBFont.bodyEmphasis).foregroundStyle(LB.ink)
                        Text("Scan the one-use QR from Connect iPhone on your Mac, check the backend, then request the connection. No desktop password is needed.")
                            .font(LBFont.rowSubtitle).foregroundStyle(LB.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Reconnect to your desktop") { showPairing = true }.buttonStyle(.lemonPrimary)
                    }.padding(.vertical, 6)
                }
            } else {
                Section {
                    Button { showPairing = true } label: { Label("Reconnect to your desktop", systemImage: "desktopcomputer") }
                } footer: { Text("Only needed if this phone lost its connection to your desktop.") }
            }
            #endif
            Section("Registered devices") {
                ForEach(devices) { device in
                    DeviceSettingsRow(store: store, device: device) { try await loadDevices() }
                }
                if devices.isEmpty { Text("No registered devices yet.").foregroundStyle(LB.muted) }
            }
            Section {
                SettingsIndexRow(title: "Sessions and password", subtitle: "See where you are signed in and revoke sessions.", symbol: "lock.rotation") { AccountSettingsView(store: store) }
                Button { Task { await control.perform { try await loadDevices() } } } label: { Label("Refresh devices", systemImage: "arrow.clockwise") }
                    .disabled(control.busy)
            }
            if let error = control.error { Section { ActionErrorView(message: error) } }
        }
        .task { await control.perform { try await loadDevices() } }
        #if os(macOS)
        .sheet(isPresented: $showPairing) { OwnerPairingView(store: store) }
        #else
        .sheet(isPresented: $showPairing) {
            NavigationStack { PhonePairingView(store: store).toolbar { Button("Close") { showPairing = false } } }
        }
        #endif
    }
    private func loadDevices() async throws { devices = try await adminReadAll(store, "/devices", as: Device.self) }
}

private struct UsagePane: View {
    let store: LemonBotStore
    var body: some View {
        Form {
            Section {
                SettingsIndexRow(title: "Usage and spend limits", subtitle: "What your Bots have used and the limits that apply.", symbol: "chart.bar") { UsageSettingsView(store: store) }
                SettingsIndexRow(title: "Exports and content consent", subtitle: "Export audit, action, usage and conversation data.", symbol: "square.and.arrow.up") { ExportSettingsView(store: store) }
            }
        }
    }
}

private struct WorkspacePane: View {
    let store: LemonBotStore
    @State private var organize = false
    var body: some View {
        Form {
            if !store.pendingIntents.isEmpty {
                Section {
                    SettingsIndexRow(title: "Pending unconfirmed actions", subtitle: "\(store.pendingIntents.count) waiting to be reconciled.", symbol: "exclamationmark.circle") { PendingIntentView(store: store) }
                }
            }
            Section {
                SettingsIndexRow(title: "Workspace name and timezone", subtitle: "How this workspace is named and when its days start.", symbol: "briefcase") { WorkspaceSettingsView(store: store) }
                Button { organize = true } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Organize Bots").font(LBFont.body).foregroundStyle(LB.ink)
                            Text("Create, rename, reorder and delete sidebar sections.").font(LBFont.meta).foregroundStyle(LB.muted)
                        }
                    } icon: { Image(systemName: "rectangle.3.group").foregroundStyle(LB.accent) }
                }
                SettingsIndexRow(title: "Provider catalog", subtitle: "Exact setup prerequisites for each provider.", symbol: "server.rack") { ProviderCatalogView(store: store) }
                if store.member?.role == "owner" {
                    SettingsIndexRow(title: "Account cleanup observations", subtitle: "Read-only status of account deletion cleanup.", symbol: "trash.slash") { AccountCleanupSettingsView(store: store) }
                }
            }
        }
        .sheet(isPresented: $organize) { SectionEditorView(store: store) }
    }
}

private struct PreferencesPane: View {
    let store: LemonBotStore
    var body: some View {
        Form {
            Section {
                SettingsIndexRow(title: "Appearance, notifications and voice", subtitle: "Theme, language, alerts and spoken replies.", symbol: "paintbrush") { PreferencesSettingsView(store: store) }
                SettingsIndexRow(title: "Local companion and accessibility", subtitle: "Shortcuts, companion and reduced motion on this device.", symbol: "accessibility") { LocalSettingsView(store: store) }
            }
        }
    }
}
