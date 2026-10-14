import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../../src/core/store';
import { createEventService } from '../../src/core/events';
import { createMutationService } from '../../src/core/mutations';
import { ApiError } from '../../src/core/errors';
import { sha256 } from '../../src/integrations/common';
import { createExportRoutes, createExportServices } from '../../src/enterprise/exports';
import type { BackendServices, HttpClient, Principal, RequestContext, Route } from '../../src/core/services';
import type * as P from '../../../contracts/protocol';

const cleanups: (() => void)[] = [];
afterEach(() => { for (const close of cleanups.splice(0).reverse()) close(); });
const owner: Principal = { kind: 'user', id: 'alice', userId: 'alice', workspaceId: 'workspace', role: 'owner', sessionId: null, botId: null, deviceId: null };
const bob: Principal = { ...owner, id: 'bob', userId: 'bob', role: 'member' };
const carol: Principal = { ...owner, id: 'carol', userId: 'carol' };

function fixture(path = ':memory:') {
  const store = new Store(path);
  store.setMetadata('policies', { actionRecording: true, auditRetentionDays: 90 });
  let now = 100000;
  let sequence = store.metadata<number>('testSequence') ?? 0;
  const resource = <T extends object>(prefix: string, fields: T): T & P.Resource => {
    const id = `${prefix}_${++sequence}`; store.setMetadata('testSequence', sequence);
    return { ...fields, id, revision: 1, createdAtMs: now, updatedAtMs: now };
  };
  const unsupported = (): never => { throw new Error('Unexpected export fixture boundary'); };
  for (const p of [owner, bob, carol]) {
    if (!store.get<P.Member>('members', p.userId)) {
      store.put<P.Member>('members', { ...resource('member', { userId: p.userId, displayName: p.userId, email: `${p.userId}@example.test`, role: p.role, enabled: true }), id: p.userId });
    }
  }
  let events: BackendServices['events'] | undefined;
  let mutations: BackendServices['mutations'] | undefined;
  const services: BackendServices = {
    store,
    config: {
      publicUrl: 'https://product.test', controlUrl: 'ws://127.0.0.1:4040/ws', operatorToken: 'known-operator-token', dataDir: tmpdir(), host: '127.0.0.1', port: 4080, trustedOverlay: false,
      operator: {
        version: 1, trustedFrontendOrigins: [], oauthRedirectUris: [], channelProviders: [], emailProviders: [], eventProviders: [], hostDrivers: [], xProvider: null, requiredRuntimeDestinations: [], breakGlassOwnerUserId: null,
        exportAllowedOrigins: ['https://collector.test'], exportPrivateOrigins: ['https://collector.test'], serverSecrets: { collector: { kind: 'env', name: 'COLLECTOR_SECRET' } },
      },
    },
    get events() { return events ??= createEventService(services); },
    get mutations() { return mutations ??= createMutationService(services, new Uint8Array(32).fill(7)); },
    http: unsupported,
    now: () => now,
    id: (prefix = 'id') => resource(prefix, {}).id,
    resource,
    update: <T extends { revision: number; updatedAtMs: number }>(row: T, changes: Partial<T>): T => ({ ...row, ...changes, revision: row.revision + 1, updatedAtMs: now }),
    encrypt: (value: unknown) => JSON.stringify(value),
    decrypt: <T>(value: string): T => JSON.parse(value),
    secret: async (ref: string) => { if (ref !== 'collector') throw new ApiError('capability_unavailable', 'Unknown secret.'); return 'known-collector-token'; },
    auth: {
      authenticate: unsupported,
      user: unsupported,
      member(userId) { return store.require<P.Member>('members', userId); },
      requireRole(p, role) {
        const member = services.auth.member(p.userId);
        if (!member.enabled || member.role !== 'owner' && (role === 'owner' || member.role !== 'admin')) throw new ApiError('forbidden', 'Admin required.');
      },
      conversation(p: Principal, id: string) { const row = store.require<P.Conversation>('conversations', id); if (row.ownerUserId !== p.userId) throw new ApiError('not_found', 'Conversation not found.'); return row; },
      bot: unsupported,
      machine: unsupported,
      attachment: unsupported,
      canRead(p, collection, entity) {
        const readable = createExportServices(services).canReadResource(p, collection, entity);
        if (readable === undefined) return unsupported();
        return readable;
      },
      revokeUser: unsupported,
      session: unsupported,
      issueReauth: unsupported,
      consumeReauth: unsupported,
    },
    page: unsupported,
    pageAfter: unsupported,
    lemon: { connected: false, methods: [], call: unsupported, onEvent: unsupported, onConnected: unsupported, start: unsupported, close: unsupported },
    runtime: { submit: unsupported, send: unsupported, cancel: unsupported, revokeConnectorInvocations: unsupported, reconcile: unsupported, sessionKey: unsupported },
    gates: { create: unsupported, resolve: unsupported, wait: unsupported, cancelUser: unsupported },
    integrations: { admission: unsupported, effectivePolicy: unsupported, connectorConfig: unsupported, sendApprovedDraft: unsupported, emitProviderNotifications: unsupported, channelIngress: unsupported, providerCapabilities: unsupported },
    entry: unsupported,
    notify: unsupported,
    syncBotProfile: unsupported,
    audit(p: Principal | null, action: string, targetId: string, outcome: P.AuditRecord['outcome'], metadata: P.JSONObject = {}, requestId = 'test-request') {
      return store.put('auditRecords', resource('audit', { actor: { kind: 'user' as const, id: p?.userId ?? null, displayName: 'Test actor' }, action, resourceType: action.split('.')[0]!, resourceId: targetId, outcome, metadata, requestId }));
    },
    attachments: {
      async create(p, bytes, metadata) {
        const row = resource<Omit<P.Attachment, keyof P.Resource>>('attachment', { ownerUserId: p.userId, conversationId: metadata.conversationId ?? null, botId: metadata.botId ?? null, filename: metadata.filename, mime: metadata.mime ?? 'application/octet-stream', size: bytes.length, sha256: sha256(bytes), width: null, height: null, durationMs: null, source: metadata.source ?? 'generated', state: 'ready', preview: 'download', provenance: metadata.provenance ?? { botId: null, runId: null, machineId: null, sourceEntryId: null, generatedAtMs: now } });
        store.put('attachments', row); store.put('testBlobs', { id: row.id, data: Buffer.from(bytes).toString('base64') }); return row;
      },
      async bytes(id: string) { return new Uint8Array(Buffer.from(store.require<{ data: string }>('testBlobs', id).data, 'base64')); },
      copy: unsupported,
      download: unsupported,
    },
    async invoke<T>(p: Principal, method: string, path: string, body?: unknown): Promise<T> {
      const url = new URL(path, services.config.publicUrl);
      const route = invocationRoutes.find(row => row.method === method && row.path === url.pathname);
      if (!route) return unsupported();
      const context: RequestContext = { route, request: new Request(url, { method }), params: {}, query: url.searchParams, body, user: p, services, requestId: 'test-invocation', nonceResourceIds: [] };
      // Internal invocation crosses a JSON response boundary, rather than asserting a report is an arbitrary T.
      return Response.json(await route.handler(context)).json();
    },
  };
  const invocationRoutes: Route[] = [{
    method: 'GET', path: '/v1/usage', auth: 'admin',
    handler(context): P.UsageReport {
      if (!context.user) throw new ApiError('unauthenticated', 'Sign in to continue.');
      services.auth.requireRole(context.user, 'admin');
      const fromAtMs = Number(context.query.get('fromAtMs'));
      const toAtMs = Number(context.query.get('toAtMs'));
      if (!context.query.has('fromAtMs') || !context.query.has('toAtMs') || !Number.isSafeInteger(fromAtMs) || fromAtMs < 0 || !Number.isSafeInteger(toAtMs) || toAtMs <= fromAtMs || context.query.get('groupBy') !== 'bot') throw new ApiError('invalid_request', 'Unexpected usage query.');
      return { fromAtMs, toAtMs, totals: { key: 'total', inputTokens: 17, outputTokens: 19, requests: 1, costUsd: null }, buckets: [], incomplete: true, pricingSource: null };
    },
  }];
  const api = createExportServices(services);
  const routes = createExportRoutes(services);
  let nonce = 0;
  async function call<T>(method: string, routePath: string, body?: Record<string, unknown>, p = owner, id?: string): Promise<T> {
    const route = routes.find(row => row.method === method && row.path === routePath)!;
    const actualPath = routePath.replace(':id', id ?? 'room');
    const context: RequestContext = { route, request: new Request(`https://product.test${actualPath}`, { method }), params: id ? { id } : {}, query: new URLSearchParams(), body: body ? { clientNonce: `test_nonce_${String(++nonce).padStart(16, '0')}`, ...body } : undefined, user: p, services, requestId: 'test-request', nonceResourceIds: [] };
    return await route.handler(context) as T;
  }
  function conversation(id: string, principal = owner) {
    store.put<P.Conversation>('conversations', { ...resource('room', {}), id, kind: 'group', name: id, ownerUserId: principal.userId, botIds: [], parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] });
  }
  function message(id: string, conversationId: string, text: string, extra: Partial<Extract<P.TranscriptEntry, { kind: 'message' }>> = {}) {
    store.put<P.TranscriptEntry>('entries', { ...resource('entry', {}), id, conversationId, seq: sequence, timestampMs: now, actor: { kind: 'user', id: 'alice', displayName: 'Alice' }, clientNonce: null, batchId: null, replyToEntryId: null, runId: null, targetedUserId: null, reactions: [], kind: 'message', role: 'user', text, streaming: false, attachmentIds: [], ...extra });
  }
  async function consent(id: string, p = owner, enabled = true) {
    const old = await call<P.ContentExportConsent>('GET', '/v1/conversations/:id/export-consent', undefined, p, id);
    return call<P.ContentExportConsent>('PUT', '/v1/conversations/:id/export-consent', { revision: old.revision, enabled }, p, id);
  }
  async function destination(selected: P.ExportDestination['streams'], enabled = true, protocol: P.ExportDestination['protocol'] = 'ndjson_webhook') {
    return call<P.ExportDestination>('POST', '/v1/export-destinations', { name: 'Collector', url: 'https://collector.test/logs', protocol, secretRef: 'collector', streams: selected, enabled });
  }
  const close = () => { api.dispose(); store.close(); };
  cleanups.push(close);
  return { store, services, api, call, consent, destination, message, conversation, advance: (ms = 1000) => { now += ms; }, close };
}
function collector(services: BackendServices, responder: (body: string, init: RequestInit) => Response | Promise<Response> = () => new Response('{}'), requests: { body: string; init: RequestInit }[] = []) {
  const http: HttpClient = async (_input, init = {}) => { const body = String(init.body); requests.push({ body, init }); return responder(body, init); };
  services.http = http;
  return requests;
}

