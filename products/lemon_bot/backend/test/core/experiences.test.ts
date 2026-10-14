import { describe, expect, test } from 'bun:test';
import { Store } from '../../src/core/store';
import { createMutationService } from '../../src/core/mutations';
import { createEventService } from '../../src/core/events';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext } from '../../src/core/services';
import { ApiError, fail } from '../../src/core/errors';
import { botPresence, createExperienceRoutes, createExperienceService, effectiveBotGrants, invocationBotToolPolicy, nativeBotToolPolicy, reviewedCandidates } from '../../src/core/experiences';
import { productBotTools } from '../../src/core/bots';
import { z } from '../../src/core/validation';

const noticePayload = z.object({
  kind: z.literal('notice'), severity: z.enum(['info', 'warning', 'error']), text: z.string(), requestId: z.string().nullable(), targetedUserId: z.string(),
  actor: z.object({ kind: z.literal('system'), id: z.null(), displayName: z.string() }).strict(),
}).strict();

const projectedProductTools = productBotTools.map((name, index) => ({ name, executionName: `mcp_fixture_tool_${index}` }));
function projectionReply() { return { server: { name: 'lemon-bot' }, tools: projectedProductTools, count: projectedProductTools.length }; }

const nonce = 'test_nonce_123456789';
const user: Principal = { kind: 'user', id: 'alice', userId: 'alice', workspaceId: 'workspace', role: 'admin', sessionId: 'session', botId: null, deviceId: null };
function fixture() {
  const store = new Store(':memory:');
  let clock = 1700000000000, serial = 0, synced = 0, notificationCount = 0;
  const allocateId = (prefix = 'id') => `${prefix}_${String(++serial).padStart(24, '0')}`;
  const acknowledgments: P.MemoryCreate[] = [];
  const base = { revision: 1, createdAtMs: clock, updatedAtMs: clock };
  const bot: P.Bot = { ...base, id: 'bot', ownerUserId: 'alice', managerUserIds: [], machineId: 'machine', profileId: 'lb-bot', name: 'Bot', title: 'Assistant', job: 'Draft useful reports', instructions: 'Ask before sending', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, visibility: 'personal', published: false, required: false, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'room', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] };
  const machine: P.Machine = { ...base, id: 'machine', nodeId: 'node', nodeName: 'worker', name: 'Laptop', ownerUserId: 'alice', accessUserIds: [], status: 'online', lastSeenAtMs: clock, labels: {}, botIds: [bot.id] };
  const room: P.Conversation = { ...base, id: 'room', kind: 'task', name: 'Report', botIds: [bot.id], humanUserIds: ['alice'], ownerUserId: 'alice', parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] };
  const services = {
    store, config: { publicUrl: 'https://product.example.test' }, now: () => clock, id: allocateId,
    resource<T extends object>(prefix: string, fields: T): T & P.Resource { return { ...fields, id: allocateId(prefix), revision: 1, createdAtMs: clock, updatedAtMs: clock }; },
    update<T extends { revision: number; updatedAtMs: number }>(resource: T, changes: Partial<T>): T { return { ...resource, ...changes, revision: resource.revision + 1, updatedAtMs: clock }; },
    page<T>(context: RequestContext, values: T[], options?: { ascending?: boolean; key?: (value: T) => string }): P.Page<T> { const key = options?.key ?? ((value: T) => (value as P.Resource).id); const sorted = [...values].sort((a, b) => key(a).localeCompare(key(b)) * (options?.ascending ? 1 : -1)); return { items: sorted.slice(0, Number(context.query.get('limit') ?? 100)), nextCursor: null }; },
    auth: {
      bot(_principal: Principal, valueId: string, manage?: boolean) { const value = store.require<P.Bot>('bots', valueId); if (manage && value.ownerUserId !== user.userId && !value.managerUserIds.includes(user.userId)) fail('forbidden', 'Not a manager'); return value; },
      machine(_principal: Principal, valueId: string) { return store.require<P.Machine>('machines', valueId); },
      conversation(_principal: Principal, valueId: string) { return store.require<P.Conversation>('conversations', valueId); },
      attachment(_principal: Principal, valueId: string) { return store.require<P.Attachment>('attachments', valueId); },
      canRead() { return true; },
    },
    lemon: { connected: true, methods: ['mcp.execution_names'], async call<T>(method: string, params?: Record<string, unknown>): Promise<T> {
      if (method !== 'mcp.execution_names') throw new Error('Unexpected RPC');
      expect(params).toEqual({ server: { name: 'lemon-bot', url: 'https://product.example.test/mcp' }, toolNames: [...productBotTools] });
      return projectionReply() as T;
    } },
    runtime: { async reconcile() {} },
    integrations: {
      async effectivePolicy(): Promise<P.EffectivePolicy> { return { userId: user.userId, botId: bot.id, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'allow', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] }; },
      async sharedProfilePolicy(): Promise<P.EffectivePolicy> { return { userId: bot.ownerUserId, botId: bot.id, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'allow', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] }; },
    },
    events: { emit() {} },
    async syncBotProfile() { synced++; },
    async invoke<T>(_principal: Principal, method: string, path: string, input?: unknown): Promise<T> { if (method !== 'POST' || path !== '/v1/bots/bot/memory') throw new Error('Unexpected invocation'); const body = input as P.MemoryCreate; acknowledgments.push(body); const memory: P.Memory = { ...base, id: `memory_${serial++}`, botId: bot.id, scope: body.scope, userId: body.scope === 'team' ? null : user.userId, text: body.text, kind: body.kind, sourceEntryId: null }; store.put('memories', memory); return memory as T; },
    entry(_principal: Principal, conversationId: string, input: Record<string, unknown>): P.TranscriptEntry {
      const payload = noticePayload.parse(input);
      const entry: P.TranscriptEntry = { ...base, ...payload, id: allocateId('entry'), conversationId, seq: serial, timestampMs: clock, clientNonce: null, batchId: null, replyToEntryId: null, runId: null, reactions: [] };
      store.put('entries', entry);
      return entry;
    },
    notify(_principal: Principal, input: Record<string, unknown>): P.Notification { notificationCount++; const value = { ...base, id: `notification_${serial++}`, ...input } as P.Notification; store.put('notifications', value); return value; },
    encrypt(input: unknown): string { return JSON.stringify(input); },
    decrypt<T>(input: string): T { return JSON.parse(input) as T; },
  } as unknown as BackendServices;
  services.mutations = createMutationService(services, new Uint8Array(32).fill(7));
  store.put('bots', bot); store.put('machines', machine); store.put('conversations', room);
  store.put('members', { ...base, id: 'member', userId: 'alice', displayName: 'Alice', email: 'alice@example.test', role: 'admin', enabled: true } satisfies P.Member);
  store.setMetadata('workspaceId', 'workspace');
  store.setMetadata('botProfileSync:bot', { profileId: bot.profileId, nodeId: machine.nodeId, mutationId: 'sync', acknowledged: true, revisionDigest: 'a'.repeat(64), completedAtMs: clock });
  const routes = createExperienceRoutes(services);
  async function request<T>(method: string, path: string, body?: unknown, params: Record<string, string> = { id: bot.id }, query = ''): Promise<T> {
    const route = routes.find(value => value.method === method && value.path === `/v1${path}`)!;
    if (!route) throw new Error('Missing route');
    const context: RequestContext = { request: new Request('https://example.test/v1'), params, query: new URLSearchParams(query), body, user, services, requestId: 'request', route, nonceResourceIds: [] };
    return await route.handler(context) as T;
  }
  return { services, store, bot, machine, room, request, base, acknowledgments, advance(ms: number) { clock += ms; }, get synced() { return synced; }, get notificationCount() { return notificationCount; }, close() { store.close(); } };
}

