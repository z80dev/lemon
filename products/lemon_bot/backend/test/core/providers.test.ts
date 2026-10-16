import { describe, expect, spyOn, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { authFixture } from './auth.test';
import { createProviderRoutes } from '../../src/core/providers';
import { Router } from '../../src/core/router';
import { ApiError } from '../../src/core/errors';

const nonce = () => ({ clientNonce: crypto.randomUUID() });
const mockKey = 'mock-provider-key-not-a-live-credential';
/** Mock provider/controller transport only; real product auth, router, nonce journal and SQLite. */
async function fixture() {
  const f = authFixture();
  const owner = await f.services.auth.session('owner');
  const admin = await f.services.auth.session('admin');
  const member = await f.services.auth.session('alice');
  const machine: P.Machine = f.services.resource('machine', { nodeId: 'node-owned', nodeName: 'worker', name: 'Owned target', ownerUserId: 'owner', accessUserIds: [], status: 'online', lastSeenAtMs: f.services.now(), labels: {}, botIds: [] });
  f.store.put('machines', machine);
  const listings = new Map<string, P.ProviderManagement>();
  for (const nodeId of [null, 'node-owned', 'node-second']) {
    listings.set(nodeId ?? 'controller', {
      target: { id: nodeId ? `node:${nodeId}` : 'controller:mock-instance', nodeId, hostname: nodeId ?? 'controller-mock' },
      default: { providerId: null, modelId: null },
      providers: [
        { id: 'openai', displayName: 'OpenAI', methods: ['api_key'], configured: false, status: 'needs_login', lastValidation: null, environmentOverrides: [], configurationOverrides: [] },
        { id: 'openai_codex', displayName: 'OpenAI Codex', methods: ['api_key', 'device_code'], configured: false, status: 'needs_login', lastValidation: null, environmentOverrides: [], configurationOverrides: [] },
        { id: 'unsupported_mock', displayName: 'Unsupported mock', methods: ['unsupported'], configured: false, status: 'needs_login', lastValidation: null, environmentOverrides: [], configurationOverrides: [] },
      ],
    });
  }
  const calls: { method: string; params: Record<string, unknown>; mutation: boolean }[] = [];
  let onList: (() => void) | undefined;
  let failure: unknown;
  let unsafeReceipt = false;
  const methods = ['list', 'api_key.set', 'disconnect', 'default.set'].flatMap(action => [`providers.management.${action}`, `node.providers.management.${action}`]);
  f.services.lemon = {
    connected: true, methods, controller: { url: f.services.config.controlUrl, state: 'connected', connectedAtMs: f.services.now(), lastDisconnectedAtMs: null, lastError: null, nextRetryAtMs: null, methodCount: methods.length },
    async call<T>(method: string, params: Record<string, unknown> = {}, options?: { mutation?: boolean }) {
      const mutating = options?.mutation === true;
      calls.push({ method, params, mutation: mutating });
      const result = listings.get(typeof params.nodeId === 'string' ? params.nodeId : 'controller')!;
      if (!mutating) { onList?.(); return structuredClone(result) as T; }
      if (failure) throw failure;
      if (method.endsWith('default.set')) result.default = { providerId: params.providerId as string, modelId: params.modelId as string };
      else {
        const provider = result.providers.find(value => value.id === params.providerId)!;
        provider.configured = method.endsWith('api_key.set');
        provider.status = provider.configured ? 'ready' : 'needs_login';
        provider.lastValidation = { atMs: f.services.now(), kind: 'resolver', ready: provider.configured };
      }
      const response = structuredClone(result);
      if (unsafeReceipt) response.providers[0]!.displayName = mockKey;
      return response as T;
    },
    reconnect() {}, onEvent() { return () => {}; }, onConnected() { return () => {}; }, start() {}, close() {},
  };
  const router = new Router(f.services); router.register(createProviderRoutes(f.services));
  async function request(path = '/v1/instance/providers', body?: unknown, token: string | null = owner.token, headers: Record<string, string> = {}, method = body === undefined ? 'GET' : path.endsWith('/api-key') ? 'PUT' : 'POST') {
    return router.fetch(new Request(`https://lemon.example${path}`, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  }
  return { ...f, ownerAuth: owner, adminAuth: admin, memberAuth: member, machine, listings, calls, request, onList(callback: () => void) { onList = callback; }, failWith(error: unknown) { failure = error; }, unsafe() { unsafeReceipt = true; } };
}
const keyBody = () => ({ ...nonce(), targetId: 'controller:mock-instance', value: mockKey });

describe('write-only target provider management', () => {
  test('lists actual upstream methods, independent default and exact target, without requiring credentials', async () => {
    const f = await fixture(); const response = await f.request();
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(f.listings.get('controller'));
    expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(f.calls).toEqual([{ method: 'providers.management.list', params: {}, mutation: false }]);
  });
  test('only current workspace owners may list or mutate, never admin or member', async () => {
    const f = await fixture();
    for (const token of [f.adminAuth.token, f.memberAuth.token]) {
      expect((await f.request(undefined, undefined, token)).status).toBe(403);
      expect((await f.request('/v1/instance/providers/openai/api-key', keyBody(), token)).status).toBe(403);
    }
    expect((await f.request(undefined, undefined, null)).status).toBe(401);
    expect(f.calls).toHaveLength(0);
  });
  test('browser origin, JSON and bearer-only auth prevent CSRF; native bearer and trusted Web work', async () => {
    const f = await fixture(); const path = '/v1/instance/providers/openai/api-key';
    expect((await f.request(path, keyBody(), f.ownerAuth.token, { Origin: 'https://evil.example' })).status).toBe(403);
    expect((await f.request(path, keyBody(), f.ownerAuth.token, { Origin: 'null' })).status).toBe(403);
    expect((await f.request(path, keyBody(), null, { Cookie: `session=${f.ownerAuth.token}`, Origin: 'https://lemon.example' })).status).toBe(401);
    expect((await f.request(path, keyBody(), f.ownerAuth.token, { 'Content-Type': 'text/plain', Origin: 'https://lemon.example' })).status).toBe(415);
    const defaultBody = { ...nonce(), targetId: 'controller:mock-instance', providerId: 'openai', modelId: 'gpt-mock-static' };
    expect((await f.request('/v1/instance/providers/default', defaultBody, f.ownerAuth.token, { Origin: 'https://evil.example' })).status).toBe(403);
    expect((await f.request('/v1/instance/providers/default', defaultBody, null, { Cookie: `session=${f.ownerAuth.token}` })).status).toBe(401);
    expect((await f.request('/v1/instance/providers/openai/disconnect', { ...nonce(), targetId: 'controller:mock-instance' }, f.ownerAuth.token, { Origin: 'https://evil.example' })).status).toBe(403);
    expect(f.calls).toHaveLength(0);
    expect((await f.request(path, keyBody(), f.ownerAuth.token, { Origin: 'https://lemon.example' })).status).toBe(200);
    expect((await f.request(path, keyBody())).status).toBe(200);
  });
  test('API key add/replace never echoes, logs or stores the credential in product state or nonce receipts', async () => {
    const f = await fixture(); const path = '/v1/instance/providers/openai/api-key'; const body = keyBody();
    const logs: string[] = []; const spies = ['log', 'info', 'warn', 'error', 'debug'].map(name => spyOn(console, name as 'log').mockImplementation((...args: unknown[]) => { logs.push(JSON.stringify(args)); }));
    try {
      const first = await f.request(path, body); expect(first.status).toBe(200);
      const firstText = await first.text(); expect(firstText).not.toContain(mockKey);
      expect(JSON.parse(firstText).providers[0]).toMatchObject({ configured: true, status: 'ready' });
      expect(await (await f.request(path, body)).text()).toBe(firstText);
      expect((await f.request(path, { ...keyBody(), value: 'mock-replacement-not-live' })).status).toBe(200);
      expect(f.calls.filter(value => value.mutation)).toHaveLength(2);
      const records = f.store.db.query('SELECT value FROM entities').all();
      const metadata = f.store.db.query('SELECT * FROM metadata').all();
      const nonces = f.store.db.query('SELECT * FROM nonces').all() as { receipt: string }[];
      expect(JSON.stringify({ records, metadata, nonces })).not.toContain(mockKey);
      for (const record of nonces) expect(JSON.stringify(f.services.decrypt(record.receipt))).not.toContain(mockKey);
      expect(JSON.stringify(logs)).not.toContain(mockKey);
      expect(await (await f.request()).text()).not.toContain(mockKey);
    } finally { for (const spy of spies) spy.mockRestore(); }
    expect((await f.request(path, undefined, f.ownerAuth.token, {}, 'GET')).status).toBe(404);
  });
  test('provider and target are validated before dispatch; default never changes with add or disconnect', async () => {
    const f = await fixture();
    const existingBot = f.addBot('owner');
    for (const [id, body] of [['not-supported', keyBody()], ['unsupported_mock', keyBody()], ['openai', { ...keyBody(), targetId: 'other-target' }], ['openai', { ...keyBody(), default: true }], ['openai', { ...keyBody(), value: '   ' }]] as const) {
      expect((await f.request(`/v1/instance/providers/${id}/api-key`, body)).status).toBeGreaterThanOrEqual(400);
    }
    expect(f.calls.some(value => value.mutation)).toBe(false);
    expect((await f.request('/v1/instance/providers/openai/api-key', keyBody())).status).toBe(200);
    expect(f.listings.get('controller')!.default).toEqual({ providerId: null, modelId: null });
    expect((await f.request('/v1/instance/providers/default', { ...nonce(), targetId: 'controller:mock-instance', providerId: 'openai', modelId: 'gpt-mock-static' })).status).toBe(200);
    expect(f.listings.get('controller')!.default).toEqual({ providerId: 'openai', modelId: 'gpt-mock-static' });
    expect((await f.request('/v1/instance/providers/openai/disconnect', { ...nonce(), targetId: 'controller:mock-instance' })).status).toBe(200);
    expect(f.listings.get('controller')!.default.providerId).toBe('openai');
    expect(f.store.list('bots')).toEqual([existingBot]);
  });
  test('machine credentials route only to the selected actual-owner durable node, not the controller or another host', async () => {
    const f = await fixture();
    const second = { ...f.machine, id: 'second-machine', nodeId: 'node-second' }; f.store.put('machines', second);
    const path = `/v1/machines/${f.machine.id}/providers`;
    expect((await f.request(path)).status).toBe(200);
    expect((await f.request(`${path}/openai/api-key`, { ...keyBody(), targetId: 'node:node-owned' })).status).toBe(200);
    expect(f.calls.at(-1)).toMatchObject({ method: 'node.providers.management.api_key.set', params: { nodeId: 'node-owned', targetId: 'node:node-owned' }, mutation: true });
    expect(f.listings.get('node-owned')!.providers[0]!.status).toBe('ready');
    expect(f.listings.get('node-second')!.providers[0]!.status).toBe('needs_login');
    expect(f.listings.get('controller')!.providers[0]!.status).toBe('needs_login');
    f.store.put('machines', { ...f.machine, ownerUserId: 'alice', accessUserIds: ['owner'] });
    const before = f.calls.length;
    expect((await f.request(path)).status).toBe(403);
    expect((await f.request(`${path}/openai/api-key`, { ...keyBody(), targetId: 'node:node-owned' })).status).toBe(403);
    expect(f.calls.length).toBe(before);
  });
  test('target mismatch receipts fail closed; offline or unsupported machines cannot fall back to controller', async () => {
    const f = await fixture(); const path = `/v1/machines/${f.machine.id}/providers`;
    f.listings.get('node-owned')!.target.nodeId = 'node-second';
    expect((await f.request(path)).status).toBe(503);
    f.store.put('machines', { ...f.machine, status: 'offline' });
    expect((await f.request(path)).status).toBe(503);
    f.services.lemon.methods = [];
    expect((await f.request()).status).toBe(503);
    expect(f.calls).toHaveLength(1);
  });
  test('revoked bearer or reassigned target during the read cannot mutate; nonce replay rechecks target ownership', async () => {
    const f = await fixture();
    f.onList(() => { f.store.put('sessionSecrets', { ...f.store.require<{ id: string }>('sessionSecrets', f.ownerAuth.session.id), revoked: true }); });
    expect((await f.request('/v1/instance/providers/openai/api-key', keyBody())).status).toBe(401);
    expect(f.calls.some(value => value.mutation)).toBe(false);
    const g = await fixture(); const path = `/v1/machines/${g.machine.id}/providers/openai/api-key`; const body = { ...keyBody(), targetId: 'node:node-owned' };
    expect((await g.request(path, body)).status).toBe(200);
    g.store.put('machines', { ...g.machine, ownerUserId: 'alice' });
    expect((await g.request(path, body)).status).toBe(403);
    expect(g.calls.filter(value => value.mutation)).toHaveLength(1);
  });
  test('foreign backend sessions, revoked paired devices and disabled workspaces have no provider authority', async () => {
    const f = await fixture(); const foreign = await fixture();
    expect((await f.request(undefined, undefined, foreign.ownerAuth.token)).status).toBe(401);
    const device: P.Device = f.services.resource('device', { userId: 'owner', name: 'Mock phone', platform: 'ios', appVersion: 'mock', pushEnabled: false, lastSeenAtMs: f.services.now() });
    f.store.put('devices', device);
    const paired = await f.services.auth.session('owner', device.id, { persistent: true });
    expect((await f.request(undefined, undefined, paired.token)).status).toBe(200);
    f.store.remove('devices', device.id);
    expect((await f.request('/v1/instance/providers/openai/api-key', keyBody(), paired.token)).status).toBe(401);
    f.store.put('workspaces', { ...f.workspace, enabled: false });
    expect((await f.request('/v1/instance/providers/openai/api-key', keyBody())).status).toBe(403);
    expect(f.calls.some(value => value.mutation)).toBe(false);
  });
  test('reassignment during listing and changed durable target on nonce replay are fenced', async () => {
    const f = await fixture(); const path = `/v1/machines/${f.machine.id}/providers/openai/api-key`;
    f.onList(() => { f.store.put('machines', { ...f.machine, nodeId: 'node-second' }); });
    expect((await f.request(path, { ...keyBody(), targetId: 'node:node-owned' })).status).toBe(409);
    expect(f.calls.some(value => value.mutation)).toBe(false);
    const g = await fixture(); const body = keyBody();
    expect((await g.request('/v1/instance/providers/openai/api-key', body)).status).toBe(200);
    g.listings.get('controller')!.target.id = 'controller:replacement';
    expect((await g.request('/v1/instance/providers/openai/api-key', body)).status).toBe(409);
    expect(g.calls.filter(value => value.mutation)).toHaveLength(1);
  });
  test('unexpected upstream credential echo or credential-bearing error never reaches clients or durable error receipts', async () => {
    for (const unsafe of [false, true]) {
      const f = await fixture(); if (unsafe) f.unsafe(); else f.failWith(new ApiError('outcome_unknown', `mock transport failure ${mockKey}`, false));
      const response = await f.request('/v1/instance/providers/openai/api-key', keyBody()); expect(response.status).toBe(409);
      expect(await response.text()).not.toContain(mockKey);
      const rows = f.store.db.query('SELECT receipt FROM nonces').all() as { receipt: string }[];
      for (const row of rows) expect(JSON.stringify(f.services.decrypt(row.receipt))).not.toContain(mockKey);
    }
  });
});
