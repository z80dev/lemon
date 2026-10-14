import { Database } from 'bun:sqlite';
import { mock, spyOn } from 'bun:test';
import * as dns from 'node:dns/promises';
import type { LookupAddress, LookupAllOptions, LookupOneOptions, LookupOptions } from 'node:dns';
import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { AccessService, BackendServices, EntityStore, GateService, HttpClient, Principal, RequestContext, Route } from '../../src/core/services';
import { createAccessService } from '../../src/core/auth';
import { createGateService } from '../../src/core/gates';
import { revokeConnectorInvocations } from '../../src/runtime/runs';
import { z } from 'zod';
import { IntegrationError } from '../../src/integrations/common';
interface FixtureGateService extends GateService { close(): void }
const fixtureClosers = new WeakMap<BackendServices, () => void>();
export function closeFixture(services: BackendServices): void {
  const close = fixtureClosers.get(services);
  if (!close) throw new Error('Unexpected channel fixture cleanup boundary.');
  fixtureClosers.delete(services);
  close();
}


export function entityStore(db = new Database(':memory:')): EntityStore {
  db.exec('CREATE TABLE IF NOT EXISTS channel_test_entities(collection TEXT NOT NULL,id TEXT NOT NULL,value TEXT NOT NULL,PRIMARY KEY(collection,id)); CREATE TABLE IF NOT EXISTS channel_test_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)');
  const store: EntityStore = {
    db,
    get<T>(collection: string, id: string): T | null { const row = db.query('SELECT value FROM channel_test_entities WHERE collection=? AND id=?').get(collection, id) as { value: string } | null; return row ? JSON.parse(row.value) as T : null; },
    require<T>(collection: string, id: string): T { const value = store.get<T>(collection, id); if (!value) throw new IntegrationError('not_found', 'Test resource not found.'); return value; },
    list<T>(collection: string, predicate?: (value: T) => boolean): T[] { const rows = db.query('SELECT value FROM channel_test_entities WHERE collection=?').all(collection) as { value: string }[]; const values = rows.map(row => JSON.parse(row.value) as T); return predicate ? values.filter(predicate) : values; },
    put<T>(collection: string, value: T & { id: string }): T { db.query('INSERT OR REPLACE INTO channel_test_entities VALUES(?,?,?)').run(collection, value.id, JSON.stringify(value)); return value; },
    remove(collection: string, id: string): void { db.query('DELETE FROM channel_test_entities WHERE collection=? AND id=?').run(collection, id); },
    transaction<T>(operation: () => T): T { return db.transaction(operation)(); },
    metadata<T>(key: string): T | null { const row = db.query('SELECT value FROM channel_test_metadata WHERE key=?').get(key) as { value: string } | null; return row ? JSON.parse(row.value) as T : null; },
    setMetadata(key: string, value: unknown): void { db.query('INSERT OR REPLACE INTO channel_test_metadata VALUES(?,?)').run(key, JSON.stringify(value)); },
  };
  return store;
}
export function fixture(store = entityStore(), principal: Principal = { kind: 'user', id: 'user_a', userId: 'user_a', workspaceId: 'workspace', role: 'member', sessionId: 'session_a', botId: null, deviceId: null }) {
  let serial = 0; let clock = 1800000000000; let sequence = 0;
  const submissions: { principal: Principal; conversationId: string; message: P.MessageSend }[] = []; const emitted: { event: string; audience: unknown; payload: unknown }[] = [];
  const secrets: Record<string, string> = { signing: 'private-signing-key', account: 'account-token', oauth: 'oauth-secret', public: 'public-bot-token', email: 'mail-gateway-token' };
  const denied = (): never => { throw new Error('Unexpected channel fixture boundary.'); };
  let access: AccessService | undefined;
  let gates: FixtureGateService | undefined;
  const services: BackendServices = {
    config: { publicUrl: 'https://product.example', controlUrl: 'wss://controller.example/ws', operatorToken: 'test-only', dataDir: '/test', host: '127.0.0.1', port: 4080, trustedOverlay: false, operator: { version: 1, trustedFrontendOrigins: [], oauthRedirectUris: ['https://product.example/return'], serverSecrets: {}, channelProviders: [], emailProviders: [], eventProviders: [], hostDrivers: [], xProvider: null, exportAllowedOrigins: [], requiredRuntimeDestinations: [], breakGlassOwnerUserId: null, xPublicAccountSecretRef: 'public' } },
    store,
    events: {
      emit(event, payload, audience) { emitted.push({ event, audience, payload }); return { type: 'event', seq: String(++sequence), event, payload, timestampMs: clock } as P.RealtimeEvent; },
      cursor: () => String(sequence), earliestCursor: () => '0', replay: () => [], visible: () => true, subscribe: () => () => undefined,
    },
    auth: {
      async authenticate(request) { const token = request.headers.get('authorization'); if (token === 'Bearer bridge') return { ...principal, kind: 'integration', id: 'bridge', scopes: ['event_ingress:github', 'event_ingress:slack-app', 'event_ingress:mail', 'event_ingress:x'] }; if (token === 'Bearer user') return principal; throw new IntegrationError('unauthenticated', 'Invalid test token.'); },
      user(userId) { return store.require<P.User>('users', userId); }, member(userId) { return store.require<P.Member>('members', userId); },
      requireRole(who, role) { if (who.role !== 'owner' && who.role !== role) throw new IntegrationError('forbidden', 'Role refused.'); },
      bot(who, botId, manage) { const bot = store.require<P.Bot>('bots', botId); if (bot.ownerUserId !== who.userId && (manage ? !bot.managerUserIds.includes(who.userId) : bot.visibility !== 'team' || !bot.published)) throw new IntegrationError('not_found', 'Bot is private.'); return bot; },
      conversation(who, conversationId) { const conversation = store.require<P.Conversation>('conversations', conversationId); if (!conversation.humanUserIds.includes(who.userId)) throw new IntegrationError('not_found', 'Conversation is private.'); return conversation; },
      machine(who, machineId) { const machine = store.require<P.Machine>('machines', machineId); if (machine.ownerUserId !== who.userId) throw new IntegrationError('not_found', 'Machine is private.'); return machine; },
      attachment(who, attachmentId) { const attachment = store.require<P.Attachment>('attachments', attachmentId); if (attachment.ownerUserId !== who.userId) throw new IntegrationError('not_found', 'Attachment is private.'); return attachment; },
      canRead(who, _collection, value) { return !!value && typeof value === 'object' && ('ownerUserId' in value && value.ownerUserId === who.userId || 'userId' in value && value.userId === who.userId); },
      revokeUser: userId => (access ??= createAccessService(services)).revokeUser(userId),
      session: (userId, deviceId) => (access ??= createAccessService(services)).session(userId, deviceId),
      issueReauth: userId => (access ??= createAccessService(services)).issueReauth(userId),
      consumeReauth: (userId, token) => (access ??= createAccessService(services)).consumeReauth(userId, token),
    },
    mutations: { execute: async (_context, operation) => operation(), checkRevision(resource, revision) { if (resource.revision !== revision) throw new IntegrationError('revision_conflict', 'Changed.'); }, preview: denied, confirm: denied, digest: value => createHash('sha256').update(JSON.stringify(value)).digest('base64url') },
    lemon: { connected: true, methods: [], call: async () => denied(), onEvent: () => () => undefined, onConnected: () => () => undefined, start() {}, close() {} },
    runtime: {
      async submit(who, conversation, selectedBot, message) {
        submissions.push({ principal: who, conversationId: conversation.id, message });
        const pending = store.metadata<string>(`pendingRoutineRun:${who.kind}:${who.id}:${conversation.id}:${message.clientNonce}`);
        const run: P.Run = services.resource('run', { conversationId: conversation.id, botId: selectedBot.id, initiatorUserId: who.userId, clientNonce: message.clientNonce, status: 'queued', error: null, startedAtMs: null, completedAtMs: null, routineRunId: pending });
        store.put('runs', run);
        return { run, delivery: { botId: run.botId, requestedMode: 'followup', effectiveMode: 'queued', targetRunId: null, runId: run.id } };
      },
      async send(who, conversationId, message) {
        submissions.push({ principal: who, conversationId, message });
        const conversation = services.auth.conversation(who, conversationId);
        const run: P.Run = services.resource('run', { conversationId, botId: conversation.botIds[0]!, initiatorUserId: who.userId, clientNonce: message.clientNonce, status: 'queued', error: null, startedAtMs: null, completedAtMs: null, routineRunId: null }); store.put('runs', run);
        return { entries: [], runs: [run], clientNonce: message.clientNonce, status: 'queued', delivery: [{ botId: run.botId, requestedMode: 'followup', effectiveMode: 'queued', targetRunId: null, runId: run.id }] };
      },
      cancel: async () => denied(),
      revokeConnectorInvocations: (actor, botId, connectorId) => revokeConnectorInvocations(services, actor, botId, connectorId),
      reconcile: async () => denied(), sessionKey: () => 'test-session',
    },
    attachments: {
      async create(who, bytes, metadata) { const attachment: P.Attachment = services.resource('attachment', { ownerUserId: who.userId, conversationId: metadata.conversationId ?? null, botId: metadata.botId ?? null, filename: metadata.filename, mime: metadata.mime ?? 'application/octet-stream', size: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex'), width: null, height: null, durationMs: null, source: 'upload', state: 'ready', preview: 'download', provenance: { botId: null, runId: null, machineId: null, sourceEntryId: null, generatedAtMs: null } }); store.put('attachments', attachment); store.setMetadata(`bytes:${attachment.id}`, Buffer.from(bytes).toString('base64')); return attachment; },
      async copy(who, sourceAttachmentId, metadata) { const source = services.auth.attachment(who, sourceAttachmentId); return services.attachments.create(who, await services.attachments.bytes(source.id), { ...metadata, filename: source.filename, mime: source.mime }); },
      async bytes(attachmentId) { return Buffer.from(store.metadata<string>(`bytes:${attachmentId}`) ?? '', 'base64'); }, download: denied,
    },
    get gates() {
      if (!gates) {
        gates = createGateService(services);
        const create = gates.create.bind(gates);
        gates.create = <T>(who: Principal, kind: Parameters<GateService['create']>[1], input: unknown): Promise<T> => { store.setMetadata('gateInput', input); return create<T>(who, kind, input); };
      }
      return gates;
    },
    integrations: { admission: async () => undefined, effectivePolicy: async who => ({ userId: who.userId, botId: null, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] }), connectorConfig: async () => [], sendApprovedDraft: async () => denied(), emitProviderNotifications: async () => undefined, channelIngress: async () => denied(), providerCapabilities: () => ({}) },
    id: prefix => `${prefix ?? 'id'}_${++serial}`, now: () => clock,
    resource: (prefix, fields) => ({ ...fields, id: `${prefix}_${++serial}`, revision: 1, createdAtMs: clock, updatedAtMs: clock }),
    update: (resource, changes) => ({ ...resource, ...changes, revision: resource.revision + 1, updatedAtMs: clock }),
    page: (_context, items) => ({ items, nextCursor: null }), pageAfter: () => null, secret: async ref => { if (!secrets[ref]) throw new IntegrationError('capability_unavailable', 'Missing test secret.'); return secrets[ref]!; },
    encrypt: value => Buffer.from(JSON.stringify(value)).toString('base64'), decrypt: <T>(value: string) => JSON.parse(Buffer.from(value, 'base64').toString()) as T,
    audit: (who, action, targetId, outcome, metadata = {}, requestId = 'test') => services.resource('audit', { actor: { kind: who ? 'user' as const : 'system' as const, id: who?.id ?? null, displayName: 'Test' }, action, resourceType: 'integration', resourceId: targetId, outcome, requestId, metadata }),
    entry(who, conversationId, payload) {
      return store.transaction(() => {
        const conversation = services.auth.conversation(who, conversationId);
        const envelope: P.EntryBase = services.resource('entry', {
          conversationId,
          seq: store.list<P.TranscriptEntry>('entries', item => item.conversationId === conversationId).reduce((max, item) => Math.max(max, item.seq), 0) + 1,
          timestampMs: clock,
          actor: payload.actor === undefined ? { kind: 'system', id: null, displayName: 'Test' } : z.object({ kind: z.enum(['system', 'user', 'bot']), id: z.string().nullable(), displayName: z.string() }).parse(payload.actor),
          clientNonce: typeof payload.clientNonce === 'string' ? payload.clientNonce : null,
          batchId: typeof payload.batchId === 'string' ? payload.batchId : null,
          replyToEntryId: typeof payload.replyToEntryId === 'string' ? payload.replyToEntryId : null,
          runId: typeof payload.runId === 'string' ? payload.runId : null,
          targetedUserId: typeof payload.targetedUserId === 'string' ? payload.targetedUserId : who.userId,
          reactions: [],
        });
        if (typeof payload.id === 'string') envelope.id = payload.id;
        let entry: P.TranscriptEntry;
        switch (payload.kind) {
          case 'message': entry = { ...envelope, kind: 'message', ...z.object({ role: z.enum(['user', 'assistant']), text: z.string(), streaming: z.boolean(), attachmentIds: z.array(z.string()) }).parse(payload) }; break;
          case 'notice': entry = { ...envelope, kind: 'notice', ...z.object({ severity: z.enum(['info', 'warning', 'error']), text: z.string(), requestId: z.string().nullable() }).parse(payload) }; break;
          case 'user_attachment': entry = { ...envelope, kind: 'user_attachment', attachmentId: z.string().parse(payload.attachmentId) }; break;
          case 'card': {
            const card = z.object({ type: z.enum(['permission_request', 'auto_review_approval', 'local_tool_permission', 'publish_approval']), approval: z.object({ id: z.string() }) }).parse(payload.card);
            const approval = store.require<P.Approval>('approvals', card.approval.id);
            if (approval.entryId !== envelope.id || approval.conversationId !== conversationId || approval.gate.targetUserId !== who.userId) throw new Error('Unexpected channel fixture approval card binding.');
            entry = { ...envelope, kind: 'card', card: { type: card.type, approval } };
            break;
          }
          default: throw new Error(`Unexpected channel fixture transcript kind: ${String(payload.kind)}.`);
        }
        store.put('entries', entry);
        const updated = services.update(conversation, { lastEntryId: entry.id }); store.put('conversations', updated);
        services.events.emit('entry.upserted', entry, { conversationId, userIds: entry.targetedUserId ? [entry.targetedUserId] : undefined });
        services.events.emit('conversation.upserted', updated, { conversationId });
        return entry;
      });
    },
    notify: denied, invoke: async () => denied(), syncBotProfile: async () => denied(),
  };
  const bot: P.Bot = services.resource('bot', { ownerUserId: principal.userId, managerUserIds: [], machineId: 'machine', profileId: 'profile', name: 'Finance', title: '', job: '', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, visibility: 'personal', published: false, required: false, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'main', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] });
  store.put('bots', bot); store.put('workspaces', { ...services.resource('workspace', { name: 'Test', ownerUserId: principal.userId, enabled: true, timezone: 'UTC' }), id: principal.workspaceId });
  store.put('members', { ...services.resource('member', { userId: principal.userId, displayName: 'Test', email: 'a@example.org', role: 'member', enabled: true }), id: principal.userId });
  store.put('users', { ...services.resource('user', { email: 'a@example.org', displayName: 'Test', avatarAttachmentId: null, preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: bot.voice, celebrationsEnabled: false }, notifications: { enabled: true, sound: false, previews: false, completed: true, needsInput: true } }), id: principal.userId } satisfies P.User);
  store.put('machines', { ...services.resource('machine', { name: 'Test machine', nodeName: 'test', nodeId: 'node_test', ownerUserId: principal.userId, accessUserIds: [], status: 'online', lastSeenAtMs: clock, labels: {}, botIds: [bot.id] }), id: bot.machineId } satisfies P.Machine);
  const conversation: P.Conversation = { ...services.resource('conversation', { kind: 'dm' as const, name: 'Main', botIds: [bot.id], humanUserIds: [principal.userId], ownerUserId: principal.userId, parentConversationId: null, leadBotId: bot.id, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] }), id: bot.mainConversationId }; store.put('conversations', conversation);
  store.setMetadata('governance', { revision: 1, allowedChannelAdapters: ['slack', 'email', 'discord', 'telegram', 'whatsapp'], emailEnabled: true, xMentionsEnabled: true }); store.setMetadata('workspaceId', principal.workspaceId);
  fixtureClosers.set(services, () => { gates?.close(); store.db.close(); });
  return { services, principal, bot, submissions, emitted, setClock(value: number) { clock = value; }, secrets };
}
export function context(services: BackendServices, route: Route, principal: Principal | null, body?: unknown, params: Record<string, string> = {}, query = '', request?: Request): RequestContext {
  return { services, route, user: principal, body, params, query: new URLSearchParams(query), request: request ?? new Request('https://product.example' + route.path), requestId: 'req_test', nonceResourceIds: [] };
}
export function route(routes: Route[], method: string, path: string): Route {
  const found = routes.find(item => item.method === method && item.path === path); if (!found) throw new Error(`Missing route ${method} ${path}`); return found;
}
export const emailProvider: P.EmailProviderConfig = { id: 'mail', domain: 'mail.example.org', provisioningBaseUrl: 'https://example.com/mail', provisioningSecretRef: 'email', immutableAddresses: true, reservedNames: ['admin', 'postmaster'], smtp: { host: 'smtp.example.org', port: 465, tls: true, secretRef: 'email' }, imap: { host: 'imap.example.org', port: 993, tls: true, secretRef: 'email' }, signingSecretRef: 'signing', supportsUnsubscribe: true };
export const slackProvider: P.ChannelProviderConfig = { id: 'slack-app', adapter: 'slack', oauth: { id: 'slack-oauth', clientId: 'client', clientSecretRef: 'oauth', authorizeUrl: 'https://example.com/oauth/authorize', tokenUrl: 'https://example.com/oauth/token', scopes: ['chat:write', 'users:read', 'im:write'], redirectUris: ['https://product.example/v1/channels/oauth/callback'], allowedOrigins: ['https://example.com'] }, signingSecretRef: 'signing', apiBaseUrl: 'https://example.com/api', accountSecretRef: 'account', capabilities: { events: ['mention', 'message', 'reaction'], inbound: true, outbound: true }, supportsBotAppInstall: true };

function providerLookup(hostname: string, family: number): Promise<LookupAddress>;
function providerLookup(hostname: string, options: LookupOneOptions): Promise<LookupAddress>;
function providerLookup(hostname: string, options: LookupAllOptions): Promise<LookupAddress[]>;
function providerLookup(hostname: string, options: LookupOptions): Promise<LookupAddress | LookupAddress[]>;
function providerLookup(hostname: string): Promise<LookupAddress>;
async function providerLookup(_hostname: string, options?: number | LookupOptions): Promise<LookupAddress | LookupAddress[]> {
  const address = { address: '93.184.216.34', family: 4 };
  return typeof options === 'object' && options.all ? [address] : address;
}

export function providerMocks(services: BackendServices, handler: (url: URL, init?: RequestInit) => unknown | Promise<unknown>) {
  const dnsMock = spyOn(dns, 'lookup').mockImplementation(providerLookup);
  const previous = services.http;
  const client: HttpClient = async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const result = await handler(url, init);
    return result instanceof Response ? result : Response.json(result);
  };
  const fetchMock = mock(client);
  services.http = fetchMock;
  return { restore() { if (previous === undefined) delete services.http; else services.http = previous; dnsMock.mockRestore(); }, fetchMock };
}