describe('experience preference lifecycle', () => {
  test('records exact authorized source and undoes without replacing later changes', async () => {
    const f = fixture();
    try {
      const source: P.TranscriptEntry = { ...f.base, id: 'source', conversationId: 'room', seq: 1, timestampMs: f.services.now(), actor: { kind: 'user', id: 'alice', displayName: 'Alice' }, clientNonce: nonce, batchId: null, replyToEntryId: null, runId: null, targetedUserId: null, reactions: [], kind: 'message', role: 'user', text: 'Be concise', streaming: false, attachmentIds: [] };
      f.store.put('entries', source);
      const change = await f.request<P.PreferenceChange>('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 1, changes: { instructions: 'Be concise' }, reason: 'Explicit request', sourceEntryId: source.id });
      expect(change.before).toEqual({ instructions: 'Ask before sending' }); expect(change.sourceEntryId).toBe(source.id); expect(f.synced).toBe(1);
      const undone = await f.request<P.PreferenceChange>('POST', '/preference-changes/:id/undo', { clientNonce: nonce, revision: change.revision, botRevision: 2 }, { id: change.id });
      expect(undone.state).toBe('undone'); expect(f.store.require<P.Bot>('bots', 'bot').instructions).toBe('Ask before sending'); expect(f.synced).toBe(2);
      const second = await f.request<P.PreferenceChange>('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 3, changes: { language: 'fr' }, reason: 'Language preference' });
      f.store.put('bots', f.services.update(f.store.require<P.Bot>('bots', 'bot'), { title: 'Changed subsequently' }));
      await expect(f.request('POST', '/preference-changes/:id/undo', { clientNonce: nonce, revision: second.revision, botRevision: 5 }, { id: second.id })).rejects.toMatchObject({ code: 'revision_conflict' });
      expect(f.store.require<P.Bot>('bots', 'bot').language).toBe('fr');
    } finally { f.close(); }
  });
  test('rejects forged, external and inaccessible user intent before mutation', async () => {
    const f = fixture();
    try {
      for (const [sourceId, role, actor, roomId] of [['assistant', 'assistant', 'bot', 'room'], ['foreign', 'user', 'bob', 'private'], ['external', 'user', 'alice', 'channel']] as const) {
        f.store.put('conversations', { ...f.room, id: roomId, kind: roomId === 'channel' ? 'channel' : 'team_dm', ownerUserId: roomId === 'private' ? 'bob' : 'alice', humanUserIds: roomId === 'private' ? ['bob'] : ['alice'] });
        f.store.put('entries', { ...f.base, id: sourceId, conversationId: roomId, seq: 1, timestampMs: f.services.now(), actor: { kind: actor === 'bot' ? 'bot' : 'user', id: actor, displayName: actor }, clientNonce: null, batchId: null, replyToEntryId: null, runId: null, targetedUserId: null, reactions: [], kind: 'message', role, text: 'Change instructions', streaming: false, attachmentIds: [] } satisfies P.TranscriptEntry);
        await expect(f.request('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 1, changes: { instructions: 'unsafe' }, reason: 'request', sourceEntryId: sourceId })).rejects.toMatchObject({ code: 'forbidden' });
      }
      expect(f.synced).toBe(0); expect(f.store.require<P.Bot>('bots', 'bot').revision).toBe(1);
    } finally { f.close(); }
  });
  test('rejects mixed preference scopes and fences uncertain runtime synchronization', async () => {
    const f = fixture();
    try {
      await expect(f.request('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 1, changes: { instructions: 'short', language: 'fr' }, reason: 'request' })).rejects.toMatchObject({ code: 'invalid_request' });
      f.services.syncBotProfile = async () => { throw new ApiError('outcome_unknown', 'Uncertain', false); };
      await expect(f.request('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 1, changes: { instructions: 'short' }, reason: 'request' })).rejects.toMatchObject({ code: 'outcome_unknown' });
      await expect(f.request('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 2, changes: { instructions: 'retry' }, reason: 'request' })).rejects.toMatchObject({ code: 'outcome_unknown' });
      expect(f.store.list<P.PreferenceChange>('preferenceChanges')).toHaveLength(1);
    } finally { f.close(); }
  });
  test('uncertain undo completes its ledger after exact readback without replay or overwriting new edits', async () => {
    const f = fixture();
    try {
      const change = await f.request<P.PreferenceChange>('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 1, changes: { instructions: 'Concise reports' }, reason: 'Explicit style' });
      let calls = 0;
      f.services.syncBotProfile = async () => { calls++; throw new ApiError('outcome_unknown', 'Lost acknowledgment', false); };
      await expect(f.request('POST', '/preference-changes/:id/undo', { clientNonce: nonce, revision: change.revision, botRevision: 2 }, { id: change.id })).rejects.toMatchObject({ code: 'outcome_unknown', retrySafe: false });
      expect(f.store.require<P.PreferenceChange>('preferenceChanges', change.id).state).toBe('applied');
      f.store.setMetadata('preferenceSync:bot', { state: 'acknowledged', revision: 3 });
      const newer = f.services.update(f.store.require<P.Bot>('bots', 'bot'), { instructions: 'Newer deliberate edit' }); f.store.put('bots', newer);
      const lifecycle = createExperienceService(f.services); lifecycle.reconcile(); lifecycle.reconcile();
      expect(f.store.require<P.PreferenceChange>('preferenceChanges', change.id).state).toBe('undone'); expect(f.store.require<P.Bot>('bots', 'bot').instructions).toBe('Newer deliberate edit'); expect(f.store.require<P.Bot>('bots', 'bot').revision).toBe(newer.revision);
      expect(calls).toBe(1); expect(f.store.list('preferenceUndoAttempts')).toHaveLength(0);
    } finally { f.close(); }
  });
  test('preference writes never persist a viewers private conversation or sidebar projection', async () => {
    const f = fixture();
    try {
      f.services.auth.bot = (_principal, valueId) => ({ ...f.store.require<P.Bot>('bots', valueId), mainConversationId: 'viewer-private-room', sidebar: { ...f.bot.sidebar, pinned: true, rank: 99 } });
      const change = await f.request<P.PreferenceChange>('POST', '/bots/:id/preference-changes', { clientNonce: nonce, revision: 1, changes: { job: 'Revised job' }, reason: 'Manual update' });
      expect(f.store.require<P.Bot>('bots', 'bot').mainConversationId).toBe(f.bot.mainConversationId); expect(f.store.require<P.Bot>('bots', 'bot').sidebar).toEqual(f.bot.sidebar);
      await f.request('POST', '/preference-changes/:id/undo', { clientNonce: nonce, revision: change.revision, botRevision: 2 }, { id: change.id });
      expect(f.store.require<P.Bot>('bots', 'bot').mainConversationId).toBe(f.bot.mainConversationId); expect(f.store.require<P.Bot>('bots', 'bot').job).toBe(f.bot.job);
    } finally { f.close(); }
  });
});

describe('guided memory import boundaries', () => {
  test('preview never writes, excludes credentials and imports only immutable selected candidates', async () => {
    const f = fixture();
    try {
      const preview = await f.request<P.MemoryImportPreview>('POST', '/bots/:id/memory/import/preview', { clientNonce: nonce, scope: 'personal', format: 'facts_text', text: 'I prefer concise reports.\n\nMy password is do-not-expose-this.\n\nSend reports on Fridays.' });
      expect(preview.candidates).toHaveLength(2); expect(preview.candidates.every(value => !value.selectedByDefault)).toBe(true); expect(preview.exclusions.map(value => value.reason)).toEqual(['credential']); expect(JSON.stringify(preview)).not.toContain('do-not-expose-this'); expect(f.acknowledgments).toHaveLength(0);
      const selected = preview.candidates[1]!;
      const result = await f.request<P.MemoryImportResult>('POST', '/bots/:id/memory/import', { clientNonce: nonce, revision: preview.revision, previewId: preview.id, confirmationToken: preview.confirmationToken, selectedCandidateIds: [selected.id] });
      expect(result.status).toBe('completed'); expect(result.items.map(value => value.text)).toEqual([selected.text]); expect(f.acknowledgments).toHaveLength(1); expect(f.acknowledgments[0]!.text).toBe(selected.text);
      await expect(f.request('POST', '/bots/:id/memory/import', { clientNonce: nonce, revision: preview.revision, previewId: preview.id, confirmationToken: preview.confirmationToken, selectedCandidateIds: [selected.id] })).rejects.toMatchObject({ code: 'conflict' });
    } finally { f.close(); }
  });
  test('binds confirmation to exact candidate set, bot revision and placement', async () => {
    const f = fixture();
    try {
      const preview = await f.request<P.MemoryImportPreview>('POST', '/bots/:id/memory/import/preview', { clientNonce: nonce, scope: 'personal', format: 'facts_text', text: 'I prefer weekly reports.' });
      const body = { clientNonce: nonce, revision: preview.revision, previewId: preview.id, confirmationToken: preview.confirmationToken, selectedCandidateIds: ['invented'] };
      await expect(f.request('POST', '/bots/:id/memory/import', body)).rejects.toMatchObject({ code: 'invalid_request' });
      f.store.put('bots', f.services.update(f.bot, { instructions: 'Changed' }));
      await expect(f.request('POST', '/bots/:id/memory/import', { ...body, selectedCandidateIds: [preview.candidates[0]!.id] })).rejects.toMatchObject({ code: 'revision_conflict' });
      expect(f.acknowledgments).toHaveLength(0);
    } finally { f.close(); }
  });
  test('private-note candidate selection cannot infer or replace another members notes', async () => {
    const f = fixture();
    try {
      f.store.put('bots', { ...f.bot, visibility: 'team', published: true });
      f.store.put('memories', { ...f.base, id: 'bob-note', botId: 'bot', scope: 'private_note', userId: 'bob', text: 'I prefer weekly reports.', kind: 'fact', sourceEntryId: null } satisfies P.Memory);
      const preview = await f.request<P.MemoryImportPreview>('POST', '/bots/:id/memory/import/preview', { clientNonce: nonce, scope: 'private_note', format: 'facts_text', text: 'I prefer weekly reports.' });
      expect(preview.candidates).toHaveLength(1); expect(preview.exclusions).toHaveLength(0);
      const result = await f.request<P.MemoryImportResult>('POST', '/bots/:id/memory/import', { clientNonce: nonce, revision: 1, previewId: preview.id, confirmationToken: preview.confirmationToken, selectedCandidateIds: [preview.candidates[0]!.id] });
      expect(result.items[0]!.scope).toBe('private_note'); expect(result.items[0]!.userId).toBe('alice'); expect(f.store.require<P.Memory>('memories', 'bob-note').userId).toBe('bob');
    } finally { f.close(); }
  });
  test('fences partial uncertain runtime-memory outcomes without replaying later candidates', async () => {
    const f = fixture();
    try {
      const preview = await f.request<P.MemoryImportPreview>('POST', '/bots/:id/memory/import/preview', { clientNonce: nonce, scope: 'personal', format: 'facts_text', text: 'I prefer concise replies.\n\nI work on Tuesdays.' });
      let calls = 0;
      f.services.invoke = async () => { calls++; throw new ApiError('outcome_unknown', 'Uncertain add', false); };
      const result = await f.request<P.MemoryImportResult>('POST', '/bots/:id/memory/import', { clientNonce: nonce, revision: 1, previewId: preview.id, confirmationToken: preview.confirmationToken, selectedCandidateIds: preview.candidates.map(value => value.id) });
      expect(result.status).toBe('outcome_unknown'); expect(result.items).toHaveLength(0); expect(result.failedCandidateIds).toEqual(preview.candidates.map(value => value.id)); expect(calls).toBe(1);
    } finally { f.close(); }
  });
  test('strict export rejects unknown fields and private profile memory', () => {
    const f = fixture();
    try {
      const memory: P.Memory = { ...f.base, id: 'memory', botId: 'oldbot', scope: 'private_note', userId: 'bob', text: 'Bob is a private user.', kind: 'fact', sourceEntryId: null };
      const result = reviewedCandidates(f.services, new TextEncoder().encode(JSON.stringify({ botId: 'oldbot', exportedAtMs: f.services.now(), items: [memory, { ...memory, scope: 'personal', secret: 'not-public' }] })), 'lemon_memory_json', []);
      expect(result.candidates).toHaveLength(0); expect(result.exclusions.map(value => value.reason)).toEqual(['private_profile', 'credential']); expect(JSON.stringify(result)).not.toContain('not-public');
    } finally { f.close(); }
  });
});
  test('attachment digest and expiry are rechecked without trusting the preview alone', async () => {
    const f = fixture();
    try {
      let content = new TextEncoder().encode('I prefer weekly reports.');
      const attachment: P.Attachment = { ...f.base, id: 'attachment', ownerUserId: 'alice', conversationId: null, botId: null, filename: 'facts.txt', mime: 'text/plain', size: content.length, sha256: 'digest', width: null, height: null, durationMs: null, source: 'upload', state: 'ready', preview: 'text', provenance: { botId: null, runId: null, machineId: null, sourceEntryId: null, generatedAtMs: null } };
      f.store.put('attachments', attachment);
      f.services.attachments = { async bytes() { return content; }, async create() { throw new Error('Unexpected create'); }, async copy() { throw new Error('Unexpected copy'); }, download() { throw new Error('Unexpected download'); } };
      const preview = await f.request<P.MemoryImportPreview>('POST', '/bots/:id/memory/import/preview', { clientNonce: nonce, scope: 'personal', format: 'facts_text', attachmentId: attachment.id });
      expect(preview.expiresAtMs - f.services.now()).toBe(600000);
      const confirmation = { clientNonce: nonce, revision: 1, previewId: preview.id, confirmationToken: preview.confirmationToken, selectedCandidateIds: [preview.candidates[0]!.id] };
      content = new TextEncoder().encode('I prefer something else.');
      await expect(f.request('POST', '/bots/:id/memory/import', confirmation)).rejects.toMatchObject({ code: 'revision_conflict' });
      f.advance(600001);
      await expect(f.request('POST', '/bots/:id/memory/import', confirmation)).rejects.toMatchObject({ code: 'expired' });
      expect(f.acknowledgments).toHaveLength(0);
    } finally { f.close(); }
  });

describe('truthful presence and private activity', () => {
  test('running is not making without verified output and offline overrides retained work', () => {
    const f = fixture();
    try {
      f.store.put('runs', { ...f.base, id: 'run', conversationId: 'room', botId: 'bot', initiatorUserId: 'alice', clientNonce: nonce, status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null } satisfies P.Run);
      expect(botPresence(f.services, user, f.bot).status).toBe('working');
      f.store.put('machines', { ...f.machine, status: 'offline' });
      const presence = botPresence(f.services, user, f.bot); expect(presence.status).toBe('offline'); expect(presence.stale).toBe(true); expect(presence.evidenceEntryId).toBeNull();
    } finally { f.close(); }
  });
  test('making needs exact output provenance and a pending question takes precedence', () => {
    const f = fixture();
    try {
      const run: P.Run = { ...f.base, id: 'run', conversationId: 'room', botId: 'bot', initiatorUserId: 'alice', clientNonce: nonce, status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null };
      const attachment: P.Attachment = { ...f.base, id: 'output', ownerUserId: 'alice', conversationId: 'room', botId: 'bot', filename: 'report.txt', mime: 'text/plain', size: 100, sha256: 'digest', width: null, height: null, durationMs: null, source: 'generated', state: 'ready', preview: 'text', provenance: { botId: 'bot', runId: 'run', machineId: 'machine', sourceEntryId: 'output-entry', generatedAtMs: f.services.now() } };
      const entry: P.TranscriptEntry = { ...f.base, id: 'output-entry', conversationId: 'room', seq: 1, timestampMs: f.services.now(), actor: { kind: 'bot', id: 'bot', displayName: 'Bot' }, clientNonce: null, batchId: null, replyToEntryId: null, runId: 'run', targetedUserId: null, reactions: [], kind: 'card', card: { type: 'attachment', attachmentId: attachment.id, caption: 'Report' } };
      f.store.put('runs', run); f.store.put('entries', entry); f.store.put('attachments', { ...attachment, provenance: { ...attachment.provenance, machineId: 'wrong-machine' } });
      expect(botPresence(f.services, user, f.bot).status).toBe('working');
      f.store.put('attachments', attachment); expect(botPresence(f.services, user, f.bot).status).toBe('making'); expect(botPresence(f.services, user, f.bot).evidenceEntryId).toBe(entry.id);
      f.store.put('questions', { ...f.base, id: 'question', gate: { id: 'gate', state: 'pending', targetUserId: 'alice', expiresAtMs: f.services.now() + 1000, resolvedAtMs: null, resolvedByUserId: null, revision: 1 }, entryId: 'question-entry', conversationId: 'room', botId: 'bot', title: 'Question', fields: [], answers: null } satisfies P.Question);
      expect(botPresence(f.services, user, f.bot).status).toBe('needs_input');
    } finally { f.close(); }
  });
  test('administrators cannot see other private DM provenance', async () => {
    const f = fixture();
    try {
      f.store.put('conversations', { ...f.room, id: 'private', kind: 'team_dm', ownerUserId: 'bob', humanUserIds: ['bob'] });
      f.store.put('runs', { ...f.base, id: 'private-run', conversationId: 'private', botId: 'bot', initiatorUserId: 'bob', clientNonce: nonce, status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null } satisfies P.Run);
      const activity = await f.request<P.Page<P.ActivityItem>>('GET', '/bots/:id/activity'); expect(activity.items).toHaveLength(0);
      const presence = botPresence(f.services, user, f.bot); expect(presence.status).toBe('working'); expect(presence.currentRunId).toBeNull(); expect(presence.taskConversationId).toBeNull();
      await expect(f.request('GET', '/bots/:id/activity', undefined, { id: 'bot' }, 'botId=other')).rejects.toMatchObject({ code: 'invalid_request' });
    } finally { f.close(); }
  });
  test('unknown OS permission enforces off even when product and bot request allow', async () => {
    const f = fixture();
    try {
      f.store.put('botGrants', { ...f.base, id: 'grant', botId: 'bot', machineId: 'machine', capabilityId: 'files', requestedLevel: 'read_interact', effectiveLevel: 'read_interact', reasons: [] } satisfies P.BotGrant);
      const grants = await effectiveBotGrants(f.services, user, f.bot, { machineId: 'machine', os: 'Darwin', measuredAtMs: f.services.now(), stale: false, items: [{ id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'unknown', tools: ['read'], reason: 'No permission evidence', measuredAtMs: f.services.now(), stale: false }] });
      expect(grants[0]!.effectiveLevel).toBe('off');
    } finally { f.close(); }
  });
});

describe('native grant enforcement boundaries', () => {
  test('read-only file grants produce actual deny policy and active work blocks cutover', async () => {
    const f = fixture();
    try {
      const measured: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [{ id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['read', 'write', 'edit', 'grep'], reason: 'Policy roots measured', measuredAtMs: f.services.now(), stale: false }] };
      f.services.lemon.methods = ['nodes.list', 'node.capabilities.get', 'profiles.update', 'mcp.execution_names'];
      f.services.lemon.call = async <T>(method: string): Promise<T> => {
        if (method === 'mcp.execution_names') return projectionReply() as T;
        if (method === 'nodes.list') return { nodes: [{ id: 'node', status: 'online', capabilities: ['node.capabilities.get'] }], summary: { presenceAvailable: true, truncated: false } } as T;
        if (method === 'node.capabilities.get') { const { machineId: _machineId, ...data } = measured; return { ...data, nodeId: 'node' } as T; }
        throw new Error('Unexpected RPC');
      };
      const grant = (await effectiveBotGrants(f.services, user, f.bot, measured))[0]!;
      const changed = await f.request<P.BotGrant>('PATCH', '/bots/:id/grants/:grantId', { clientNonce: nonce, revision: grant.revision, requestedLevel: 'read_only' }, { id: 'bot', grantId: grant.id });
      expect(changed.effectiveLevel).toBe('read_only'); expect(f.synced).toBe(1);
      f.services.auth.machine = () => fail('forbidden', 'No host-management authority');
      const visible = await f.request<P.Page<P.BotGrant>>('GET', '/bots/:id/grants');
      expect(visible.items[0]!.effectiveLevel).toBe('read_only');
      await expect(f.request('GET', '/machines/:id/capabilities', undefined, { id: 'machine' })).rejects.toMatchObject({ code: 'forbidden' });
      const policy = await nativeBotToolPolicy(f.services, user, f.bot, measured);
      expect(policy.deny).toContain('write'); expect(policy.deny).toContain('bash'); expect(policy.deny).not.toContain('read');
      f.store.put('runs', { ...f.base, id: 'active', conversationId: 'room', botId: 'bot', initiatorUserId: 'alice', clientNonce: nonce, status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null } satisfies P.Run);
      await expect(f.request('PATCH', '/bots/:id/grants/:grantId', { clientNonce: nonce, revision: changed.revision, requestedLevel: 'read_interact' }, { id: 'bot', grantId: grant.id })).rejects.toMatchObject({ code: 'conflict' });
      expect(f.store.require<P.BotGrant>('botGrants', grant.id).requestedLevel).toBe('read_only');
      f.store.setMetadata('botPolicySync:bot', { state: 'outcome_unknown' });
      expect((await effectiveBotGrants(f.services, user, f.bot, measured))[0]!.effectiveLevel).toBe('off');
    } finally { f.close(); }
  });
  test('shared profile floor never uses the initiating members private execution ceiling', async () => {
    const f = fixture();
    try {
      const measured: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [{ id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['read', 'write'], reason: 'Measured', measuredAtMs: f.services.now(), stale: false }] };
      f.store.put('botGrants', { ...f.base, id: 'file-grant', botId: 'bot', machineId: 'machine', capabilityId: 'files', requestedLevel: 'read_only', effectiveLevel: 'read_only', reasons: [] } satisfies P.BotGrant);
      const floor = await f.services.integrations.sharedProfilePolicy!('bot');
      f.services.integrations.effectivePolicy = async () => ({ ...floor, localExecutionCeiling: 'deny' });
      const shared = await nativeBotToolPolicy(f.services, user, f.bot, measured);
      const invocation = await invocationBotToolPolicy(f.services, user, f.bot, measured);
      expect(shared.deny).not.toContain('read'); expect(invocation.deny).toContain('read');
      for (const policy of [shared, invocation]) {
        const excluded = ['agent', 'remember', 'recall', 'cron', 'goal', 'kanban', 'todo', 'peer', 'skill_manage', 'tool_auth', 'extensions_status'];
        for (const tool of excluded) expect(policy.deny).toContain(tool);
        expect(policy.blocked_tools).toEqual(excluded);
        expect(policy.allow).toContain('task'); expect(policy.allow).toContain('read_skill'); expect(policy.allow).toContain('webfetch'); expect(policy.allow).toContain('websearch');
        for (const tool of projectedProductTools) expect(policy.allow).toContain(tool.executionName);
        for (const tool of excluded) expect(policy.allow).not.toContain(tool);
        expect(policy.deny).not.toContain('task'); expect(policy.blocked_tools).not.toContain('task');
      }
    } finally { f.close(); }
  });
  test('closed inventory preserves exact product aliases before Bot creation and excludes unsupported native tools', async () => {
    const f = fixture();
    try {
      f.store.delete('bots', f.bot.id);
      const measured: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [{ id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['read', 'operator_extension'], reason: 'Measured', measuredAtMs: f.services.now(), stale: false }] };
      f.store.put('botGrants', { ...f.base, id: 'file-grant', botId: 'bot', machineId: 'machine', capabilityId: 'files', requestedLevel: 'read_interact', effectiveLevel: 'read_interact', reasons: [] } satisfies P.BotGrant);
      const policy = await nativeBotToolPolicy(f.services, user, f.bot, measured);
      expect(policy.allow).toContain('read'); expect(policy.allow).not.toContain('write'); expect(policy.allow).not.toContain('operator_extension');
      for (const tool of projectedProductTools) expect(policy.allow).toContain(tool.executionName);
      expect(policy.allow).not.toBe('all'); expect(policy.allow).not.toContain('remember');
      expect(policy.allow).toContain('webfetch'); expect(policy.allow).toContain('websearch');
    } finally { f.close(); }
  });
  test('projection is fail-closed without the real RPC or with incomplete, ambiguous or extra selectors', async () => {
    const f = fixture();
    try {
      const measured: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [] };
      f.services.lemon.methods = [];
      await expect(nativeBotToolPolicy(f.services, user, f.bot, measured)).rejects.toMatchObject({ code: 'capability_unavailable' });
      f.services.lemon.methods = ['mcp.execution_names'];
      const reply = projectionReply();
      for (const invalid of [
        { ...reply, count: reply.count - 1 },
        { ...reply, tools: reply.tools.slice(1) },
        { ...reply, tools: reply.tools.map((tool, index) => index === 1 ? { ...tool, executionName: reply.tools[0]!.executionName } : tool) },
        { ...reply, tools: reply.tools.map((tool, index) => index === 1 ? { ...tool, name: 'operator_tool' } : tool) },
        { ...reply, server: { name: 'lemon-bot', headers: { Authorization: 'must-not-accept-secret-fields' } } },
      ]) {
        f.services.lemon.call = async <T>(): Promise<T> => invalid as T;
        await expect(nativeBotToolPolicy(f.services, user, f.bot, measured)).rejects.toMatchObject({ code: 'upstream_error' });
      }
    } finally { f.close(); }
  });
  test('measured LSP diagnostics require both file writes and local execution, with caller approval ceilings', async () => {
    const f = fixture();
    try {
      const measured: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [
        { id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['read', 'write'], reason: 'Measured roots', measuredAtMs: f.services.now(), stale: false },
        { id: 'terminal', name: 'Terminal', category: 'shell', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['bash', 'lsp_diagnostics'], reason: 'Measured local tooling', measuredAtMs: f.services.now(), stale: false },
      ] };
      for (const files of ['off', 'read_only', 'read_interact'] as const) for (const shell of ['off', 'read_only', 'read_interact'] as const) {
        f.store.put('botGrants', { ...f.base, id: 'file-grant', botId: 'bot', machineId: 'machine', capabilityId: 'files', requestedLevel: files, effectiveLevel: files, reasons: [] } satisfies P.BotGrant);
        f.store.put('botGrants', { ...f.base, id: 'shell-grant', botId: 'bot', machineId: 'machine', capabilityId: 'terminal', requestedLevel: shell, effectiveLevel: shell, reasons: [] } satisfies P.BotGrant);
        const policy = await nativeBotToolPolicy(f.services, user, f.bot, measured);
        if (files === 'read_interact' && shell === 'read_interact') { expect(policy.allow).toContain('lsp_diagnostics'); expect(policy.deny).not.toContain('lsp_diagnostics'); }
        else { expect(policy.allow).not.toContain('lsp_diagnostics'); expect(policy.deny).toContain('lsp_diagnostics'); }
      }
      const floor = await f.services.integrations.effectivePolicy(user, f.bot.id);
      f.services.integrations.effectivePolicy = async () => ({ ...floor, localExecutionCeiling: 'ask' });
      expect((await invocationBotToolPolicy(f.services, user, f.bot, measured)).require_approval).toContain('lsp_diagnostics');
      measured.items[1]!.tools = ['bash'];
      expect((await nativeBotToolPolicy(f.services, user, f.bot, measured)).allow).not.toContain('lsp_diagnostics');
      measured.items[1]!.tools = ['bash', 'lsp_diagnostics']; measured.items[0]!.osGrant = 'unknown';
      expect((await nativeBotToolPolicy(f.services, user, f.bot, measured)).allow).not.toContain('lsp_diagnostics');
    } finally { f.close(); }
  });
  test('uses discovered connector aliases and read-only hints cannot waive mandatory approval', async () => {
    const f = fixture();
    try {
      const measured: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [] };
      const connector: P.Connector = { ...f.base, id: 'connector', botId: 'bot', ownerUserId: 'alice', name: 'Reports', url: 'https://example.test/mcp', accountLabel: 'Own account', authKind: 'none', state: 'connected', tools: [{ name: 'declared_read', enabled: true }, { name: 'write_report', enabled: true }], secretHeaderNames: [], shared: false, lastError: null };
      f.store.put('connectors', connector);
      f.store.put('botGrants', { ...f.base, id: 'connector-grant', botId: 'bot', machineId: 'machine', capabilityId: 'connector:connector', requestedLevel: 'read_interact', effectiveLevel: 'read_interact', reasons: [] } satisfies P.BotGrant);
      f.store.setMetadata('connector:connector', JSON.stringify({ machineId: 'machine', configuredLevel: 'read_interact', discoveredAtMs: f.services.now(), readOnlyTools: ['declared_read'], executionNames: { declared_read: 'actual_read_alias', write_report: 'actual_write_alias' } }));
      const shared = await nativeBotToolPolicy(f.services, user, f.bot, measured);
      expect(shared.require_approval).toEqual(['actual_write_alias']);
      const floor = await f.services.integrations.sharedProfilePolicy!('bot');
      f.services.integrations.effectivePolicy = async () => ({ ...floor, localExecutionCeiling: 'ask' });
      const invocation = await invocationBotToolPolicy(f.services, user, f.bot, measured);
      expect(invocation.require_approval).toEqual(['actual_read_alias', 'actual_write_alias']);
      f.store.put('botGrants', { ...f.store.require<P.BotGrant>('botGrants', 'connector-grant'), requestedLevel: 'off' });
      const off = await invocationBotToolPolicy(f.services, user, f.bot, measured);
      expect(off.deny).toContain('actual_read_alias'); expect(off.deny).toContain('actual_write_alias');
    } finally { f.close(); }
  });
});

describe('reminder and milestone once-only lifecycle', () => {
  test('due dispatcher persists one notification across service restart and cancellation wins', async () => {
    const f = fixture();
    try {
      const reminder = await f.request<P.Reminder>('POST', '/reminders', { clientNonce: nonce, botId: 'bot', conversationId: 'room', text: 'Review the report', dueAtMs: f.services.now() + 1000, timezone: 'UTC' });
      const cancelled = await f.request<P.Reminder>('POST', '/reminders', { clientNonce: nonce, botId: 'bot', conversationId: 'room', text: 'Cancelled reminder', dueAtMs: f.services.now() + 1000, timezone: 'UTC' });
      await f.request('DELETE', '/reminders/:id', { clientNonce: nonce, revision: 1 }, { id: cancelled.id });
      f.advance(1001); createExperienceService(f.services).dispatchDueReminders(); createExperienceService(f.services).dispatchDueReminders();
      expect(f.notificationCount).toBe(1); expect(f.store.require<P.Reminder>('reminders', reminder.id).state).toBe('delivered'); expect(f.store.require<P.Reminder>('reminders', cancelled.id).state).toBe('cancelled');
    } finally { f.close(); }
  });
  test('awards actual online placement only once and ack conflict prevents duplicate animation', async () => {
    const f = fixture();
    try {
      const first = await f.request<P.Page<P.Milestone>>('GET', '/bots/:id/milestones'); expect(first.items.map(value => value.kind)).toEqual(['machine_attached']);
      const second = await f.request<P.Page<P.Milestone>>('GET', '/bots/:id/milestones'); expect(second.items[0]!.id).toBe(first.items[0]!.id);
      const milestone = first.items[0]!;
      await f.request('POST', '/milestones/:id/ack', { clientNonce: nonce }, { id: milestone.id });
      await expect(f.request('POST', '/milestones/:id/ack', { clientNonce: 'other_nonce_12345678' }, { id: milestone.id })).rejects.toMatchObject({ code: 'conflict' });
      expect(f.store.list<P.Milestone>('milestones')).toHaveLength(1);
    } finally { f.close(); }
  });
});

test('durable presence fanout redacts other members private run IDs', () => {
  const f = fixture();
  const lifecycle = createExperienceService(f.services);
  try {
    f.store.put('bots', { ...f.bot, visibility: 'team', published: true });
    f.store.put('members', { ...f.base, id: 'member-bob', userId: 'bob', displayName: 'Bob', email: 'bob@example.test', role: 'member', enabled: true } satisfies P.Member);
    f.store.put('conversations', { ...f.room, id: 'bob-dm', kind: 'team_dm', ownerUserId: 'bob', humanUserIds: ['bob'] });
    const run: P.Run = { ...f.base, id: 'private-run', conversationId: 'bob-dm', botId: 'bot', initiatorUserId: 'bob', clientNonce: nonce, status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null };
    f.store.put('runs', run);
    f.services.events = createEventService(f.services);
    lifecycle.start();
    f.services.events.emit('run.upserted', run, { userIds: ['bob'] });
    const aliceEvents = f.services.events.replay(user, '0');
    const presenceEvents = aliceEvents.filter(event => event.event === 'bot.presence');
    expect(presenceEvents).toHaveLength(1);
    if (presenceEvents[0]?.event === 'bot.presence') expect(presenceEvents[0].payload.currentRunId).toBeNull();
    expect(JSON.stringify(aliceEvents)).not.toContain('private-run');
    expect(aliceEvents.some(event => event.event === 'activity.upserted')).toBe(false);
  } finally { lifecycle.close(); f.close(); }
});

function storedZip(filename: string, text: string, flags = 0, mode = 0): Uint8Array {
  const name = Buffer.from(filename), bytes = Buffer.from(text);
  let crc = 0xffffffff;
  for (const byte of bytes) { crc ^= byte; for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0); }
  crc = (crc ^ 0xffffffff) >>> 0;
  const local = Buffer.alloc(30 + name.length + bytes.length);
  local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt16LE(flags, 6); local.writeUInt32LE(crc, 14); local.writeUInt32LE(bytes.length, 18); local.writeUInt32LE(bytes.length, 22); local.writeUInt16LE(name.length, 26); name.copy(local, 30); bytes.copy(local, 30 + name.length);
  const central = Buffer.alloc(46 + name.length);
  central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4); central.writeUInt16LE(20, 6); central.writeUInt16LE(flags, 8); central.writeUInt32LE(crc, 16); central.writeUInt32LE(bytes.length, 20); central.writeUInt32LE(bytes.length, 24); central.writeUInt16LE(name.length, 28); central.writeUInt32LE((mode << 16) >>> 0, 38); name.copy(central, 46);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(1, 8); end.writeUInt16LE(1, 10); end.writeUInt32LE(central.length, 12); end.writeUInt32LE(local.length, 16);
  return Buffer.concat([local, central, end]);
}

describe('bounded chat archive review', () => {
  test('proposes only explicit user-authored declarations, not assistant or ordinary chat', () => {
    const f = fixture();
    try {
      const mapping = {
        a: { message: { author: { role: 'user' }, content: { parts: ['Remember that I prefer short summaries.'] } } },
        b: { message: { author: { role: 'assistant' }, content: { parts: ['Remember Bob lives in Paris.'] } } },
        c: { message: { author: { role: 'user' }, content: { parts: ['What is the weather?'] } } },
        d: { message: { author: { role: 'user' }, content: { parts: ['Remember my api key is sk-not-for-sharing.'] } } },
      };
      const result = reviewedCandidates(f.services, storedZip('conversations.json', JSON.stringify([{ mapping }])), 'chat_export_zip', []);
      expect(result.candidates.map(value => value.text)).toEqual(['I prefer short summaries.']);
      expect(result.candidates[0]!.source.filename).toBe('conversations.json');
      expect(result.exclusions.map(value => value.reason)).toEqual(['not_durable', 'not_durable', 'credential']);
      expect(JSON.stringify(result)).not.toContain('sk-not-for-sharing');
    } finally { f.close(); }
  });
  test('rejects traversal, encrypted entries, symlinks, truncation and corrupt checksum', () => {
    const f = fixture();
    try {
      for (const archive of [storedZip('../facts.txt', 'A durable statement.'), storedZip('facts.txt', 'A durable statement.', 1), storedZip('facts.txt', 'A durable statement.', 0, 0xa000), storedZip('facts.txt', 'A durable statement.').subarray(0, 20)]) {
        expect(() => reviewedCandidates(f.services, archive, 'chat_export_zip', [])).toThrow(ApiError);
      }
      const corrupt = storedZip('facts.txt', 'A durable statement.'); corrupt[40] = corrupt[40]! ^ 1;
      expect(() => reviewedCandidates(f.services, corrupt, 'chat_export_zip', [])).toThrow(ApiError);
      const unsupported = reviewedCandidates(f.services, storedZip('private-secret-filename.bin', 'unreviewed'), 'chat_export_zip', []);
      expect(unsupported.candidates).toHaveLength(0); expect(unsupported.exclusions[0]!.reason).toBe('unsupported'); expect(JSON.stringify(unsupported)).not.toContain('private-secret-filename');
    } finally { f.close(); }
  });
});
