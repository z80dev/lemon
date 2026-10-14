import { afterEach, describe, expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, EntityStore, Principal, RequestContext } from '../../src/core/services';
import { ApiError } from '../../src/core/errors';
import { z, parse } from '../../src/core/validation';
import { createDraft, createGateRoutes, createGateService, cancelConversationGates, cancelConnectorConsents, previewBotResources, cancelBotResources, acknowledgeExecutionApproval } from '../../src/core/gates';

const actor: Principal = { kind: 'user', id: 'user_1', userId: 'user_1', workspaceId: 'workspace_1', role: 'member', sessionId: null, botId: null, deviceId: null };
const nonce = 'abcdefghijklmnop';
const cleanup: (() => void)[] = [];
afterEach(() => { for (const close of cleanup.splice(0)) close(); });
function unreachable(): never { throw new Error('Unexpected test boundary call'); }
/** Real SQLite transactions hold resources and event outbox together; adapters are controlled boundaries. */
function fixture() {
  const db = new Database(':memory:');
  db.exec('CREATE TABLE entities(collection TEXT,id TEXT,value TEXT,PRIMARY KEY(collection,id)); CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,payload TEXT,audience TEXT)');
  const store: EntityStore = {
    db,
    get<T>(collection: string, id: string): T | null { const row = db.query<{ value: string }, [string, string]>('SELECT value FROM entities WHERE collection=? AND id=?').get(collection, id); return row ? JSON.parse(row.value) as T : null; },
    require<T>(collection: string, id: string): T { const value = this.get<T>(collection, id); if (!value) throw new ApiError('not_found', 'Not found.'); return value; },
    list<T>(collection: string, predicate?: (value: T) => boolean): T[] { const values = db.query<{ value: string }, [string]>('SELECT value FROM entities WHERE collection=?').all(collection).map(row => JSON.parse(row.value) as T); return predicate ? values.filter(predicate) : values; },
    put<T>(collection: string, value: T & { id: string }): T { db.query('INSERT OR REPLACE INTO entities VALUES(?,?,?)').run(collection, value.id, JSON.stringify(value)); return value; },
    remove(collection, id) { db.query('DELETE FROM entities WHERE collection=? AND id=?').run(collection, id); },
    transaction<T>(operation: () => T): T { return db.transaction(operation)(); },
    metadata<T>(key: string): T | null { const row = db.query<{ value: string }, [string]>('SELECT value FROM metadata WHERE key=?').get(key); return row ? JSON.parse(row.value) as T : null; },
    setMetadata(key, value) { db.query('INSERT OR REPLACE INTO metadata VALUES(?,?)').run(key, JSON.stringify(value)); },
  };
  let now = 1000;
  let nextId = 0;
  const policy: P.EffectivePolicy = { userId: actor.userId, botId: 'bot_1', directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'allow', allowSudo: false, allowEgress: true, rules: [], networkPolicies: [], explanations: [] };
  let rpc: (method: string, params: Record<string, unknown>) => Promise<unknown> = async () => unreachable();
  let sender: (draft: P.Draft) => Promise<{ providerMessageId: string | null; runId: string | null }> = async () => unreachable();
  const calls: { method: string; params: Record<string, unknown> }[] = [];
  const sent: P.Draft[] = [];
  const services = new Proxy({} as BackendServices, { get(_object, key) { if (!Reflect.has(implemented, key)) return unreachable(); return Reflect.get(implemented, key); }, set(_object, key, value) { Reflect.set(implemented, key, value); return true; } });
  const implemented: Partial<BackendServices> = {
    store,
    now: () => now,
    id: (prefix = 'id') => `${prefix}_${++nextId}`,
    resource<T extends object>(prefix: string, fields: T): T & P.Resource { return { ...fields, id: services.id(prefix), revision: 1, createdAtMs: now, updatedAtMs: now }; },
    update<T extends { revision: number; updatedAtMs: number }>(resource: T, changes: Partial<T>): T { return { ...resource, ...changes, revision: resource.revision + 1, updatedAtMs: now }; },
    page: (_context, values) => ({ items: values, nextCursor: null }),
    mutations: { execute: async (_context, operation) => operation(), checkRevision(resource, revision) { if (resource.revision !== revision) throw new ApiError('revision_conflict', 'Resource changed.'); }, preview: unreachable, confirm: unreachable, digest(value) { return createHash('sha256').update(JSON.stringify(value)).digest('hex'); } },
    auth: { authenticate: unreachable, user: unreachable, member(userId) { return { id: userId, userId, email: 'test@example.invalid', displayName: 'Member', role: 'member', enabled: true, revision: 1, createdAtMs: now, updatedAtMs: now }; }, requireRole: unreachable, bot(_principal, botId) { return store.require<P.Bot>('bots', botId); }, conversation(principal, conversationId) { const room = store.require<P.Conversation>('conversations', conversationId); if (!room.humanUserIds.includes(principal.userId)) throw new ApiError('not_found', 'Not found.'); return room; }, machine(_principal, machineId) { return store.require<P.Machine>('machines', machineId); }, attachment: unreachable, canRead(principal, _collection, resource) { if (!resource || typeof resource !== 'object') return false; if ('gate' in resource) { const gate = resource.gate; return !!gate && typeof gate === 'object' && 'targetUserId' in gate && gate.targetUserId === principal.userId; } if ('ownerUserId' in resource) return resource.ownerUserId === principal.userId; return false; }, revokeUser: unreachable, session: unreachable, issueReauth: unreachable, consumeReauth: unreachable },
    events: { emit(name, payload, audience) { const result = db.query('INSERT INTO events(name,payload,audience) VALUES(?,?,?)').run(name, JSON.stringify(payload), JSON.stringify(audience)); return { type: 'event', seq: String(result.lastInsertRowid), event: name, payload, timestampMs: now } as P.RealtimeEvent; }, cursor: () => String(db.query<{ seq: number }, []>('SELECT COALESCE(MAX(seq),0) AS seq FROM events').get()?.seq ?? 0), earliestCursor: () => '1', replay: unreachable, visible: unreachable, subscribe: unreachable },
    lemon: { connected: true, methods: ['node.secrets.set', 'exec.approval.resolve'], async call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> { calls.push({ method, params }); return await rpc(method, params) as T; }, onEvent: () => () => {}, onConnected: unreachable, start: unreachable, close: unreachable },
    runtime: Object.assign({ submit: unreachable, send: unreachable, cancel: unreachable, reconcile: unreachable, sessionKey: () => 'session_1' }, { revokeConnectorInvocations: unreachable }),
    integrations: { admission: unreachable, effectivePolicy: async () => policy, connectorConfig: unreachable, async sendApprovedDraft(_principal, draft) { sent.push(structuredClone(draft)); return sender(draft); }, emitProviderNotifications: unreachable, channelIngress: unreachable, providerCapabilities: unreachable },
    entry(principal, conversationId, payload) {
      const entryActor = parse(z.object({ kind: z.enum(['user', 'bot', 'system']), id: z.string().nullable(), displayName: z.string() }).strict(), payload.actor ?? { kind: 'user', id: principal.userId, displayName: 'Member' });
      const base: P.EntryBase = { ...services.resource('entry', {}), id: parse(z.string(), payload.id ?? services.id('entry')), conversationId, seq: store.list<P.TranscriptEntry>('entries', item => item.conversationId === conversationId).length + 1, timestampMs: now, actor: entryActor, clientNonce: null, batchId: null, replyToEntryId: null, runId: parse(z.string().nullable(), payload.runId ?? null), targetedUserId: parse(z.string().nullable(), payload.targetedUserId ?? null), reactions: [] };
      let entry: P.TranscriptEntry;
      if (payload.kind === 'card') {
        if (!payload.card || typeof payload.card !== 'object' || !('type' in payload.card)) unreachable();
        // Gate factories pass an already typed in-process Card through the shared Record payload seam.
        const card = payload.card as P.Card;
        entry = { ...base, kind: 'card', card };
      } else if (payload.kind === 'notice') {
        entry = { ...base, kind: 'notice', severity: parse(z.enum(['info', 'warning', 'error']), payload.severity), text: parse(z.string(), payload.text), requestId: parse(z.string().nullable(), payload.requestId ?? null) };
      } else unreachable();
      store.put('entries', entry);
      services.events.emit('entry.upserted', entry, { conversationId });
      return entry;
    },
  };
  const bot: P.Bot = { ...services.resource('bot', {}), id: 'bot_1', ownerUserId: actor.userId, managerUserIds: [], machineId: 'machine_1', profileId: 'profile_1', name: 'Bot', title: '', job: '', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, visibility: 'personal', published: false, required: false, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'room_1', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] };
  store.put('bots', bot);
  store.put<P.Conversation>('conversations', { ...services.resource('conversation', {}), id: 'room_1', kind: 'dm', name: 'Room', botIds: [bot.id], humanUserIds: [actor.userId], ownerUserId: actor.userId, parentConversationId: null, leadBotId: bot.id, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] });
  store.put<P.Machine>('machines', { ...services.resource('machine', {}), id: 'machine_1', nodeId: 'node_1', nodeName: 'node', name: 'Machine', ownerUserId: actor.userId, accessUserIds: [], status: 'online', lastSeenAtMs: now, labels: {}, botIds: [bot.id] });
  store.put<P.Connector>('connectors', { ...services.resource('connector', {}), id: 'connector_1', botId: bot.id, ownerUserId: actor.userId, name: 'Email', url: 'https://example.invalid/mcp', accountLabel: 'Mailbox', authKind: 'none', state: 'connected', tools: [], secretHeaderNames: [], shared: false, lastError: null });
  let gates = createGateService(services);
  services.gates = gates;
  cleanup.push(() => { gates.close(); db.close(); });
  return { services, store, db, policy, calls, sent, get gates() { return gates; }, advance(ms: number) { now += ms; }, rpc(handler: typeof rpc) { rpc = handler; }, sender(handler: typeof sender) { sender = handler; }, restart() { gates = createGateService(services); services.gates = gates; return gates; }, events() { return db.query<{ name: string; payload: string; audience: string }, []>('SELECT name,payload,audience FROM events ORDER BY seq').all(); } };
}
const common = { botId: 'bot_1', conversationId: 'room_1', targetUserId: actor.userId };
const questionInput = { ...common, title: 'Choose', fields: [{ id: 'selection', label: 'Choice', kind: 'single_select', required: true, options: [{ value: 'yes', label: 'Yes' }] }, { id: 'count', label: 'Count', kind: 'number', required: true, min: 1, max: 5 }] };
const content: P.DraftContent = { kind: 'email', connectorId: 'connector_1', from: 'sender@example.invalid', to: ['recipient@example.invalid'], cc: [], bcc: [], subject: 'Review', body: 'Original', attachmentIds: [] };
async function action(f: ReturnType<typeof fixture>, path: string, resourceId: string, body: unknown): Promise<P.Draft> {
  const route = createGateRoutes(f.services).find(route => route.path === path && route.method === 'POST');
  if (!route) throw new Error('Missing route');
  const context: RequestContext = { request: new Request('https://example.invalid'), params: { id: resourceId }, query: new URLSearchParams(), body, user: actor, services: f.services, requestId: 'req_1', route, nonceResourceIds: [] };
  return await route.handler(context) as P.Draft;
}

