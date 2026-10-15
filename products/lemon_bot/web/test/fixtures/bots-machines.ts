import type { Bot, BotTemplate, ChannelBinding, HostInfo, HostOperation, Memory, RealtimeServerFrame, Terminal, XProviderInfo } from '@lemon-bot/sdk';
import type { AppContextValue, Route } from '../../src/app';

const resource = { revision: 1, createdAtMs: 1800000000000, updatedAtMs: 1800000000000 };
export const machine = { ...resource, id: 'machine_test', nodeId: 'node_test', nodeName: 'studio', name: 'Studio Mac', ownerUserId: 'owner', accessUserIds: [], status: 'online' as const, lastSeenAtMs: resource.updatedAtMs, labels: {}, botIds: ['bot_test'] };
export const bot: Bot = { ...resource, id: 'bot_test', ownerUserId: 'owner', machineId: machine.id, profileId: 'profile_test', name: 'Research partner', title: 'Research', job: 'Find reliable sources.', instructions: 'Ask before sharing.', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'conversation_test', sidebar: { sectionId: null, rank: 0, hidden: false, pinned: false, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] };
export const memory: Memory = { ...resource, id: 'memory_test', botId: bot.id, kind: 'preference', text: 'Include sources in research briefs.', sourceEntryId: 'entry_opaque_reference' };
export const template: BotTemplate = { ...resource, id: 'template_opaque_reference', ownerUserId: 'publisher', audience: 'public', sourceBotId: null, content: { name: 'Research partner', title: 'Research', job: bot.job, instructions: bot.instructions, avatar: bot.avatar, voice: bot.voice, skills: [], routines: [], connectorNames: [] }, provenance: { publisher: 'Community publisher', sourceUrl: 'https://example.com/source', termsUrl: 'https://example.com/terms', thirdParty: true }, shareUrl: 'https://example.com/template' };
export const host: HostInfo = { hostname: 'studio', os: 'macOS', osVersion: '26', arch: 'arm64', cpuCount: 10, memTotalBytes: 16000000000, memFreeBytes: 8000000000, diskTotalBytes: 1000000000000, diskFreeBytes: 500000000000, uptimeSec: 3600, lemonVersion: '2026.10', defaultCwd: '/Users/test/projects', user: 'test', measuredAtMs: resource.updatedAtMs };
export const binding: ChannelBinding = { ...resource, id: 'binding_test', botId: bot.id, ownerUserId: 'owner', adapter: 'slack', accountId: 'Research', target: '#research', enabled: true, state: 'connected', capabilities: { inbound: true, outbound: false, events: [] }, lastError: null };
export const xProvider: XProviderInfo = { id: 'x', kind: 'x', label: 'X', configured: false, publicHandle: '@researchbot', oauthScopes: [], allowedMedia: ['photo'], deniedCountries: [], capabilities: [], prerequisites: [] };
export const terminal: Terminal = { ...resource, id: 'terminal_test', machineId: machine.id, userId: 'owner', deviceId: 'device_test', cwd: host.defaultCwd, cols: 100, rows: 30, state: 'open', exitCode: null };
export const operation: HostOperation = { ...resource, id: 'operation_test', action: 'update', ownerUserId: 'owner', state: 'running', results: ['succeeded', 'failed', 'skipped', 'queued', 'running', 'outcome_unknown'].map((state, i) => ({ machineId: `target_${i}`, state: state as HostOperation['results'][number]['state'], reason: null })) };

export const calls: { endpoint: string; options: unknown }[] = [];
export const navigations: Route[] = [];
export const listeners = new Set<(frame: RealtimeServerFrame) => void>();
export const responses = new Map<string, unknown>();
// These screens consume only this subset of workspace context; no backend runs in UI tests.
export const app = {
  online: true,
  device: { id: 'device_test' },
  snapshot: { user: { id: 'owner' }, workspace: { id: 'workspace_test', ownerUserId: 'owner' }, bots: [bot], machines: [machine], capabilities: { imageGeneration: false } },
  client: { call: async (endpoint: string, options: unknown) => {
    calls.push({ endpoint, options });
    if (!responses.has(endpoint)) throw new Error(`Unexpected test endpoint: ${endpoint}`);
    const response = responses.get(endpoint);
    if (response instanceof Error) throw response;
    return response;
  } },
  realtime: { subscribe: (listener: (frame: RealtimeServerFrame) => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; }, send: () => undefined },
  navigate: (route: Route) => { navigations.push(route); },
  reportError: (error: unknown) => { throw error; },
} as unknown as AppContextValue;
export function useApp() { return app; }
export function resetFixtures() {
  calls.length = 0; navigations.length = 0; listeners.clear(); responses.clear(); app.online = true;
  const page = (items: unknown[]) => ({ items, nextCursor: null });
  for (const [endpoint, value] of Object.entries({
    'GET /machines/:id': machine,
    'GET /machines/:id/host': host,
    'GET /machines/:id/capabilities': { machineId: machine.id, os: host.os, measuredAtMs: host.measuredAtMs, stale: false, items: [] },
    'GET /machines': page([machine]),
    'GET /bots': page([bot]),
    'GET /bots/:id': bot,
    'GET /bots/:id/memory': page([memory]),
    'GET /entries/:id': { id: memory.sourceEntryId, conversationId: bot.mainConversationId },
    'GET /templates': page([template]),
    'GET /templates/:id': template,
    'GET /policies': { publicTemplates: true },
    'GET /channels': page([binding]),
    'GET /channels/providers': [],
    'GET /channels/principal-links': page([]),
    'GET /x/provider': xProvider,
    'GET /x/connections': page([]),
    'GET /terminals/:id': terminal,
    'GET /machines/:id/files': page([]),
    'GET /machines/:id/management': { machineId: machine.id, supportedActions: ['update'], provider: 'launchd', environmentRoot: null, lastBackupAtMs: null, supportsNetworkPolicy: false, supportsEgress: false, supportsSetup: false },
    'GET /host-operations': page([operation]),
    'GET /host-operations/:id': operation,
  })) responses.set(endpoint, value);
}
resetFixtures();
