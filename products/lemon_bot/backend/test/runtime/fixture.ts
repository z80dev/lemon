import { expect } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { installHelpers } from '../../src/core/helpers';
import { createEventService } from '../../src/core/events';
import { createMutationService } from '../../src/core/mutations';
import { ApiError } from '../../src/core/errors';
import type { ConnectedLemonService } from '../../src/runtime/lemon';
import { productBotTools } from '../../src/core/bots';
import type { MachineRuntimeFeatures } from '../../src/runtime/machines';

// Captured from the authenticated owning mcp.execution_names RPC for https://product.example/mcp.
const nativeProductTools: { name: keyof P.MCPToolInputs; executionName: string }[] = [
  { name: 'message_bot', executionName: 'mcp_lemon_bot_message_bot_e27f8366c893fc7d4ace784f51ce12a1' },
  { name: 'handoff', executionName: 'mcp_lemon_bot_handoff_9f74e5f82ed019f6a9084a1daa468386' },
  { name: 'create_draft', executionName: 'mcp_lemon_bot_create_draft_6e65809e9170b8c9b3cb0da09b714275' },
  { name: 'ask_user', executionName: 'mcp_lemon_bot_ask_user_10d4fd7a91be9332225ab7a9f47f9f2f' },
  { name: 'request_approval', executionName: 'mcp_lemon_bot_request_approval_ca54a9645adf9ba042f0e53146a13ee0' },
  { name: 'request_human_step', executionName: 'mcp_lemon_bot_request_human_ste_688cee41cf6bff126499b440c3a8624c' },
  { name: 'request_secret', executionName: 'mcp_lemon_bot_request_secret_c5d5dd62ffb1c7cd4ebdaf58ee1da740' },
  { name: 'send_voice_memo', executionName: 'mcp_lemon_bot_send_voice_memo_94b772ea7c8f891201c61ad1c1a26482' },
  { name: 'share_file', executionName: 'mcp_lemon_bot_share_file_768d74587235feb2e85ef683d4558c37' },
  { name: 'create_routine', executionName: 'mcp_lemon_bot_create_routine_480cfac22f6df0d89908d166b1e80b6f' },
  { name: 'update_routine', executionName: 'mcp_lemon_bot_update_routine_9243c6d1a2783406bed605d7ddf21a9d' },
  { name: 'save_skill', executionName: 'mcp_lemon_bot_save_skill_ce8a3dbeea117002d1ccc85b12353fb5' },
  { name: 'list_bots', executionName: 'mcp_lemon_bot_list_bots_151a36bf63151717e5c7dcf2f76752f2' },
  { name: 'post_to_group', executionName: 'mcp_lemon_bot_post_to_group_f9eeb76c647b0739da6629d63799e809' },
  { name: 'remember', executionName: 'mcp_lemon_bot_remember_88ac13cb8401ab72fbc6e5caeaedf539' },
  { name: 'create_bot', executionName: 'mcp_lemon_bot_create_bot_4a92e9bba45de6978e230abb443d9321' },
  { name: 'update_preferences', executionName: 'mcp_lemon_bot_update_preference_f55d35c688fc2ca9a6d77f7bb3c75d94' },
  { name: 'create_reminder', executionName: 'mcp_lemon_bot_create_reminder_d1a7af45016ffbce56b89af97037eae8' },
];
export function productExecutionProjection() {
  return { server: { name: 'lemon-bot' }, tools: nativeProductTools.map(tool => ({ ...tool })), count: nativeProductTools.length };
}