describe('durable targeted gates', () => {
  test('first resolver wins and resource, gate, embedded card and events agree', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', questionInput);
    const body = { clientNonce: nonce, revision: 1, decision: 'answer', answers: { selection: 'yes', count: 3 } };
    const results = await Promise.allSettled([f.gates.resolve<P.Question>(actor, 'questions', question.id, body), f.gates.resolve<P.Question>(actor, 'questions', question.id, { ...body, clientNonce: 'otherabcdefghijk' })]);
    expect(results.filter(result => result.status === 'fulfilled')).toHaveLength(1);
    const current = f.store.require<P.Question>('questions', question.id);
    expect(current.gate.state).toBe('completed');
    expect(current.revision).toBe(2);
    expect(current.gate.revision).toBe(2);
    const entry = f.store.require<P.TranscriptEntry>('entries', question.entryId);
    expect(entry.kind === 'card' && entry.card.type === 'user_form' ? entry.card.question : null).toEqual(current);
    expect(f.events().slice(-2).map(event => event.name)).toEqual(['question.upserted', 'entry.upserted']);
  });
  test('decline and answers reject unknown fields, wrong options, bounds and types without resolving', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', questionInput);
    for (const answers of [{ selection: 'Yes', count: 3 }, { selection: 'yes', count: 6 }, { selection: 'yes', count: '3' }, { selection: 'yes', count: 2, extra: true }, { count: 2 }]) await expect(f.gates.resolve(actor, 'questions', question.id, { clientNonce: nonce, revision: 1, decision: 'answer', answers })).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(f.gates.resolve(actor, 'questions', question.id, { clientNonce: nonce, revision: 1, decision: 'decline', answers: {} })).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.store.require<P.Question>('questions', question.id).gate.state).toBe('pending');
  });
  test('admin cannot resolve another member gate', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', questionInput);
    await expect(f.gates.resolve({ ...actor, id: 'other', userId: 'other', role: 'owner' }, 'questions', question.id, { clientNonce: nonce, revision: 1, decision: 'decline' })).rejects.toMatchObject({ code: 'not_found' });
    expect(f.store.require<P.Question>('questions', question.id).gate.state).toBe('pending');
  });
  test('persisted deadline expires at boundary after restart and wakes with no permission', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', { ...questionInput, expiresInMs: 1000 });
    const old = f.gates;
    const restarted = f.restart();
    const waiting = restarted.wait<P.Question>('questions', question.id);
    f.advance(1000);
    restarted.sweep();
    expect((await waiting).gate.state).toBe('expired');
    await expect(restarted.resolve(actor, 'questions', question.id, { clientNonce: nonce, revision: 2, decision: 'decline' })).rejects.toMatchObject({ code: 'expired' });
    old.close();
  });
  test('background timer expires without HTTP traffic', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', { ...questionInput, expiresInMs: 1000 });
    const waiting = f.gates.wait<P.Question>('questions', question.id);
    f.advance(1000);
    expect((await waiting).gate.state).toBe('expired');
  });
  test('cancelUser and conversation removal wake terminal cancelled requests', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', questionInput);
    const waiting = f.gates.wait<P.Question>('questions', question.id);
    cancelConversationGates(f.services, 'room_1');
    expect((await waiting).gate.state).toBe('cancelled');
    const next = await f.gates.create<P.Question>(actor, 'question', questionInput);
    f.gates.cancelUser(actor.userId);
    expect((await f.gates.wait<P.Question>('questions', next.id)).gate.state).toBe('cancelled');
  });
  test('group sensitive cards reroute private with no sensitive data in room notice', async () => {
    const f = fixture();
    const room = f.store.require<P.Conversation>('conversations', 'room_1');
    f.store.put('conversations', { ...room, kind: 'group', humanUserIds: [actor.userId, 'other'] });
    const step = await f.gates.create<P.HumanStep>(actor, 'human_step', { ...common, title: 'Private login', instructions: 'Private destination instructions', reason: 'login' });
    expect(step.conversationId).not.toBe('room_1');
    const privateRoom = f.store.require<P.Conversation>('conversations', step.conversationId);
    expect(privateRoom.humanUserIds).toEqual([actor.userId]);
    const roomEntries = f.store.list<P.TranscriptEntry>('entries', item => item.conversationId === 'room_1');
    expect(roomEntries).toHaveLength(1);
    expect(roomEntries[0].kind).toBe('notice');
    expect(JSON.stringify(roomEntries)).not.toContain('Private destination');
    expect(JSON.stringify(roomEntries)).not.toContain('Private login');
  });
  test('auto review has no pretend model verdict and required ask-first wins', async () => {
    const f = fixture();
    f.policy.rules.push({ ...f.services.resource('rule', {}), ownerUserId: null, category: 'shell', botId: null, machineId: null, mode: 'auto_review', description: 'Review', required: true });
    const approval = await f.gates.create<P.Approval>(actor, 'approval', { ...common, title: 'Run', description: 'Consequences', target: 'command', category: 'shell', inputs: {} });
    expect(approval.gate.state).toBe('pending');
    expect(approval.review).toBe('ask');
    f.policy.rules[0].mode = 'allow';
    const forced = await f.gates.create<P.Approval>(actor, 'approval', { ...common, title: 'Run', description: 'Consequences', target: 'command', category: 'shell', inputs: {}, forceHuman: true });
    expect(forced.policyMode).toBe('ask_first');
    expect(forced.gate.state).toBe('pending');
  });
});

