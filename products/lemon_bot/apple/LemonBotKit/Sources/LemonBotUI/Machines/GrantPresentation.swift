import LemonBotKit

// Mirrored in web/src/features/bots/grant-presentation.ts; wire reasons stay unchanged.
enum GrantPresentation {
    static let levels = ["off", "read_only", "read_interact"]
    static let groups = ["Everyday", "Control this Mac", "Connections"]
    static func label(_ level: String) -> String {
        switch level { case "read_only": return "View only"; case "read_interact": return "Full"; default: return "Off" }
    }
    static let names = ["terminal": "Terminal", "shell": "Terminal", "files": "Files", "browser": "Browser", "computer_use": "Computer use", "accessibility": "Accessibility", "screen_recording": "Screen Recording", "event_synthesizing": "Event Synthesizing", "full_disk_access": "Full Disk Access", "connectors": "Session connections", "x11_desktop": "X11 desktop automation", "desktop": "Desktop automation"]
    static func name(_ id: String, _ capability: MachineCapability?, connectorName: String? = nil) -> String {
        if let name = capability?.name, !name.isEmpty { return name }
        return connectorName ?? names[id] ?? (id.hasPrefix("connector:") ? "Connection" : "Unavailable capability")
    }
    static func group(_ id: String, _ capability: MachineCapability?) -> String {
        if capability?.category == "connector" || id == "connectors" || id.hasPrefix("connector:") { return "Connections" }
        if ["terminal", "shell", "files", "browser"].contains(id) || ["shell", "files", "browser"].contains(capability?.category ?? "") { return "Everyday" }
        return "Control this Mac"
    }
    static let messages = [
        "python3_not_installed": "Python 3 is not installed — install it on the assigned machine.",
        "filesystem_access_disabled_or_denied": "File access is blocked — check allowed folders and OS permissions on the assigned machine.",
        "policy_roots_measured": "Allowed folders checked; protected folders may still require OS permission.",
        "policy_root_unavailable": "Allowed folders could not be checked — check the machine configuration and refresh.",
        "destination_shell_measured": "Terminal is available on the assigned machine.",
        "shell_or_python3_not_installed": "A shell or Python 3 is missing — install it on the assigned machine.",
        "browser_cdp_measured": "Browser connection checked.",
        "browser_executable_measured": "Browser installation checked.",
        "browser_cdp_unavailable": "Browser connection unavailable — start the configured browser and refresh.",
        "browser_executable_not_installed": "Browser is not installed — install the configured browser on the assigned machine.",
        "browser_backend_unavailable_or_not_configured": "Browser is not ready — configure its backend on the assigned machine.",
        "browser_backend_measured": "Browser backend checked.",
        "browser_runtime_not_installed": "Browser runtime is not installed — install it on the assigned machine.",
        "browser_inspection_unavailable": "Browser status could not be checked — check the machine and refresh.",
        "connectors_and_permissions_are_session_scoped": "Manage each connection and its tools in Connections.",
        "computer_use_enabled_per_app_approval": "Computer use is enabled; each app still needs approval from the helper.",
        "computer_use_not_enabled": "Computer use is not enabled — configure the computer-use helper on the assigned machine.",
        "peekaboo_not_installed": "Desktop permission checks need Peekaboo — install it on the assigned Mac.",
        "peekaboo_grant_measured": "macOS permission checked.",
        "peekaboo_grant_denied": "macOS has not allowed this capability — review it in System Settings → Privacy & Security on the assigned Mac.",
        "peekaboo_grant_inspection_unavailable": "macOS permission could not be checked — review Privacy & Security on the assigned Mac, then refresh.",
        "macos_has_no_nonprompting_full_disk_grant_query": "Full Disk Access cannot be checked automatically — review Privacy & Security on the assigned Mac.",
        "x11_connection_measured": "Desktop connection checked.",
        "xdotool_not_installed": "Desktop automation needs xdotool — install it on the assigned machine.",
        "display_connection_unavailable": "Desktop connection unavailable — start a graphical session on the assigned machine.",
        "unsupported_platform": "Desktop automation is not supported on this operating system."
    ]
    static func controlReason(_ id: String, _ level: String, _ capability: MachineCapability?) -> String? {
        if capability?.category == "os_app" || id == "connectors" { return "This capability cannot be changed here; configure it on the assigned machine or in Connections." }
        if (capability?.category == "shell" || id == "terminal" || id == "shell") && level == "read_only" { return "Terminal can run arbitrary commands; View only cannot be enforced." }
        return nil
    }
    static func status(_ grant: BotGrant, _ capability: MachineCapability?) -> String {
        if grant.reasons.contains("Tool-policy cutover has not been acknowledged.") { return "Access changes are not yet confirmed — refresh before making another change." }
        if grant.reasons.contains(where: { $0.hasPrefix("Local execution is deny;") || $0 == "Workspace, membership or eligible directory group denied product access." }) { return "Limited by workspace policy — ask a workspace administrator to review access." }
        if capability?.stale == true { return "Machine measurement is out of date — reconnect the assigned machine and refresh." }
        let limited = grant.requestedLevel != grant.effectiveLevel
        if limited, let capability, capability.supported, capability.configuredLevel != "off", ["granted", "not_required"].contains(capability.osGrant) { return "Limited by machine configuration — review its configured access and refresh." }
        if let reason = grant.reasons.first, let message = messages[reason] { return message }
        if grant.reasons.first?.hasPrefix("Destination connector discovery") == true {
            return limited ? "Connection access is limited — review its setup and enabled tools in Connections." : "Connection tools and credentials checked on the assigned machine."
        }
        return limited ? "Access is unavailable — check the assigned machine and workspace policy, then refresh. See Why for details." : "See Why for the latest machine and policy details."
    }
}