describe('export privacy and durable delivery', () => {
  test('defaults content off; consent is private owner revisioned state, not administrative authority', async () => {
    const f = fixture(); f.conversation('own'); f.conversation('foreign', bob);
    const consent = await f.call<P.ContentExportConsent>('GET', '/v1/conversations/:id/export-consent', undefined, owner, 'own');
    expect(consent.enabled).toBe(false); expect(consent.revision).toBe(1);
    await expect(f.call('PUT', '/v1/conversations/:id/export-consent', { revision: 99, enabled: true }, owner, 'own')).rejects.toMatchObject({ code: 'revision_conflict' });
    await expect(f.call('GET', '/v1/conversations/:id/export-consent', undefined, owner, 'foreign')).rejects.toMatchObject({ code: 'not_found' });
    await expect(f.call('PUT', '/v1/conversations/:id/export-consent', { revision: 1, enabled: true, userId: 'bob' }, owner, 'own')).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(f.call('POST', '/v1/exports', { fromAtMs: 0, toAtMs: 100000, kind: 'conversation_content', conversationIds: ['own'] })).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.store.list('exports')).toHaveLength(0);
  });
  test('historical content requires current ownership and owner consent bound to the actual bytes', async () => {
    const f = fixture(); f.conversation('own'); f.conversation('foreign', bob); f.store.setMetadata('governance', { contentExportEnabled: true });
    f.message('own-entry', 'own', 'selected content'); f.message('foreign-entry', 'foreign', 'foreign private content');
    await expect(f.call('POST', '/v1/exports', { fromAtMs: 0, toAtMs: 100000, kind: 'conversation_content', conversationIds: ['own'] })).rejects.toMatchObject({ code: 'policy_denied' });
    await f.consent('own');
    await expect(f.consent('own', carol)).rejects.toMatchObject({ code: 'not_found' });
    await expect(f.call('POST', '/v1/exports', { fromAtMs: 0, toAtMs: 100000, kind: 'conversation_content', conversationIds: ['foreign'] })).rejects.toMatchObject({ code: 'not_found' });
    f.advance(1);
    const row = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: f.services.now(), kind: 'conversation_content', conversationIds: ['own'] });
    expect(row.state).toBe('queued'); expect(row.attachmentId).toBeNull(); await f.api.reconcile();
    const completed = await f.call<P.ExportRecord>('GET', '/v1/exports/:id', undefined, owner, row.id);
    expect(completed.state).toBe('completed'); const bytes = await f.services.attachments.bytes(completed.attachmentId!);
    const body = new TextDecoder().decode(bytes); expect(body).toContain('selected content'); expect(body).not.toContain('foreign private content'); expect(body).toContain('cannot erase copies');
    f.api.authorizeExportAttachment(owner, completed.attachmentId!);
    expect(() => f.api.authorizeExportAttachment(carol, completed.attachmentId!)).toThrow('Attachment not found');
    await f.consent('own', owner, false);
    expect(() => f.api.authorizeExportAttachment(owner, completed.attachmentId!)).toThrow();
    expect(f.store.require<P.ExportRecord>('exports', row.id).state).toBe('failed');
    await f.consent('own', owner, true);
    expect(() => f.api.authorizeExportAttachment(owner, completed.attachmentId!)).toThrow();
  });
  test('current ownership and global policy loss revoke downloads without administrative escalation', async () => {
    const f = fixture(); f.conversation('room'); f.store.setMetadata('governance', { contentExportEnabled: true }); await f.consent('room'); f.message('entry', 'room', 'private bytes'); f.advance(1);
    const row = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: f.services.now(), kind: 'conversation_content', conversationIds: ['room'] }); await f.api.reconcile();
    const attachmentId = f.store.require<P.ExportRecord>('exports', row.id).attachmentId!;
    f.conversation('room', bob); expect(() => f.api.authorizeExportAttachment(owner, attachmentId)).toThrow();
    expect(f.store.require<P.Attachment>('attachments', attachmentId).state).toBe('deleted');
    f.store.setMetadata('governance', { contentExportEnabled: false }); expect(() => f.api.authorizeExportAttachment(owner, attachmentId)).toThrow();
  });
  test('owner revocation invalidates queued and in-flight content without replay after re-consent', async () => {
    const f = fixture(); f.conversation('room'); f.store.setMetadata('governance', { contentExportEnabled: true }); await f.consent('room'); await f.destination(['conversation_content']);
    f.advance(); f.message('new', 'room', 'sensitive queued packet');
    const requests = collector(f.services, async () => { await f.consent('room', owner, false); return new Response('{}'); });
    await f.api.reconcile(); expect(requests).toHaveLength(1);
    expect(f.store.list<{ state: string }>('exportOutbox')[0]!.state).toBe('cancelled');
    await f.consent('room', owner, true); f.advance(500000); await f.api.reconcile(); expect(requests).toHaveLength(1);
  });
  test('stream enabling starts current watermark, disable cancels queued packets, re-enable never backfills', async () => {
    const f = fixture(); f.services.audit(owner, 'bot.created', 'old', 'succeeded'); const requests = collector(f.services);
    let destination = await f.destination(['audit'], false); f.services.audit(owner, 'bot.created', 'disabled-history', 'succeeded');
    destination = await f.call<P.ExportDestination>('PATCH', '/v1/export-destinations/:id', { revision: destination.revision, enabled: true }, owner, destination.id);
    await f.api.reconcile(); expect(requests.every(row => !row.body.includes('disabled-history') && !row.body.includes('"old"'))).toBe(true);
    f.services.audit(owner, 'bot.created', 'future', 'succeeded'); await f.api.reconcile(); expect(requests.some(row => row.body.includes('future'))).toBe(true);
    destination = await f.call<P.ExportDestination>('PATCH', '/v1/export-destinations/:id', { revision: destination.revision, enabled: false }, owner, destination.id);
    f.services.audit(owner, 'bot.created', 'later-disabled', 'succeeded'); await f.api.reconcile();
    destination = await f.call<P.ExportDestination>('PATCH', '/v1/export-destinations/:id', { revision: destination.revision, enabled: true }, owner, destination.id); await f.api.reconcile();
    expect(requests.some(row => row.body.includes('later-disabled'))).toBe(false);
    await f.call('DELETE', '/v1/export-destinations/:id', { revision: destination.revision }, owner, destination.id); expect(f.store.list('exportDestinations')).toHaveLength(0);
  });
  test('resource receipt authorization rechecks current role, own consent and content revocation', async () => {
    const f = fixture(); f.conversation('room'); f.store.setMetadata('governance', { contentExportEnabled: true });
    const consent = await f.consent('room');
    expect(f.api.canReadResource(owner, 'contentExportConsents', consent)).toBe(true);
    expect(f.api.canReadResource(carol, 'contentExportConsents', consent)).toBe(false);
    expect(f.api.canReadResource(owner, 'unownedCollection', consent)).toBeUndefined();
    f.message('entry', 'room', 'consented content');
    const record = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: 100000, kind: 'conversation_content', conversationIds: ['room'] });
    await f.api.reconcile();
    const receipt = f.store.require<P.ExportRecord>('exports', record.id);
    expect(f.api.canReadResource(owner, 'exports', receipt)).toBe(true);
    expect(f.api.canReadResource(carol, 'exports', receipt)).toBe(false);
    await f.consent('room', owner, false);
    expect(f.api.canReadResource(owner, 'exports', receipt)).toBe(false);
    await f.consent('room', owner, true);
    expect(f.api.canReadResource(owner, 'exports', receipt)).toBe(false);
    const metadata = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: 100000, kind: 'audit' });
    expect(f.api.canReadResource(carol, 'exports', metadata)).toBe(true);
    expect(f.api.canReadResource({ ...bob, role: 'owner' }, 'exports', metadata)).toBe(false);
  });
  test('revoke during attachment creation keeps the announced blob inaccessible and the job failed', async () => {
    const f = fixture(); f.conversation('room'); f.store.setMetadata('governance', { contentExportEnabled: true }); await f.consent('room'); f.message('entry', 'room', 'authorized until revoke');
    const create = f.services.attachments.create;
    let announcedId = '';
    f.services.attachments.create = async (p, bytes, metadata) => {
      const attachment = await create(p, bytes, metadata); announcedId = attachment.id;
      expect(() => f.api.authorizeExportAttachment(owner, attachment.id)).toThrow('not complete');
      await f.consent('room', owner, false);
      await f.consent('room', owner, true);
      return attachment;
    };
    const record = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: 100000, kind: 'conversation_content', conversationIds: ['room'] }); await f.api.reconcile();
    expect(f.store.require<P.ExportRecord>('exports', record.id).state).toBe('failed');
    expect(f.store.require<P.Attachment>('attachments', announcedId).state).toBe('deleted');
    expect(() => f.api.authorizeExportAttachment(owner, announcedId)).toThrow();
  });
  test('usage captures actual report once per stable measurement without leaking into the action stream', async () => {
    const f = fixture(); await f.destination(['usage']);
    const report: P.UsageReport = { fromAtMs: 0, toAtMs: 100000, totals: { key: 'total', inputTokens: 7, outputTokens: 11, requests: 1, costUsd: null }, buckets: [], incomplete: true, pricingSource: null };
    Object.assign(report.totals, { accessToken: 'not-a-usage-field', password: 123456 });
    f.api.captureUsage(owner, report); f.api.captureUsage(owner, report); f.api.captureAction(owner, { action: 'tool.completed' }, 'unselected-action');
    const requests = collector(f.services); await f.api.reconcile();
    expect(requests).toHaveLength(1); expect(requests[0]!.body).toContain('"stream":"usage"'); expect(requests[0]!.body).toContain('"inputTokens":7'); expect(requests[0]!.body).toContain('"outputTokens":11'); expect(requests[0]!.body).not.toContain('tool.completed'); expect(requests[0]!.body).not.toContain('not-a-usage-field'); expect(requests[0]!.body).not.toContain('"password"');
  });
  test('restart retries exact durable payload/key and acknowledges once; cursor survives restart', async () => {
    const directory = mkdtempSync(join(tmpdir(), 'lemon-export-')); cleanups.push(() => rmSync(directory, { recursive: true, force: true }));
    const path = join(directory, 'store.sqlite'); let f = fixture(path); await f.destination(['action']); f.api.captureAction(owner, { action: 'tool.completed', outcome: 'succeeded', runId: 'run' }, 'stable-action');
    const requests = collector(f.services, () => new Response('unavailable', { status: 503 })); await f.api.reconcile(); expect(requests).toHaveLength(1);
    const first = requests[0]!; f.close(); cleanups.splice(cleanups.indexOf(f.close), 1); f = fixture(path); f.advance(500000);
    collector(f.services, () => new Response('{}'), requests);
    await f.api.reconcile(); expect(requests).toHaveLength(2); expect(requests[1]!.body).toBe(first.body); expect(new Headers(requests[1]!.init.headers).get('idempotency-key')).toBe(new Headers(first.init.headers).get('idempotency-key'));
    expect(f.store.list<P.ExportRecord>('exports')[0]!.lastDeliveredCursor).toMatch(/^\d+$/); await f.api.reconcile(); expect(requests).toHaveLength(2);
  });
  test('known credential names/values/shapes are redacted while commands and shell output never enter metadata', async () => {
    const f = fixture(); f.conversation('room'); f.store.setMetadata('governance', { contentExportEnabled: true }); await f.consent('room');
    f.message('entry', 'room', 'known-collector-token known-operator-token collector sk-abcdefghijklmnop ghp_abcdefghijklmnopqrst eyJhbGciOiJIUzI1NiJ9.abc.def password=unsafe');
    f.advance(1);
    const content = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: f.services.now(), kind: 'conversation_content', conversationIds: ['room'] }); await f.api.reconcile();
    const body = new TextDecoder().decode(await f.services.attachments.bytes(f.store.require<P.ExportRecord>('exports', content.id).attachmentId!));
    for (const value of ['known-collector-token', 'known-operator-token', 'sk-abcdefghijklmnop', 'ghp_abcdefghijklmnopqrst', 'password=unsafe', 'eyJhbGci']) expect(body).not.toContain(value);
    f.services.audit(owner, 'tool.completed', 'tool', 'succeeded', { command: 'rm -rf dangerous', stdout: 'raw secret output', botId: 'bot', durationMs: 123, password: 'unsafe' });
    f.advance(1);
    const metadata = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: f.services.now(), kind: 'audit' }); await f.api.reconcile();
    const audit = new TextDecoder().decode(await f.services.attachments.bytes(f.store.require<P.ExportRecord>('exports', metadata.id).attachmentId!));
    expect(audit).not.toContain('rm -rf'); expect(audit).not.toContain('raw secret output'); expect(audit).toContain('durationMs');
  });
  test('real OTLP HTTP envelope is pinned, has no redirects, and partial rejection is not completion', async () => {
    const f = fixture(); await f.destination(['action'], true, 'otlp_http'); f.api.captureAction(owner, { action: 'tool.completed', outcome: 'succeeded' }, 'otlp-action');
    const requests = collector(f.services, () => new Response(JSON.stringify({ partialSuccess: { rejectedLogRecords: '1' } }))); await f.api.reconcile();
    expect(requests[0]!.init.redirect).toBe('error'); const parsed = JSON.parse(requests[0]!.body); expect(parsed.resourceLogs[0].resource.attributes[0].value.stringValue).toBe('lemon_bot');
    expect(parsed.resourceLogs[0].scopeLogs[0].logRecords[0].timeUnixNano).toBe('100000000000'); expect(f.store.list<P.ExportRecord>('exports')[0]!.state).toBe('queued');
    await expect(f.call('POST', '/v1/export-destinations', { name: 'Unsafe', url: 'https://unapproved.test', protocol: 'ndjson_webhook', streams: ['audit'], enabled: true })).rejects.toMatchObject({ code: 'policy_denied' });
    await expect(f.call('POST', '/v1/export-destinations', { name: 'Unsafe', url: 'https://collector.test', secretRef: 'machine-secret', protocol: 'ndjson_webhook', streams: ['audit'], enabled: true })).rejects.toMatchObject({ code: 'capability_unavailable' });
  });
  test('historical audit, action, and usage remain distinct; incomplete actual usage is not invented zero', async () => {
    const f = fixture(); f.services.audit(owner, 'member.updated', 'member', 'succeeded'); f.api.captureAction(owner, { action: 'tool.completed', outcome: 'succeeded' }, 'action');
    f.advance(1);
    for (const kind of ['audit', 'action', 'usage'] as const) {
      const record = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 0, toAtMs: f.services.now(), kind }); await f.api.reconcile();
      const body = new TextDecoder().decode(await f.services.attachments.bytes(f.store.require<P.ExportRecord>('exports', record.id).attachmentId!));
      if (kind === 'audit') { expect(body).toContain('member.updated'); expect(body).not.toContain('tool.completed'); }
      if (kind === 'action') { expect(body).toContain('tool.completed'); expect(body).not.toContain('member.updated'); }
      if (kind === 'usage') { expect(body).toContain('"inputTokens":17'); expect(body).toContain('"costUsd":null'); expect(body).toContain('"incomplete":true'); }
    }
  });
  test('historical snapshots include the lower timestamp and exclude the exact upper timestamp', async () => {
    const f = fixture(); f.conversation('room', ['alice']); f.store.setMetadata('governance', { contentExportEnabled: true }); await f.consent('room');
    f.advance(499 - f.services.now()); f.message('before', 'room', 'before-lower');
    f.advance(1); f.message('lower', 'room', 'at-lower');
    f.advance(499); f.message('inside', 'room', 'before-upper');
    f.advance(1); f.message('upper', 'room', 'at-upper');
    const record = await f.call<P.ExportRecord>('POST', '/v1/exports', { fromAtMs: 500, toAtMs: 1000, kind: 'conversation_content', conversationIds: ['room'] }); await f.api.reconcile();
    const completed = f.store.require<P.ExportRecord>('exports', record.id); expect(completed.state).toBe('completed');
    const bytes = new TextDecoder().decode(await f.services.attachments.bytes(completed.attachmentId!));
    expect(bytes).toContain('at-lower'); expect(bytes).toContain('before-upper'); expect(bytes).not.toContain('before-lower'); expect(bytes).not.toContain('at-upper');
  });
  test('same nonce returns one durable export receipt; changed intent conflicts before new record', async () => {
    const f = fixture(); const body = { clientNonce: 'stable_nonce_1234567890', fromAtMs: 0, toAtMs: 100000, kind: 'audit' };
    const first = await f.call<P.ExportRecord>('POST', '/v1/exports', body); const second = await f.call<P.ExportRecord>('POST', '/v1/exports', body);
    expect(second.id).toBe(first.id); expect(f.store.list('exports')).toHaveLength(1);
    await expect(f.call('POST', '/v1/exports', { ...body, kind: 'action' })).rejects.toMatchObject({ code: 'nonce_conflict' });
  });
});