describe('secret acknowledgments and execution approvals', () => {
  test('secret stays submitted during one RPC and completes only on exact destination acknowledgment', async () => {
    const f = fixture();
    const { promise: pendingAck, resolve: acknowledge } = Promise.withResolvers<unknown>();
    f.rpc(async () => pendingAck);
    const request = await f.gates.create<P.SecretRequest>(actor, 'secret_request', { ...common, name: 'API_KEY', description: 'Destination key', scope: 'bot' });
    const saving = f.gates.resolve<P.SecretRequest>(actor, 'secretRequests', request.id, { clientNonce: nonce, revision: 1, decision: 'save', value: 'sensitive-test-value' });
    expect(f.store.require<P.SecretRequest>('secretRequests', request.id).gate.state).toBe('submitted');
    await expect(f.gates.resolve(actor, 'secretRequests', request.id, { clientNonce: 'otherabcdefghijk', revision: 2, decision: 'save', value: 'other' })).rejects.toMatchObject({ code: 'conflict' });
    expect(f.calls).toHaveLength(1);
    expect(f.calls[0]).toEqual({ method: 'node.secrets.set', params: { nodeId: 'node_1', name: 'API_KEY', value: 'sensitive-test-value' } });
    acknowledge({ name: 'API_KEY', set: true });
    expect((await saving).gate.state).toBe('completed');
    const persisted = [...f.store.list('secretRequests'), ...f.store.list('entries'), ...f.events()];
    expect(JSON.stringify(persisted)).not.toContain('sensitive-test-value');
  });
  test('malformed secret acknowledgment is unknown, proven rejection is failed, neither says saved', async () => {
    const f = fixture();
    for (const mode of ['unknown', 'failed'] as const) {
      f.rpc(async () => { if (mode === 'failed') throw new ApiError('policy_denied', 'Rejected before dispatch.', true); return { set: true, name: 'WRONG' }; });
      const request = await f.gates.create<P.SecretRequest>(actor, 'secret_request', { ...common, name: 'KEY', description: '', scope: 'machine' });
      const result = await f.gates.resolve<P.SecretRequest>(actor, 'secretRequests', request.id, { clientNonce: nonce, revision: 1, decision: 'save', value: 'value' });
      expect(result.gate.state).toBe(mode === 'unknown' ? 'outcome_unknown' : 'failed');
    }
  });
  test('execution resolves only exact persisted source identity and real receipt', async () => {
    const f = fixture();
    f.store.put<P.Run>('runs', { ...f.services.resource('run', {}), id: 'run_product', conversationId: 'room_1', botId: 'bot_1', initiatorUserId: actor.userId, clientNonce: nonce, status: 'running', error: null, startedAtMs: 1000, completedAtMs: null, routineRunId: null });
    const approval = await f.gates.create<P.Approval>(actor, 'approval', { ...common, runId: 'run_product', source: 'lemon_exec', upstream: { approvalId: 'upstream_approval', runId: 'upstream_run', sessionKey: 'session_1' }, category: 'shell', title: 'Execute', description: '', target: 'exec', inputs: {} });
    expect(acknowledgeExecutionApproval(f.services, { approvalId: 'upstream_approval', runId: 'different_run', sessionKey: 'session_1', decision: 'deny' })).toBe(false);
    f.rpc(async (_method, params) => ({ resolved: true, approvalId: params.approvalId, sessionKey: params.expectedSessionKey, runId: params.expectedRunId, decision: params.decision, approved: true, outcome: 'approved' }));
    const resolved = await f.gates.resolve<P.Approval>(actor, 'approvals', approval.id, { clientNonce: nonce, revision: 1, decision: 'approve_once' });
    expect(resolved.gate.state).toBe('approved');
    expect(f.calls[0]).toEqual({ method: 'exec.approval.resolve', params: { approvalId: 'upstream_approval', decision: 'approve_once', expectedSessionKey: 'session_1', expectedRunId: 'upstream_run' } });
  });
});