export function compatibleFeatures(nodeId: string): MachineRuntimeFeatures {
  const capabilities: P.JSONObject = {
    'coding_agent.run': { version: 1, nativePrivacyContext: { version: 1 } },
    'node.invoke.event': { version: 1, maxBytes: 65_536 },
    'node.invoke.control': { version: 1, operations: ['steer', 'redirect'], maxTextBytes: 16_384 },
    'node.invoke.cancel': true,
    'node.enrollment': { version: 1, repairInvites: true },
  };
  for (const method of ['node.host.info', 'node.capabilities.get', 'node.runtime.features', 'node.fs.list', 'node.fs.stat', 'node.fs.read', 'node.fs.write', 'node.fs.mkdir', 'node.fs.move', 'node.fs.delete.preview', 'node.fs.delete', 'node.secrets.set', 'node.secrets.list', 'node.secrets.delete', 'node.secrets.receipt', 'node.shell.open', 'node.shell.input', 'node.shell.resize', 'node.shell.close', 'node.mcp.discover', 'node.profile.sync', 'node.profile.sync.status', 'node.profile.paths']) capabilities[method] = true;
  return { nodeId, protocol: 1, lemonVersion: 'fixture', methods: Object.keys(capabilities).filter(method => method !== 'node.enrollment').sort(), features: { hostIO: true, filesystemCAS: true, deletePreviews: true, encryptedSecrets: true, ptyShell: true, mcpDiscovery: true, profileSync: true, liveStreaming: true, repairInvites: true, nativeExecutionPolicy: true }, botReady: true, missingFeatures: [], capabilities, nativePrivacyContext: { version: 1 } };
}
export interface TestRuntimeFixture {
  services: BackendServices;
  store: Store;
  alice: Principal;
  bob: Principal;
  machine: P.Machine;
  bot: P.Bot;
  conversation: P.Conversation;
  calls: { method: string; params: Record<string, unknown>; mutation: boolean }[];
  rpc: (method: string, params: Record<string, unknown>) => Promise<unknown>;
  emit(event: string, payload: unknown): void;
  disconnect(): void;
  context(route: Route, body: unknown, actor?: Principal, params?: Record<string, string>, query?: URLSearchParams): RequestContext;
}
export function fixture(): TestRuntimeFixture {
  const store = new Store(':memory:');
  const alice: Principal = { kind: 'user', id: 'alice', userId: 'alice', workspaceId: 'workspace', role: 'owner', sessionId: 'session_alice', botId: null, deviceId: 'device_alice' };
  const bob: Principal = { ...alice, id: 'bob', userId: 'bob', role: 'member', sessionId: 'session_bob', deviceId: 'device_bob' };
  const eventListeners = new Set<(event: string, payload: unknown) => void>();
  const connectedListeners = new Set<() => void>();
  const lostListeners = new Set<() => void>();
  const calls: TestRuntimeFixture['calls'] = [];
  const services = { store, config: { publicUrl: 'https://product.example', controlUrl: 'wss://controller.example/ws', operatorToken: 'fixture-controller-token', trustedOverlay: false, dataDir: '/tmp/fixture', host: '127.0.0.1', port: 4080, operator: { approvedPrivateMcpOrigins: [] } } } as unknown as BackendServices;
  installHelpers(services);
  services.encrypt = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  services.decrypt = <T>(value: string) => JSON.parse(Buffer.from(value, 'base64url').toString()) as T;
  services.mutations = createMutationService(services, new Uint8Array(32).fill(7));
  services.auth = {
    async authenticate() { return alice; }, user: userId => store.require('users', userId), member: userId => store.require('members', userId),
    requireRole(actor, role) { if (role === 'owner' ? actor.role !== 'owner' : actor.role === 'member') throw new ApiError('forbidden', 'Role denied.'); },
    bot(actor, botId) { const bot = store.require<P.Bot>('bots', botId); if (bot.ownerUserId !== actor.userId) throw new ApiError('not_found', 'Bot denied.'); return bot; },
    conversation(actor, conversationId) { const value = store.require<P.Conversation>('conversations', conversationId); if (value.ownerUserId !== actor.userId) throw new ApiError('not_found', 'Conversation denied.'); return value; },
    machine(actor, machineId) { const value = store.require<P.Machine>('machines', machineId); if (actor.kind !== 'user' || value.ownerUserId !== actor.userId) throw new ApiError('forbidden', 'Host access denied.'); return value; },
    attachment(actor, attachmentId) { const value = store.require<P.Attachment>('attachments', attachmentId); if (value.ownerUserId !== actor.userId) throw new ApiError('not_found', 'Attachment denied.'); return value; },
    canRead(actor, collection, entity) { if (typeof entity !== 'object' || entity === null) return false; try { if ('conversationId' in entity && typeof entity.conversationId === 'string') services.auth.conversation(actor, entity.conversationId); if (collection === 'bots' && 'id' in entity && typeof entity.id === 'string') services.auth.bot(actor, entity.id); if (collection === 'machines' && 'id' in entity && typeof entity.id === 'string') services.auth.machine(actor, entity.id); return true; } catch { return false; } },
    async revokeUser() {}, async session() { throw new Error('Not exercised by runtime fixture.'); },
    issueReauth() { throw new Error('Reauthentication is not exercised by the runtime fixture.'); }, consumeReauth() { throw new Error('Reauthentication is not exercised by the runtime fixture.'); },
  } as BackendServices['auth'];
  services.integrations = { async admission() {}, async effectivePolicy(actor, botId) { return { userId: actor.userId, botId: botId ?? null, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] }; }, async connectorConfig(_actor, _botId, _conversationId, operationId) { if (operationId) store.setMetadata(`invocationConnectors:${operationId}`, []); return []; }, async sendApprovedDraft() { throw new Error('Draft delivery is not exercised by the runtime fixture.'); }, async channelIngress() { throw new Error('Channel ingress is not exercised by the runtime fixture.'); }, async emitProviderNotifications() {}, providerCapabilities() { return {}; } } as BackendServices['integrations'];
  services.gates = { async create() { throw new Error('No gate RPC configured in this fixture.'); }, async resolve() { throw new Error('No gate resolution configured.'); }, async wait() { throw new Error('No gate wait configured.'); }, cancelUser() {} };
  services.events = createEventService(services);
  store.setMetadata('workspaceId', 'workspace');
  for (const actor of [alice, bob]) { store.put('members', { id: actor.userId, userId: actor.userId, enabled: true, role: actor.role }); store.put('users', { id: actor.userId, displayName: actor.userId }); store.put('devices', { ...services.resource('device', { userId: actor.userId, platform: 'web', name: actor.userId, appVersion: '1', pushEnabled: false, lastSeenAtMs: services.now() }), id: actor.deviceId! }); }
  const machine: P.Machine = services.resource('machine', { nodeId: 'node_1', nodeName: 'worker-1', name: 'Worker', ownerUserId: alice.userId, accessUserIds: [], status: 'online', lastSeenAtMs: services.now(), labels: {}, botIds: [] });
  const bot: P.Bot = services.resource('bot', { ownerUserId: alice.userId, machineId: machine.id, profileId: 'lb-fixture', name: 'Fixture', title: '', job: '', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, skillIds: [], referenceAttachmentIds: [], mainConversationId: '', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] });
  const conversation: P.Conversation = services.resource('conversation', { kind: 'dm', name: '', botIds: [bot.id], ownerUserId: alice.userId, parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] });
  bot.mainConversationId = conversation.id; machine.botIds = [bot.id];
  store.put('machines', machine); store.put('bots', bot); store.put('conversations', conversation); store.setMetadata(`botMcp:${bot.id}`, { secretName: 'LEMON_BOT_FIXTURE', encryptedToken: 'encrypted-fixture-token', digest: 'digest' });
  store.setMetadata(`profileCanonicalSession:${bot.id}`, `agent:${bot.profileId}:main`);
  const value: TestRuntimeFixture = {
    services, store, alice, bob, machine, bot, conversation, calls,
    async rpc(method, params) {
      if (method === 'mcp.execution_names') {
        expect(params).toEqual({ server: { name: 'lemon-bot', url: 'https://product.example/mcp' }, toolNames: [...productBotTools] });
        return productExecutionProjection();
      }
      if (method === 'nodes.list') return { nodes: [{ id: machine.nodeId, name: machine.nodeName, purpose: 'lemon_bot', enrollmentInviteId: null, status: 'online', lastSeenMs: machine.lastSeenAtMs, pairedAtMs: machine.createdAtMs, capabilities: ['node.shell.open', 'node.fs.read'] }], pairings: [], summary: { presenceAvailable: true, truncated: false } };
      if (method === 'node.capabilities.get') return { nodeId: machine.nodeId, os: 'linux', measuredAtMs: services.now(), stale: false, items: [
        { id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['read', 'grep', 'find', 'ls', 'write', 'edit', 'patch'], reason: 'policy_roots_measured', measuredAtMs: services.now(), stale: false },
        { id: 'terminal', name: 'Terminal', category: 'shell', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['bash', 'bash_output', 'kill_process'], reason: 'destination_shell_measured', measuredAtMs: services.now(), stale: false },
        { id: 'browser', name: 'Browser', category: 'browser', supported: false, configuredLevel: 'off', osGrant: 'not_required', tools: [], reason: 'browser_runtime_not_installed', measuredAtMs: services.now(), stale: false },
        { id: 'connectors', name: 'Session connectors', category: 'connector', supported: true, configuredLevel: 'off', osGrant: 'unknown', tools: [], reason: 'connectors_and_permissions_are_session_scoped', measuredAtMs: services.now(), stale: false },
        { id: 'x11_desktop', name: 'X11 desktop automation', category: 'os_app', supported: false, configuredLevel: 'off', osGrant: 'unknown', tools: [], reason: 'xdotool_not_installed', measuredAtMs: services.now(), stale: false },
      ] };
      if (method === 'node.runtime.features') return compatibleFeatures(String(params.nodeId));
      if (method === 'node.secrets.set') return { name: params.name, set: true, operationId: params.operationId, status: 'applied', currentBindingMatches: true };
      if (method === 'chat.send') return { runId: params.runId, sessionKey: params.sessionKey, state: 'accepted', effectiveMode: 'new_run', targetRunId: params.runId, retrySafe: false };
      if (method === 'agent.wait') throw new ApiError('upstream_unavailable', 'Still running.');
      throw new Error(`Unconfigured fixture RPC: ${method}`);
    },
    emit(event, payload) { for (const listener of eventListeners) listener(event, payload); },
    disconnect() { services.lemon.connected = false; for (const listener of lostListeners) listener(); },
    context(route, body, actor = alice, params = {}, query = new URLSearchParams()) { return { services, route, body, user: actor, params, query, nonceResourceIds: [], requestId: 'req_fixture', request: new Request(`https://product.example${route.path}`) }; },
  };
  const lemon: ConnectedLemonService = {
    connected: true, methods: ['mcp.execution_names', 'chat.send', 'runs.receipt.get', 'agent.wait', 'chat.abort', 'node.secrets.set', 'node.shell.open', 'node.shell.input', 'node.shell.resize', 'node.shell.close', 'node.fs.write', 'node.fs.stat', 'nodes.list', 'node.capabilities.get', 'node.runtime.features'],
    controller: { url: 'ws://127.0.0.1:4040/ws', state: 'connected', connectedAtMs: 1, lastDisconnectedAtMs: null, lastError: null, nextRetryAtMs: null, methodCount: 0 }, reconnect() {},
    async call<T>(method: string, params: Record<string, unknown> = {}, options = {}) { calls.push({ method, params, mutation: 'mutation' in options && options.mutation === true }); return await value.rpc(method, params) as T; },
    onEvent(listener) { eventListeners.add(listener); return () => { eventListeners.delete(listener); }; },
    onConnected(listener) { connectedListeners.add(listener); return () => { connectedListeners.delete(listener); }; },
    onDisconnected(listener) { lostListeners.add(listener); return () => { lostListeners.delete(listener); }; },
    start() {}, close() { value.disconnect(); },
  };
  services.lemon = lemon;
  return value;
}
