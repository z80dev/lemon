import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { installHelpers } from '../../src/core/helpers';
import { createEventService } from '../../src/core/events';
import { createMutationService } from '../../src/core/mutations';
import { ApiError } from '../../src/core/errors';
import type { ConnectedLemonService } from '../../src/runtime/lemon';

import type { MachineRuntimeFeatures } from '../../src/runtime/machines';

export function compatibleFeatures(nodeId: string): MachineRuntimeFeatures {
  return { nodeId, protocol: 1, lemonVersion: 'fixture', methods: ['coding_agent.run', 'node.host.info', 'node.fs.read', 'node.fs.write', 'node.shell.open', 'profiles.sync'], features: { hostIO: true, filesystemCAS: true, deletePreviews: true, encryptedSecrets: true, ptyShell: true, mcpDiscovery: true, profileSync: true, liveStreaming: true, repairInvites: true, nativeExecutionPolicy: true }, botReady: true, missingFeatures: [] };
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
    bot(actor, botId, manage) { const bot = store.require<P.Bot>('bots', botId); if (manage ? bot.ownerUserId !== actor.userId && !bot.managerUserIds.includes(actor.userId) : bot.ownerUserId !== actor.userId && !(bot.visibility === 'team' && bot.published)) throw new ApiError('not_found', 'Bot denied.'); return bot; },
    conversation(actor, conversationId) { const value = store.require<P.Conversation>('conversations', conversationId); if (value.ownerUserId !== actor.userId && !value.humanUserIds.includes(actor.userId)) throw new ApiError('not_found', 'Conversation denied.'); return value; },
    machine(actor, machineId, manage) { const value = store.require<P.Machine>('machines', machineId); if (actor.kind !== 'user' || (manage ? value.ownerUserId !== actor.userId : value.ownerUserId !== actor.userId && !value.accessUserIds.includes(actor.userId))) throw new ApiError('forbidden', 'Host access denied.'); return value; },
    attachment(actor, attachmentId) { const value = store.require<P.Attachment>('attachments', attachmentId); if (value.ownerUserId !== actor.userId) throw new ApiError('not_found', 'Attachment denied.'); return value; },
    canRead(actor, collection, entity) { if (typeof entity !== 'object' || entity === null) return false; try { if ('conversationId' in entity && typeof entity.conversationId === 'string') services.auth.conversation(actor, entity.conversationId); if (collection === 'bots' && 'id' in entity && typeof entity.id === 'string') services.auth.bot(actor, entity.id); if (collection === 'machines' && 'id' in entity && typeof entity.id === 'string') services.auth.machine(actor, entity.id); return true; } catch { return false; } },
    async revokeUser() {}, async session() { throw new Error('Not exercised by runtime fixture.'); },
  } as BackendServices['auth'];
  services.integrations = { async admission() {}, async effectivePolicy(actor, botId) { return { userId: actor.userId, botId: botId ?? null, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] }; }, async connectorConfig() { return []; }, async emitProviderNotifications() {}, providerCapabilities() { return {}; } } as BackendServices['integrations'];
  services.gates = { async create() { throw new Error('No gate RPC configured in this fixture.'); }, async resolve() { throw new Error('No gate resolution configured.'); }, async wait() { throw new Error('No gate wait configured.'); }, cancelUser() {} };
  services.events = createEventService(services);
  store.setMetadata('workspaceId', 'workspace');
  for (const actor of [alice, bob]) { store.put('members', { id: actor.userId, userId: actor.userId, enabled: true, role: actor.role }); store.put('users', { id: actor.userId, displayName: actor.userId }); store.put('devices', { ...services.resource('device', { userId: actor.userId, platform: 'web', name: actor.userId, appVersion: '1', pushEnabled: false, lastSeenAtMs: services.now() }), id: actor.deviceId! }); }
  const machine: P.Machine = services.resource('machine', { nodeId: 'node_1', nodeName: 'worker-1', name: 'Worker', ownerUserId: alice.userId, accessUserIds: [], status: 'online', lastSeenAtMs: services.now(), labels: {}, botIds: [] });
  const bot: P.Bot = services.resource('bot', { ownerUserId: alice.userId, managerUserIds: [], machineId: machine.id, profileId: 'lb-fixture', name: 'Fixture', title: '', job: '', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, visibility: 'team', published: true, required: false, skillIds: [], referenceAttachmentIds: [], mainConversationId: '', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] });
  const conversation: P.Conversation = services.resource('conversation', { kind: 'team_dm', name: '', botIds: [bot.id], humanUserIds: [alice.userId], ownerUserId: alice.userId, parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] });
  bot.mainConversationId = conversation.id; machine.botIds = [bot.id];
  store.put('machines', machine); store.put('bots', bot); store.put('conversations', conversation); store.setMetadata(`botMcp:${bot.id}`, { secretName: 'LEMON_BOT_FIXTURE', encryptedToken: 'encrypted-fixture-token', digest: 'digest' });
  const value: TestRuntimeFixture = {
    services, store, alice, bob, machine, bot, conversation, calls,
    async rpc(method, params) {
      if (method === 'nodes.list') return { nodes: [{ id: machine.nodeId, name: machine.nodeName, purpose: 'lemon_bot', enrollmentInviteId: null, status: 'online', lastSeenMs: machine.lastSeenAtMs, pairedAtMs: machine.createdAtMs, capabilities: ['node.shell.open', 'node.fs.read'] }], pairings: [], summary: { presenceAvailable: true, truncated: false } };
      if (method === 'node.capabilities.get') return { nodeId: machine.nodeId, os: 'linux', measuredAtMs: services.now(), stale: false, items: [{ id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['read', 'write'], reason: 'Injected measured worker configuration.', measuredAtMs: services.now(), stale: false }] };
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
    connected: true, methods: ['chat.send', 'runs.receipt.get', 'agent.wait', 'chat.abort', 'node.secrets.set', 'node.shell.open', 'node.shell.input', 'node.shell.resize', 'node.shell.close', 'node.fs.write', 'node.fs.stat', 'nodes.list', 'node.capabilities.get', 'node.runtime.features'],
    async call<T>(method: string, params: Record<string, unknown> = {}, options = {}) { calls.push({ method, params, mutation: 'mutation' in options && options.mutation === true }); return await value.rpc(method, params) as T; },
    onEvent(listener) { eventListeners.add(listener); return () => { eventListeners.delete(listener); }; },
    onConnected(listener) { connectedListeners.add(listener); return () => { connectedListeners.delete(listener); }; },
    onDisconnected(listener) { lostListeners.add(listener); return () => { lostListeners.delete(listener); }; },
    start() {}, close() { value.disconnect(); },
  };
  services.lemon = lemon;
  return value;
}