describe('explicit exact-content draft sending', () => {
  test('create never sends; send freezes supplied edited content and prevents concurrent edit/discard/send', async () => {
    const f = fixture();
    const { promise: pendingDelivery, resolve: delivered } = Promise.withResolvers<{ providerMessageId: string | null; runId: string | null }>();
    f.sender(async () => pendingDelivery);
    const draft = await createDraft(f.services, actor, { ...common, content });
    expect(f.sent).toHaveLength(0);
    const edited = { ...content, to: ['edited@example.invalid'], body: 'Exact reviewed content' };
    const sending = action(f, '/v1/drafts/:id/send', draft.id, { clientNonce: nonce, revision: 1, content: edited });
    expect(f.store.require<P.Draft>('drafts', draft.id).state).toBe('sending');
    expect(f.sent[0].content).toEqual(edited);
    await expect(action(f, '/v1/drafts/:id/discard', draft.id, { clientNonce: nonce, revision: 2 })).rejects.toMatchObject({ code: 'outcome_unknown' });
    await expect(action(f, '/v1/drafts/:id/send', draft.id, { clientNonce: nonce, revision: 2, content: edited })).rejects.toMatchObject({ code: 'outcome_unknown' });
    delivered({ providerMessageId: 'message_provider', runId: null });
    expect((await sending).state).toBe('sent');
    expect(f.sent).toHaveLength(1);
  });
  test('unknown send is fenced across restart and cannot be discarded or resent', async () => {
    const f = fixture();
    f.sender(async () => { throw new ApiError('outcome_unknown', 'Provider timeout.', false); });
    const draft = await createDraft(f.services, actor, { ...common, content });
    const result = await action(f, '/v1/drafts/:id/send', draft.id, { clientNonce: nonce, revision: 1, content });
    expect(result.state).toBe('outcome_unknown');
    const old = f.gates;
    f.restart();
    old.close();
    await expect(action(f, '/v1/drafts/:id/discard', draft.id, { clientNonce: nonce, revision: result.revision })).rejects.toMatchObject({ code: 'outcome_unknown' });
    await expect(action(f, '/v1/drafts/:id/send', draft.id, { clientNonce: nonce, revision: result.revision, content })).rejects.toMatchObject({ code: 'outcome_unknown' });
    expect(f.sent).toHaveLength(1);
  });
  test('restart fences persisted sending and submitted secret without redispatch', async () => {
    const f = fixture();
    const draft = await createDraft(f.services, actor, { ...common, content });
    f.store.put('drafts', f.services.update(draft, { state: 'sending' }));
    const secret = await f.gates.create<P.SecretRequest>(actor, 'secret_request', { ...common, name: 'KEY', description: '', scope: 'machine' });
    f.store.put('secretRequests', f.services.update(secret, { gate: { ...secret.gate, revision: 2, state: 'submitted' } }));
    const old = f.gates;
    f.restart();
    old.close();
    expect(f.store.require<P.Draft>('drafts', draft.id).state).toBe('outcome_unknown');
    expect((await f.gates.wait<P.SecretRequest>('secretRequests', secret.id)).gate.state).toBe('outcome_unknown');
    expect(f.calls).toHaveLength(0);
    expect(f.sent).toHaveLength(0);
  });
});

