import type { AccessLevel, BotGrant, MachineCapability } from '@lemon-bot/sdk';

// Mirrored in LemonBotUI/Machines/GrantPresentation.swift; wire reasons stay unchanged.
export const accessLabels: Record<AccessLevel, string> = { off: 'Off', read_only: 'View only', read_interact: 'Full' };
export const grantGroups = ['Everyday', 'Control this Mac', 'Connections'] as const;
const names: Record<string, string> = { terminal: 'Terminal', shell: 'Terminal', files: 'Files', browser: 'Browser', computer_use: 'Computer use', accessibility: 'Accessibility', screen_recording: 'Screen Recording', event_synthesizing: 'Event Synthesizing', full_disk_access: 'Full Disk Access', connectors: 'Session connections', x11_desktop: 'X11 desktop automation', desktop: 'Desktop automation' };
export function grantName(id: string, capability?: MachineCapability, connectorName?: string): string {
  return capability?.name || connectorName || names[id] || (id.startsWith('connector:') ? 'Connection' : 'Unavailable capability');
}
export function grantGroup(id: string, capability?: MachineCapability): typeof grantGroups[number] {
  if (capability?.category === 'connector' || id === 'connectors' || id.startsWith('connector:')) return 'Connections';
  if (['terminal', 'shell', 'files', 'browser'].includes(id) || ['shell', 'files', 'browser'].includes(capability?.category ?? '')) return 'Everyday';
  return 'Control this Mac';
}
const messages: Record<string, string> = {
  python3_not_installed: 'Python 3 is not installed — install it on the assigned machine.',
  filesystem_access_disabled_or_denied: 'File access is blocked — check allowed folders and OS permissions on the assigned machine.',
  policy_roots_measured: 'Allowed folders checked; protected folders may still require OS permission.',
  policy_root_unavailable: 'Allowed folders could not be checked — check the machine configuration and refresh.',
  destination_shell_measured: 'Terminal is available on the assigned machine.',
  shell_or_python3_not_installed: 'A shell or Python 3 is missing — install it on the assigned machine.',
  browser_cdp_measured: 'Browser connection checked.',
  browser_executable_measured: 'Browser installation checked.',
  browser_cdp_unavailable: 'Browser connection unavailable — start the configured browser and refresh.',
  browser_executable_not_installed: 'Browser is not installed — install the configured browser on the assigned machine.',
  browser_backend_unavailable_or_not_configured: 'Browser is not ready — configure its backend on the assigned machine.',
  browser_backend_measured: 'Browser backend checked.',
  browser_runtime_not_installed: 'Browser runtime is not installed — install it on the assigned machine.',
  browser_inspection_unavailable: 'Browser status could not be checked — check the machine and refresh.',
  connectors_and_permissions_are_session_scoped: 'Manage each connection and its tools in Connections.',
  computer_use_enabled_per_app_approval: 'Computer use is enabled; each app still needs approval from the helper.',
  computer_use_not_enabled: 'Computer use is not enabled — configure the computer-use helper on the assigned machine.',
  peekaboo_not_installed: 'Desktop control needs Peekaboo — install it on the assigned Mac.',
  macos_grant_measured: 'macOS permission checked.',
  macos_grant_denied: "macOS hasn't allowed this — open Permissions on that Mac.",
  macos_grant_probe_unavailable: "macOS permissions can't be checked until this Mac uses Lemon Bot Worker — open Permissions on that Mac.",
  macos_has_no_nonprompting_full_disk_grant_query: "Full Disk Access can't be checked until this Mac uses Lemon Bot Worker — open Permissions on that Mac.",
  x11_connection_measured: 'Desktop connection checked.',
  xdotool_not_installed: 'Desktop automation needs xdotool — install it on the assigned machine.',
  display_connection_unavailable: 'Desktop connection unavailable — start a graphical session on the assigned machine.',
  unsupported_platform: 'Desktop automation is not supported on this operating system.',
};
export function grantControlReason(id: string, level: AccessLevel, capability?: MachineCapability): string | undefined {
  if (capability?.category === 'os_app' || id === 'connectors') return 'This capability cannot be changed here; configure it on the assigned machine or in Connections.';
  if ((capability?.category === 'shell' || id === 'terminal' || id === 'shell') && level === 'read_only') return 'Terminal can run arbitrary commands; View only cannot be enforced.';
  return undefined;
}
export function pendingGrantStatus(grant: BotGrant): string | null {
  if (grant.pendingLevel === null) return null;
  const rank: Record<AccessLevel, number> = { off: 0, read_only: 1, read_interact: 2 };
  return rank[grant.pendingLevel] > rank[grant.requestedLevel] ? 'Turns on when the current task finishes' : 'Turns off when the current task finishes';
}
export function grantStatus(grant: BotGrant, capability?: MachineCapability): string {
  if (grant.reasons.includes('Tool-policy cutover has not been acknowledged.')) return 'Access changes are not yet confirmed — refresh before making another change.';
  if (grant.reasons.some(reason => reason.startsWith('Local execution is deny;') || reason === 'Workspace, membership or eligible directory group denied product access.')) return 'Limited by workspace policy — ask a workspace administrator to review access.';
  if (capability?.stale && capability.reason !== 'macos_grant_probe_unavailable') return 'Machine measurement is out of date — reconnect the assigned machine and refresh.';
  const reason = grant.reasons[0];
  const message = reason ? messages[reason] : undefined;
  const limited = grant.requestedLevel !== grant.effectiveLevel;
  if (limited && capability?.supported && capability.configuredLevel !== 'off' && (capability.osGrant === 'granted' || capability.osGrant === 'not_required')) return 'Limited by machine configuration — review its configured access and refresh.';
  if (message) return message;
  if (reason?.startsWith('Destination connector discovery')) return limited ? 'Connection access is limited — review its setup and enabled tools in Connections.' : 'Connection tools and credentials checked on the assigned machine.';
  return limited ? 'Access is unavailable — check the assigned machine and workspace policy, then refresh. See Why for details.' : 'See Why for the latest machine and policy details.';
}
