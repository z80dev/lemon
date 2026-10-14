import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { createMutationService } from '../../src/core/mutations';
import { createEventService } from '../../src/core/events';
import { installHelpers } from '../../src/core/helpers';
import { fail } from '../../src/core/errors';
import { sendMessage } from '../../src/core/conversations';

export const alice: Principal = { kind: 'user', id: 'alice', userId: 'alice', workspaceId: 'workspace', role: 'member', sessionId: 'alice-session', botId: null, deviceId: null };
export const bob: Principal = { ...alice, id: 'bob', userId: 'bob', sessionId: 'bob-session' };
export interface ChatFixture {
  services: BackendServices;
  store: Store;
  submissions: { principal: Principal; conversation: P.Conversation; bot: P.Bot; message: P.MessageSend; metadata: unknown }[];
  admissions: { principal: Principal; botId: string }[];
  addBot(botId: string, visibility?: P.Bot['visibility'], ownerUserId?: string): P.Bot;
  requestContext(method: string, path: string, body: unknown, actor?: Principal, params?: Record<string, string>): RequestContext;
}
export function chatFixture(): ChatFixture {
  const store = new Store(':memory:');
  const submissions: { principal: Principal; conversation: P.Conversation; bot: P.Bot; message: P.MessageSend; metadata: unknown }[] = [];
  const admissions: { principal: Principal; botId: string }[] = [];
  const unreachable = (): never => { throw new Error('Unexpected dependency call in isolated boundary test.'); };
  // The fixture supplies only tested boundaries; all unrelated services fail loudly.
  const services = { store, config: { publicUrl: 'http://localhost:4080' }, encrypt: (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url'), decrypt: <T>(value: string): T => JSON.parse(Buffer.from(value, 'base64url').toString()) as T } as BackendServices;
  installHelpers(services);
  services.mutations = createMutationService(services, new Uint8Array(32).fill(7));
  services.events = createEventService(services);
  services.store.setMetadata('workspaceId', 'workspace');
  services.auth = {
    authenticate: async () => unreachable(),
    user: userId => store.require<P.User>('users', userId),
    member: userId => store.require<P.Member>('members', userId),
    requireRole: (actor, role) => { if (actor.role !== 'owner' && (role === 'owner' || actor.role !== 'admin')) fail('forbidden', 'Role denied.'); },
    bot: (actor, botId, manage = false) => {
      const bot = store.require<P.Bot>('bots', botId);
      if (bot.ownerUserId !== actor.userId && (bot.visibility !== 'team' || !bot.published || manage && !bot.managerUserIds.includes(actor.userId))) fail('forbidden', 'Bot denied.');
      return bot;
    },
    conversation: (actor, roomId) => {
      const room = store.require<P.Conversation>('conversations', roomId);
      if (room.kind === 'group' || room.kind === 'channel') { if (!room.humanUserIds.includes(actor.userId)) fail('forbidden', 'Room denied.'); }
      else if (room.ownerUserId !== actor.userId) fail('forbidden', 'Private room denied.');
      return room;
    },
    machine: (actor, machineId) => { const machine = store.require<P.Machine>('machines', machineId); if (machine.ownerUserId !== actor.userId && !machine.accessUserIds.includes(actor.userId)) fail('forbidden', 'Machine denied.'); return machine; },
    attachment: (actor, attachmentId) => {
      const attachment = store.require<P.Attachment>('attachments', attachmentId);
      if (attachment.conversationId) services.auth.conversation(actor, attachment.conversationId);
      else if (attachment.ownerUserId !== actor.userId) fail('forbidden', 'Staging denied.');
      return attachment;
    },
    canRead: (actor, collection, value) => {
      if (typeof value !== 'object' || value === null || !('id' in value) || typeof value.id !== 'string') return false;
      try {
        if (collection === 'conversations') services.auth.conversation(actor, value.id);
        else if (collection === 'bots') services.auth.bot(actor, value.id);
        else if ('conversationId' in value && typeof value.conversationId === 'string') services.auth.conversation(actor, value.conversationId);
        else if ('ownerUserId' in value && value.ownerUserId !== actor.userId) return false;
        return !('targetedUserId' in value) || !value.targetedUserId || value.targetedUserId === actor.userId;
      } catch { return false; }
    },
    revokeUser: async () => unreachable(), session: async () => unreachable(), issueReauth: unreachable, consumeReauth: unreachable,
  };
  services.runtime = {
    submit: async (actor, room, bot, message) => {
      submissions.push({ principal: actor, conversation: room, bot, message, metadata: store.metadata(`submissionContext:${actor.kind}:${actor.id}:${room.id}:${message.clientNonce}`) });
      const run: P.Run = services.resource('run', { conversationId: room.id, botId: bot.id, initiatorUserId: actor.userId, clientNonce: message.clientNonce, status: 'running', error: null, startedAtMs: services.now(), completedAtMs: null, routineRunId: null });
      store.put('runs', run); store.setMetadata(`runPrincipal:${run.id}`, actor);
      return { run, delivery: { botId: bot.id, requestedMode: message.mode ?? 'followup', effectiveMode: 'started', targetRunId: null, runId: run.id } };
    },
    send: (actor, roomId, message, context) => sendMessage(services, actor, roomId, message, context),
    cancel: async () => unreachable(), reconcile: async () => unreachable(), sessionKey: (room, bot) => `agent:${bot.profileId}:${room.kind === 'team_dm' ? 'dm-' + room.ownerUserId : room.kind === 'dm' ? 'main' : room.kind + '-' + room.id}`,
    revokeConnectorInvocations: async () => unreachable(),
  };
  const eventListeners = new Set<(event: string, payload: unknown) => void>();
  const connectedListeners = new Set<() => void>();
  services.lemon = { connected: true, methods: [], call: async () => unreachable(), onEvent: listener => { eventListeners.add(listener); return () => { eventListeners.delete(listener); }; }, onConnected: listener => { connectedListeners.add(listener); return () => { connectedListeners.delete(listener); }; }, start: unreachable, close: () => { eventListeners.clear(); connectedListeners.clear(); } };
  services.integrations = { admission: async (actor, botId) => { admissions.push({ principal: actor, botId }); }, effectivePolicy: async () => unreachable(), connectorConfig: async () => unreachable(), sendApprovedDraft: async () => unreachable(), emitProviderNotifications: async () => unreachable(), channelIngress: async () => unreachable(), providerCapabilities: unreachable };
  store.put('machines', { ...services.resource<Omit<P.Machine, keyof P.Resource>>('machine', { nodeId: 'node', nodeName: 'node', name: 'Test machine', ownerUserId: 'alice', accessUserIds: ['bob'], status: 'online', lastSeenAtMs: services.now(), labels: {}, botIds: [] }), id: 'machine' });
  for (const actor of [alice, bob]) {
    const user: P.User = { ...services.resource<Omit<P.User, keyof P.Resource>>('user', { displayName: actor.userId, email: `${actor.userId}@example.test`, avatarAttachmentId: null, preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false }, notifications: { enabled: true, sound: false, previews: false, completed: true, needsInput: true } }), id: actor.userId };
    store.put('users', user);
    store.put('members', { ...services.resource('member', { userId: actor.userId, displayName: actor.userId, email: `${actor.userId}@example.test`, role: 'member' as const, enabled: true }), id: actor.userId });
  }
  function addBot(botId: string, visibility: P.Bot['visibility'] = 'personal', ownerUserId = alice.userId): P.Bot {
    const bot: P.Bot = { ...services.resource('bot', { ownerUserId, managerUserIds: [], machineId: 'machine', profileId: 'lb-' + botId, name: botId, title: '', job: '', instructions: '', avatar: { kind: 'character' as const, shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, visibility, published: visibility === 'team', required: false, skillIds: [], referenceAttachmentIds: [], mainConversationId: '', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle' as const, activeRunIds: [] }), id: botId };
    store.put('bots', bot); return bot;
  }
  function requestContext(method: string, path: string, body: unknown, actor: Principal = alice, params: Record<string, string> = {}): RequestContext {
    const request = new Request(new URL(path, services.config.publicUrl), { method, ...(method === 'GET' ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }) });
    return { request, params, body, query: new URL(request.url).searchParams, user: actor, services, requestId: services.id('request'), route: { method, path: new URL(request.url).pathname, auth: 'member', handler: unreachable }, nonceResourceIds: [] };
  }
  return { services, store, addBot, requestContext, submissions, admissions };
}