describe('gate admission and transactional failures', () => {
  test('expiry maximum, unique field IDs and strict properties reject before persistence', async () => {
    const f = fixture();
    await expect(f.gates.create(actor, 'question', { ...questionInput, expiresInMs: 600_001 })).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(f.gates.create(actor, 'question', { ...questionInput, expiresInMs: 999 })).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(f.gates.create(actor, 'question', { ...questionInput, fields: [questionInput.fields[0], questionInput.fields[0]] })).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(f.gates.create(actor, 'question', { ...questionInput, extra: 'unsupported' })).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.store.list('questions')).toHaveLength(0);
    expect(f.store.list('entries')).toHaveLength(0);
  });
  test('gate revision mismatch and event-outbox failure leave card and resource pending', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', questionInput);
    f.store.put('questions', { ...question, gate: { ...question.gate, revision: 2 } });
    await expect(f.gates.resolve(actor, 'questions', question.id, { clientNonce: nonce, revision: 1, decision: 'decline' })).rejects.toMatchObject({ code: 'revision_conflict' });
    f.store.put('questions', question);
    f.db.exec("CREATE TRIGGER reject_gate_event BEFORE INSERT ON events WHEN NEW.name='question.upserted' BEGIN SELECT RAISE(ABORT,'outbox unavailable'); END");
    await expect(f.gates.resolve(actor, 'questions', question.id, { clientNonce: nonce, revision: 1, decision: 'decline' })).rejects.toThrow();
    expect(f.store.require<P.Question>('questions', question.id)).toEqual(question);
    const entry = f.store.require<P.TranscriptEntry>('entries', question.entryId);
    expect(entry.kind === 'card' && entry.card.type === 'user_form' ? entry.card.question : null).toEqual(question);
  });
  test('consent approval binds account owner, scope, expiry and revokes with user cancellation', async () => {
    const f = fixture();
    const consent = await f.gates.create<P.ConnectorConsent>(actor, 'consent', { ...common, connectorId: 'connector_1', accountOwnerUserId: actor.userId });
    const resolved = await f.gates.resolve<P.ConnectorConsent>(actor, 'consents', consent.id, { clientNonce: nonce, revision: 1, decision: 'allow_bot', expiresAtMs: 2000 });
    expect(resolved.gate.state).toBe('approved');
    expect(resolved.scope).toBe('bot');
    expect(resolved.expiresAtMs).toBe(2000);
    f.gates.cancelUser(actor.userId);
    expect(f.store.require<P.ConnectorConsent>('consents', consent.id).gate.state).toBe('cancelled');
  });
  test('proven unsent failure requires explicit edit before another send; unknown cannot edit', async () => {
    const f = fixture();
    f.sender(async () => { throw new ApiError('policy_denied', 'Rejected before dispatch.', true); });
    const draft = await createDraft(f.services, actor, { ...common, content });
    const failed = await action(f, '/v1/drafts/:id/send', draft.id, { clientNonce: nonce, revision: 1, content });
    expect(failed.state).toBe('failed');
    await expect(action(f, '/v1/drafts/:id/send', draft.id, { clientNonce: nonce, revision: failed.revision, content })).rejects.toMatchObject({ code: 'conflict' });
    const route = createGateRoutes(f.services).find(route => route.method === 'PATCH' && route.path === '/v1/drafts/:id');
    if (!route) throw new Error('Missing edit route');
    const context: RequestContext = { request: new Request('https://example.invalid'), params: { id: draft.id }, query: new URLSearchParams(), body: { clientNonce: nonce, revision: failed.revision, content: { ...content, body: 'Re-reviewed' } }, user: actor, services: f.services, requestId: 'req_1', route, nonceResourceIds: [] };
    const edited = await route.handler(context) as P.Draft;
    expect(edited.state).toBe('editable');
    f.store.put('drafts', f.services.update(edited, { state: 'outcome_unknown' }));
    context.body = { clientNonce: nonce, revision: edited.revision + 1, content };
    expect(() => route.handler(context)).toThrow(ApiError);
    expect(f.sent).toHaveLength(1);
  });
});

test('connector revocation wakes only its exact pending consent and replaces embedded state', async () => {
  const f = fixture();
  const consent = await f.gates.create<P.ConnectorConsent>(actor, 'consent', { ...common, connectorId: 'connector_1', accountOwnerUserId: actor.userId });
  const waiting = f.gates.wait<P.ConnectorConsent>('consents', consent.id);
  cancelConnectorConsents(f.services, 'connector_1', actor.userId);
  const cancelled = await waiting;
  expect(cancelled.gate.state).toBe('cancelled');
  expect(cancelled.gate.resolvedByUserId).toBe(actor.userId);
  const entry = f.store.require<P.TranscriptEntry>('entries', consent.entryId);
  expect(entry.kind === 'card' && entry.card.type === 'connector_grant' ? entry.card.consent : null).toEqual(cancelled);
});

describe('exact bot-owned gate deletion', () => {
  test('removes only selected bot cards in a retained group and wakes its pending waiter', async () => {
    const f = fixture();
    const bot = f.store.require<P.Bot>('bots', 'bot_1');
    f.store.put('bots', { ...bot, id: 'bot_2', name: 'Other bot', profileId: 'profile_2' });
    const room = f.store.require<P.Conversation>('conversations', 'room_1');
    f.store.put('conversations', { ...room, kind: 'group', botIds: ['bot_1', 'bot_2'] });
    const selected = await f.gates.create<P.Question>(actor, 'question', { ...questionInput, title: 'Private candidate wording' });
    const other = await f.gates.create<P.Question>(actor, 'question', { ...questionInput, botId: 'bot_2' });
    const waiting = f.gates.wait<P.Question>('questions', selected.id);
    const candidates = previewBotResources(f.services, 'bot_1');
    expect(candidates.map(item => item.id)).toEqual([selected.id]);
    expect(JSON.stringify(candidates)).not.toContain('Private candidate wording');
    cancelBotResources(f.services, 'bot_1', candidates);
    expect((await waiting).gate.state).toBe('cancelled');
    expect(f.store.get('questions', selected.id)).toBeNull();
    expect(f.store.get('entries', selected.entryId)).toBeNull();
    expect(f.store.require<P.Question>('questions', other.id)).toEqual(other);
    expect(f.store.get('entries', other.entryId)).not.toBeNull();
    expect(f.store.get('conversations', 'room_1')).not.toBeNull();
  });
  test('changed candidates and uncertain sends retain every row before cancellation', async () => {
    const f = fixture();
    const question = await f.gates.create<P.Question>(actor, 'question', questionInput);
    const stale = previewBotResources(f.services, 'bot_1');
    const draft = await createDraft(f.services, actor, { ...common, content });
    expect(() => cancelBotResources(f.services, 'bot_1', stale)).toThrow(ApiError);
    expect(f.store.require<P.Question>('questions', question.id).gate.state).toBe('pending');
    f.store.put('drafts', f.services.update(draft, { state: 'outcome_unknown' }));
    const current = previewBotResources(f.services, 'bot_1');
    expect(() => cancelBotResources(f.services, 'bot_1', current)).toThrow(ApiError);
    expect(f.store.require<P.Question>('questions', question.id).gate.state).toBe('pending');
    expect(f.store.require<P.Draft>('drafts', draft.id).state).toBe('outcome_unknown');
    expect(f.store.get('entries', question.entryId)).not.toBeNull();
    expect(f.store.get('entries', draft.entryId)).not.toBeNull();
  });
});
