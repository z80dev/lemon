import { describe, expect, spyOn, test } from 'bun:test';
import { createHash, randomBytes } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import { authFixture } from './auth.test';
import { createProviderRoutes } from '../../src/core/providers';
import { Router } from '../../src/core/router';
import { ApiError } from '../../src/core/errors';
import { providerAuthorityGeneration, providerCompletionCollection, settleProviderCompletions } from '../../src/core/provider_completion';
import type { BackendServices, EntityStore } from '../../src/core/services';
import { createLemonService, type ControlSocket } from '../../src/runtime/lemon';

const nonce = () => ({ clientNonce: crypto.randomUUID() });
const mockKey = 'mock-provider-key-not-a-live-credential';
interface MockProviderCall { method: string; params: Record<string, unknown>; mutation: boolean }
interface ProviderRevocationFixture { store: EntityStore; services: BackendServices; machine: P.Machine; workspace: P.Workspace }
/** Mock provider/controller transport only; real product auth, router, nonce journal and SQLite. */
async function fixture(realAdapter = false) {
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
  const calls: MockProviderCall[] = [];
  let onList: (() => void) | undefined;
  let failure: unknown;
  let failureMethod: string | undefined;
  let unsafeReceipt = false;
  const deviceLogins = new Map<string, { binding: Record<string, unknown>; status: P.ProviderDeviceLoginStatus; ready: boolean; challenge: { nonce: string; deadline: number } | null }>();
  const spentLogins = new Set<string>();
  let deviceReply: ((value: P.ProviderDeviceLogin) => unknown) | undefined;
  let onDevice: (() => void) | undefined;
  let beforeComplete: (() => Promise<void> | void) | undefined;
  let beforeChallenge: (() => Promise<void> | void) | undefined;
  let targetMonotonicMs = 0;
  let targetWallMs = f.services.now();
  const completions = new Set<string>();
  let secretWrites = 0;
  let configWrites = 0;
  const methods = ['list', 'api_key.set', 'disconnect', 'default.set', 'device.start', 'device.poll', 'device.challenge', 'device.cancel', 'device.complete'].flatMap(action => [`providers.management.${action}`, `node.providers.management.${action}`]);
  f.services.lemon = {
    connected: true, methods, controller: { url: f.services.config.controlUrl, state: 'connected', connectedAtMs: f.services.now(), lastDisconnectedAtMs: null, lastError: null, nextRetryAtMs: null, methodCount: methods.length },
    async call<T>(method: string, params: Record<string, unknown> = {}, options?: { mutation?: boolean }) {
      const mutating = options?.mutation === true;
      calls.push({ method, params, mutation: mutating });
      const result = listings.get(typeof params.nodeId === 'string' ? params.nodeId : 'controller')!;
      if (method.endsWith('.list')) { onList?.(); return structuredClone(result) as T; }
      if (failure && (!failureMethod || method.endsWith(failureMethod))) throw failure;
      if (method.includes('.device.')) {
        const identity = `${params.targetId}:${params.loginId}`;
        const binding = Object.fromEntries(Object.entries(params).filter(([key]) => !['completionId', 'challengeNonce', 'commit'].includes(key)));
        let login = deviceLogins.get(identity);
        if (login && JSON.stringify(login.binding) !== JSON.stringify(binding)) {
          throw new ApiError('forbidden', 'Mock target rejected another owner/session binding.', method.endsWith('device.challenge'),
            method.endsWith('device.complete') ? { reason: 'provider_binding_rejected', mutationMayHaveApplied: false } : undefined);
        }
        if (method.endsWith('device.start') && !login && !spentLogins.has(identity)) {
          spentLogins.add(identity);
          login = { binding: structuredClone(binding), status: 'pending', ready: false, challenge: null };
          deviceLogins.set(identity, login);
        }
        if (method.endsWith('device.cancel') && login && ['starting', 'pending'].includes(login.status)) login.status = 'cancelled';
        if (method.endsWith('device.challenge')) {
          if (login?.status === 'pending' && login.ready && (!login.challenge || login.challenge.deadline <= targetMonotonicMs)) {
            login.challenge = { nonce: randomBytes(32).toString('base64url'), deadline: targetMonotonicMs + 5000 };
          }
          await beforeChallenge?.();
          login = deviceLogins.get(identity);
        }
        if (method.endsWith('device.complete')) {
          await beforeComplete?.();
          login = deviceLogins.get(identity);
          if (!completions.has(String(params.completionId))) {
            completions.add(String(params.completionId));
            const challenge = login?.challenge;
            if (params.commit === true && challenge && challenge.nonce === params.challengeNonce && challenge.deadline > targetMonotonicMs && login?.ready && login.status === 'pending') {
              secretWrites++; configWrites++; login.status = 'completed';
            }
            if (login) login.challenge = null;
          }
        }
        const status = login?.status ?? 'lost';
        const response: P.ProviderDeviceLogin = {
          loginId: params.loginId as string, targetId: params.targetId as string, providerId: 'openai_codex', status,
          verificationUrl: status === 'pending' ? 'https://auth.openai.com/codex/device' : null,
          userCode: status === 'pending' ? 'MOCK-1234' : null,
          expiresAtMs: status === 'pending' ? targetWallMs + 300_000 : null,
          pollIntervalMs: status === 'pending' ? 5000 : null,
        };
        onDevice?.();
        const internal = method.endsWith('device.challenge')
          ? { ...response, challengeNonce: login?.status === 'pending' && login.ready ? login.challenge?.nonce ?? null : null }
          : response;
        return (deviceReply ? deviceReply(internal) : internal) as T;
      }
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
  if (realAdapter) {
    const target = f.services.lemon;
    let handlers: Parameters<ControlSocket['listen']>[0] | undefined;
    const socket: ControlSocket = {
      listen(value) { handlers = value; },
      close() { handlers?.closed(); },
      send(text) {
        const frame = JSON.parse(text) as { id: string; method: string; params: Record<string, unknown> };
        if (frame.method === 'connect') {
          handlers!.frame(JSON.stringify({ type: 'hello-ok', protocol: 1, features: { methods }, auth: { role: 'operator' } }));
          return;
        }
        void target.call(frame.method, frame.params, { mutation: !frame.method.endsWith('.list') && !frame.method.endsWith('device.challenge') }).then(
          payload => handlers!.frame(JSON.stringify({ type: 'res', id: frame.id, ok: true, payload })),
          (error: unknown) => {
            if (!(error instanceof ApiError)) throw error;
            handlers!.frame(JSON.stringify({ type: 'res', id: frame.id, ok: false, error: {
              code: error.code.toUpperCase(), message: error.message, details: { ...error.details, retrySafe: error.retrySafe },
            } }));
          },
        );
      },
    };
    f.services.lemon = createLemonService(f.services.config, { socket: () => socket });
    f.services.lemon.start(); handlers!.open();
  }
  const router = new Router(f.services); router.register(createProviderRoutes(f.services));
  async function request(path = '/v1/instance/providers', body?: unknown, token: string | null = owner.token, headers: Record<string, string> = {}, method = body === undefined ? 'GET' : path.endsWith('/api-key') ? 'PUT' : 'POST') {
    return router.fetch(new Request(`https://lemon.example${path}`, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  }
  return {
    ...f, ownerAuth: owner, adminAuth: admin, memberAuth: member, machine, listings, calls, request,
    onList(callback: () => void) { onList = callback; }, failWith(error: unknown, method?: string) { failure = error; failureMethod = method; }, unsafe() { unsafeReceipt = true; },
    onDevice(callback: () => void) { onDevice = callback; },
    deviceReply(callback: (value: P.ProviderDeviceLogin) => unknown) { deviceReply = callback; },
    deviceStatus(loginId: string, status: P.ProviderDeviceLoginStatus, targetId = 'controller:mock-instance') { deviceLogins.get(`${targetId}:${loginId}`)!.status = status; },
    restartDeviceRuntime() { deviceLogins.clear(); },
    oauthSuccess(loginId: string, targetId = 'controller:mock-instance') { deviceLogins.get(`${targetId}:${loginId}`)!.ready = true; },
    writes() { return { secrets: secretWrites, config: configWrites }; },
    beforeComplete(callback?: () => Promise<void> | void) { beforeComplete = callback; },
    beforeChallenge(callback?: () => Promise<void> | void) { beforeChallenge = callback; },
    advanceTarget(ms: number) { targetMonotonicMs += ms; },
    targetWall(ms: number) { targetWallMs = ms; },
  };
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

describe('Codex device login product boundary with MOCK target transport', () => {
  const base = '/v1/instance/providers/openai_codex/device-login';
  const body = () => ({ ...nonce(), targetId: 'controller:mock-instance' });
  const deviceCalls = (f: { calls: MockProviderCall[] }) => f.calls.filter(value => value.method.includes('.device.'));

  test('device start uses the canonical underscore provider ID advertised by target onboarding metadata', async () => {
    const f = await fixture();
    const listing: P.ProviderManagement = await (await f.request()).json();
    const provider = listing.providers.find(value => value.methods.includes('device_code'))!;
    expect(provider.id).toBe('openai_codex');
    const response = await f.request(`/v1/instance/providers/${provider.id}/device-login`, body());
    expect(response.status).toBe(200);
    expect((await response.json()).providerId).toBe(provider.id);
    expect(deviceCalls(f)[0]!.params.providerId).toBe(provider.id);
  });

  test('start, fixed-nonce poll and cancel reconcile fresh target status with exact owner/session bindings', async () => {
    const f = await fixture(); const start = body();
    const response = await f.request(base, start, f.ownerAuth.token, { Origin: 'https://lemon.example' });
    expect(response.status).toBe(200); expect(response.headers.get('Cache-Control')).toBe('no-store');
    expect(await response.json()).toEqual({
      loginId: start.clientNonce, targetId: start.targetId, providerId: 'openai_codex', status: 'pending',
      verificationUrl: 'https://auth.openai.com/codex/device', userCode: 'MOCK-1234',
      expiresAtMs: f.services.now() + 300_000, pollIntervalMs: 5000,
    });
    const expected = {
      targetId: start.targetId, providerId: 'openai_codex', loginId: start.clientNonce,
      ownerId: createHash('sha256').update(JSON.stringify(['lemon_bot', 'provider_owner', f.workspace.id, 'owner'])).digest('hex'),
      sessionId: createHash('sha256').update(JSON.stringify(['lemon_bot', 'provider_session', f.ownerAuth.session.id])).digest('hex'),
    };
    expect(deviceCalls(f)).toEqual([{ method: 'providers.management.device.start', params: expected, mutation: true }]);
    const poll = body(); const pollPath = `${base}/${start.clientNonce}/poll`;
    expect((await (await f.request(pollPath, poll)).json()).status).toBe('pending');
    f.deviceStatus(start.clientNonce, 'completed');
    expect((await (await f.request(pollPath, poll)).json()).status).toBe('completed');
    expect((await (await f.request(base, start)).json()).status).toBe('completed');
    const cancel = body(); const cancelPath = `${base}/${start.clientNonce}/cancel`;
    expect((await (await f.request(cancelPath, cancel)).json()).status).toBe('completed');
    expect((await (await f.request(cancelPath, cancel)).json()).status).toBe('completed');
    for (const call of deviceCalls(f)) expect(Object.fromEntries(Object.entries(call.params).filter(([key]) => !['completionId', 'challengeNonce', 'commit'].includes(key)))).toEqual(expected);
    expect(f.listings.get('controller')!.default).toEqual({ providerId: null, modelId: null });
    expect((await f.request(pollPath, { ...poll, targetId: 'controller:wrong' })).status).toBe(409);
    expect((await f.request(pollPath, { ...poll, ownerId: 'forged' })).status).toBe(400);
    expect((await f.request(pollPath, start)).status).toBe(400);
    expect((await f.request(`${base}/short/cancel`, cancel)).status).toBe(400);
  });

  test('fixed nonce intent conflicts survive result changes and runtime restart never returns cached success', async () => {
    const f = await fixture(); const start = body();
    expect((await f.request(base, start)).status).toBe(200);
    f.deviceStatus(start.clientNonce, 'completed');
    expect((await (await f.request(base, start)).json()).status).toBe('completed');
    f.restartDeviceRuntime();
    for (const path of [base, `${base}/${start.clientNonce}/poll`, `${base}/${start.clientNonce}/cancel`]) {
      const response = await f.request(path, path === base ? start : body());
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ loginId: start.clientNonce, targetId: start.targetId, providerId: 'openai_codex', status: 'lost', verificationUrl: null, userCode: null, expiresAtMs: null, pollIntervalMs: null });
    }
    f.listings.get('controller')!.target.id = 'controller:replacement';
    expect((await f.request(base, { ...start, targetId: 'controller:replacement' })).status).toBe(409);
    expect(deviceCalls(f)).toHaveLength(5);
  });

  test('starting, denial, expiry, cancellation and failure are safe explicit target statuses', async () => {
    const f = await fixture(); const start = body(); await f.request(base, start);
    const poll = body(); const path = `${base}/${start.clientNonce}/poll`;
    for (const status of ['starting', 'denied', 'expired', 'failed'] as const) {
      f.deviceStatus(start.clientNonce, status);
      const response = await f.request(path, poll); expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ loginId: start.clientNonce, targetId: start.targetId, providerId: 'openai_codex', status, verificationUrl: null, userCode: null, expiresAtMs: null, pollIntervalMs: null });
    }
    f.deviceStatus(start.clientNonce, 'pending');
    const cancel = body();
    expect((await (await f.request(`${base}/${start.clientNonce}/cancel`, cancel)).json()).status).toBe('cancelled');
    expect((await (await f.request(path, poll)).json()).status).toBe('cancelled');
    expect((await (await f.request(base, start)).json()).status).toBe('cancelled');
  });

  test('all operations require current owner bearer, JSON and trusted browser origin, never cookies', async () => {
    const f = await fixture(); const loginId = crypto.randomUUID();
    for (const path of [base, `${base}/${loginId}/poll`, `${base}/${loginId}/cancel`]) {
      for (const token of [f.adminAuth.token, f.memberAuth.token]) expect((await f.request(path, body(), token)).status).toBe(403);
      expect((await f.request(path, body(), null)).status).toBe(401);
      expect((await f.request(path, body(), null, { Cookie: `session=${f.ownerAuth.token}`, Origin: 'https://lemon.example' })).status).toBe(401);
      for (const Origin of ['https://evil.example', 'null']) expect((await f.request(path, body(), f.ownerAuth.token, { Origin })).status).toBe(403);
      expect((await f.request(path, body(), f.ownerAuth.token, { 'Content-Type': 'text/plain' })).status).toBe(415);
    }
    expect(f.calls).toHaveLength(0);
    expect((await f.request(base, body())).status).toBe(200);
  });

  test('strict canonical provider, route identity, target and capability checks run before device dispatch', async () => {
    const f = await fixture();
    for (const provider of ['openai', 'openai-codex', 'unsupported_mock']) {
      expect((await f.request(base.replace('openai_codex', provider), body())).status).toBe(400);
    }
    for (const extra of [{ loginId: crypto.randomUUID() }, { ownerId: 'forged' }, { sessionId: 'forged' }, { providerId: 'openai_codex' }, { value: mockKey }, { challengeNonce: 'forged' }]) {
      expect((await f.request(base, { ...body(), ...extra })).status).toBe(400);
    }
    expect((await f.request(base, { ...body(), targetId: 'other-target' })).status).toBe(409);
    expect((await f.request(`${base}?targetId=other`, body())).status).toBe(400);
    f.listings.get('controller')!.providers.find(value => value.id === 'openai_codex')!.methods = ['api_key'];
    expect((await f.request(base, body())).status).toBe(503);
    f.listings.get('controller')!.providers.find(value => value.id === 'openai_codex')!.methods = ['device_code'];
    for (const action of ['start', 'poll', 'cancel']) {
      f.services.lemon.methods = f.services.lemon.methods.filter(value => value !== `providers.management.device.${action}`);
      expect((await f.request(action === 'start' ? base : `${base}/${crypto.randomUUID()}/${action}`, body())).status).toBe(503);
    }
    expect(deviceCalls(f)).toHaveLength(0);
    expect((await f.request(`${base}/${crypto.randomUUID()}/challenge`, body())).status).toBe(404);
  });

  test('another actual session or workspace cannot reuse an owner login or its nonce receipt', async () => {
    const f = await fixture(); const start = body(); await f.request(base, start);
    const second = await f.services.auth.session('owner');
    expect((await f.request(base, start, second.token)).status).toBe(409);
    for (const action of ['poll', 'cancel']) {
      const response = await f.request(`${base}/${start.clientNonce}/${action}`, body(), second.token);
      expect(response.status).toBe(403); expect(await response.text()).not.toContain('MOCK-1234');
    }
    const anotherOwner = f.addUser('second-owner', 'owner'); const otherSession = await f.services.auth.session(anotherOwner.userId);
    expect((await f.request(`${base}/${start.clientNonce}/poll`, body(), otherSession.token)).status).toBe(403);
    const foreign = await fixture();
    expect((await f.request(base, body(), foreign.ownerAuth.token)).status).toBe(401);
    await foreign.request(base, body());
    expect(deviceCalls(foreign)[0]!.params.ownerId).not.toBe(deviceCalls(f)[0]!.params.ownerId);
    expect(deviceCalls(f)[1]!.params.sessionId).not.toBe(deviceCalls(f)[0]!.params.sessionId);
    expect(deviceCalls(f)[3]!.params.ownerId).not.toBe(deviceCalls(f)[0]!.params.ownerId);
  });

  test('node operations stay on the actual owned target and replay rechecks ownership and durable placement', async () => {
    const f = await fixture(); const start = { ...body(), targetId: 'node:node-owned' };
    const path = `/v1/machines/${f.machine.id}/providers/openai_codex/device-login`;
    expect((await f.request(path, start)).status).toBe(200);
    expect(deviceCalls(f)[0]).toMatchObject({ method: 'node.providers.management.device.start', params: { nodeId: 'node-owned', targetId: start.targetId, loginId: start.clientNonce } });
    const other = { ...f.machine, id: 'second-machine', nodeId: 'node-second' }; f.store.put('machines', other);
    const otherPath = `/v1/machines/${other.id}/providers/openai_codex/device-login/${start.clientNonce}/poll`;
    expect((await (await f.request(otherPath, { ...body(), targetId: 'node:node-second' })).json()).status).toBe('lost');
    f.store.put('machines', { ...f.machine, ownerUserId: 'alice', accessUserIds: ['owner'] });
    for (const route of [path, `${path}/${start.clientNonce}/poll`, `${path}/${start.clientNonce}/cancel`]) expect((await f.request(route, route === path ? start : { ...body(), targetId: start.targetId })).status).toBe(403);
    expect(deviceCalls(f)).toHaveLength(2);
    const g = await fixture(); const gPath = `/v1/machines/${g.machine.id}/providers/openai_codex/device-login`;
    g.onList(() => { g.store.put('machines', { ...g.machine, nodeId: 'node-second' }); });
    expect((await g.request(gPath, { ...body(), targetId: 'node:node-owned' })).status).toBe(409);
    expect(deviceCalls(g)).toHaveLength(0);
  });

  test('session, device and workspace revocation fence dispatch and late status exposure', async () => {
    for (const action of ['start', 'poll', 'cancel']) {
      const f = await fixture(); const start = body(); await f.request(base, start);
      f.onList(() => { f.store.put('sessionSecrets', { ...f.store.require<{ id: string }>('sessionSecrets', f.ownerAuth.session.id), revoked: true }); });
      expect((await f.request(action === 'start' ? base : `${base}/${start.clientNonce}/${action}`, body())).status).toBe(401);
      expect(deviceCalls(f)).toHaveLength(1);
    }
    const f = await fixture();
    f.onDevice(() => { f.store.put('sessionSecrets', { ...f.store.require<{ id: string }>('sessionSecrets', f.ownerAuth.session.id), revoked: true }); });
    const late = await f.request(base, body()); expect(late.status).toBe(401); expect(await late.text()).not.toContain('MOCK-1234');
    const g = await fixture();
    const device: P.Device = g.services.resource('device', { userId: 'owner', name: 'Mock phone', platform: 'ios', appVersion: 'mock', pushEnabled: false, lastSeenAtMs: g.services.now() });
    g.store.put('devices', device); const paired = await g.services.auth.session('owner', device.id, { persistent: true });
    const start = body(); expect((await g.request(base, start, paired.token)).status).toBe(200);
    g.store.remove('devices', device.id);
    expect((await g.request(`${base}/${start.clientNonce}/poll`, body(), paired.token)).status).toBe(401);
    g.store.put('workspaces', { ...g.workspace, enabled: false });
    expect((await g.request(base, body())).status).toBe(403);
    expect(deviceCalls(g)).toHaveLength(1);
  });

  test('start then revoke then successful MOCK OAuth never writes secrets/config, even with lost notifications', async () => {
    const revocations: ((f: ProviderRevocationFixture, device: P.Device, session: P.AuthSession) => unknown)[] = [
      (f, _device, session) => f.store.put('sessionSecrets', { ...f.store.require<{ id: string }>('sessionSecrets', session.id), revoked: true }),
      (f, _device, session) => f.store.remove('authSessions', session.id),
      (f, _device, session) => f.store.put('authSessions', { ...session, expiresAtMs: f.services.now() - 1 }),
      f => f.store.remove('users', 'owner'),
      (f, device) => f.store.remove('devices', device.id),
      (f, device) => f.store.put('devices', { ...device, userId: 'alice' }),
      f => f.store.put('members', { ...f.services.auth.member('owner'), enabled: false }),
      f => f.store.put('members', { ...f.services.auth.member('owner'), role: 'member' }),
      f => f.store.put('workspaces', { ...f.workspace, enabled: false }),
      f => f.store.setMetadata('accountDeletion:owner', { status: 'completed' }),
      f => f.store.setMetadata('governance', { groupAccess: 'selected', allowedDirectoryGroupIds: [] }),
      f => f.store.put('machines', { ...f.machine, ownerUserId: 'alice' }),
      f => f.store.put('machines', { ...f.machine, nodeId: 'node-second' }),
      f => f.store.put('machines', { ...f.machine, status: 'offline' }),
      f => f.store.remove('machines', f.machine.id),
    ];
    for (const revoke of revocations) {
      const f = await fixture();
      const device: P.Device = f.services.resource('device', { userId: 'owner', name: 'Mock phone', platform: 'ios', appVersion: 'mock', pushEnabled: false, lastSeenAtMs: f.services.now() });
      f.store.put('devices', device);
      const auth = await f.services.auth.session('owner', device.id, { persistent: true });
      const start = { ...body(), targetId: 'node:node-owned' };
      const path = `/v1/machines/${f.machine.id}/providers/openai_codex/device-login`;
      expect((await f.request(path, start, auth.token)).status).toBe(200);
      revoke(f, device, auth.session);
      // No cancel/revocation event is delivered to the mock target.
      f.oauthSuccess(start.clientNonce, start.targetId);
      expect((await f.request(`${path}/${start.clientNonce}/poll`, { ...body(), targetId: start.targetId }, auth.token)).status).toBeGreaterThanOrEqual(400);
      expect(f.writes()).toEqual({ secrets: 0, config: 0 });
      expect(deviceCalls(f)).toHaveLength(1);
      expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
    }
  });

  test('revocation succeeds immediately during an issued completion; its single-write window is bounded', async () => {
    const f = await fixture(true); const start = body();
    try {
      await f.request(base, start);
      expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
      f.oauthSuccess(start.clientNonce);
      let entered!: () => void; const entering = new Promise<void>(resolve => { entered = resolve; });
      let release!: () => void;
      f.beforeComplete(() => new Promise<void>(resolve => { release = resolve; entered(); }));
      const pending = f.request(`${base}/${start.clientNonce}/poll`, body());
      await entering;
      const completion = deviceCalls(f).at(-1)!.params;
      expect(completion.challengeNonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(completion).not.toHaveProperty('authorizationExpiresAtMs');
      expect(f.store.list<{ params: Record<string, unknown> }>(providerCompletionCollection)[0]!.params).toEqual({ ...completion, challengeNonce: '', commit: false });
      expect(f.store.list(providerCompletionCollection)).toHaveLength(1);
      const generation = providerAuthorityGeneration(f.store);
      f.store.put('sessionSecrets', { ...f.store.require<{ id: string }>('sessionSecrets', f.ownerAuth.session.id), revoked: true });
      expect(providerAuthorityGeneration(f.store)).toBeGreaterThan(generation);
      release();
      // This already-issued authorization may be admitted once within its TTL.
      expect((await pending).status).toBe(401);
      expect(f.writes()).toEqual({ secrets: 1, config: 1 });
      expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
      expect((await f.request(`${base}/${start.clientNonce}/poll`, body())).status).toBe(401);
      expect(deviceCalls(f).filter(value => value.params.commit === true)).toHaveLength(1);
    } finally { f.services.lemon.close(); }
  });

  test('uncertain completion survives route restart; non-writing settlement fences a delayed authorization', async () => {
    const f = await fixture(); const start = body(); await f.request(base, start);
    f.oauthSuccess(start.clientNonce);
    const call = f.services.lemon.call.bind(f.services.lemon);
    let delayed!: Record<string, unknown>;
    f.services.lemon.call = async <T>(method: string, params: Record<string, unknown> = {}, options?: { mutation?: boolean }) => {
      if (method.endsWith('device.complete') && params.commit === true) {
        delayed = structuredClone(params);
        throw new ApiError('outcome_unknown', 'MOCK dropped completion before delivery', false);
      }
      return call<T>(method, params, options);
    };
    expect((await f.request(`${base}/${start.clientNonce}/poll`, body())).status).toBe(409);
    expect(f.store.list(providerCompletionCollection)).toHaveLength(1);
    f.store.remove('authSessions', f.ownerAuth.session.id);
    // Recreate orchestration over the same persisted state, with no in-memory lock.
    createProviderRoutes(f.services);
    await settleProviderCompletions(f.services);
    expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
    await call('providers.management.device.complete', delayed, { mutation: true });
    expect(f.writes()).toEqual({ secrets: 0, config: 0 });
  });

  test('real adapter rejects cross-session challenges before issuance and revocation needs no reconciliation', async () => {
    const f = await fixture(true); const start = body();
    try {
      expect((await f.request(base, start)).status).toBe(200);
      const second = await f.services.auth.session('owner');
      const response = await f.request(`${base}/${start.clientNonce}/poll`, body(), second.token);
      expect(response.status).toBe(403);
      // Challenge rejection precedes completion issuance and cannot have written.
      expect((await response.json()).error.retrySafe).toBe(true);
      expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
      const generation = providerAuthorityGeneration(f.store);
      f.services.lemon.close();
      f.store.remove('authSessions', second.session.id);
      f.store.put('sessionSecrets', { ...f.store.require<{ id: string }>('sessionSecrets', f.ownerAuth.session.id), revoked: true });
      expect(providerAuthorityGeneration(f.store)).toBeGreaterThan(generation);
      expect((await f.request(`${base}/${start.clientNonce}/poll`, body())).status).toBe(401);
      expect(f.writes()).toEqual({ secrets: 0, config: 0 });
    } finally { f.services.lemon.close(); }
  });

  test('generic rejection retains the fixed journal and never permits a fresh completion retry', async () => {
    const f = await fixture(true); const start = body();
    try {
      await f.request(base, start); f.oauthSuccess(start.clientNonce);
      f.failWith(new ApiError('forbidden', 'MOCK generic pre-dispatch rejection', true, { preDispatch: true, mutationMayHaveApplied: false }), 'device.complete');
      const poll = body(); const path = `${base}/${start.clientNonce}/poll`;
      expect((await f.request(path, poll)).status).toBe(403);
      const journal = f.store.list<{ id: string; params: Record<string, unknown> }>(providerCompletionCollection);
      expect(journal).toHaveLength(1);
      expect((await f.request(path, poll)).status).toBe(409);
      expect((await f.request(path, body())).status).toBe(409);
      expect(f.store.list(providerCompletionCollection)).toEqual(journal);
      const calls = deviceCalls(f).filter(value => value.method.endsWith('device.complete'));
      expect(calls.filter(value => value.params.commit === true)).toHaveLength(1);
      expect(calls.filter(value => value.params.commit === false)).toHaveLength(2);
      for (const call of calls) expect(call.params).toEqual({ ...journal[0]!.params, commit: call.params.commit, challengeNonce: call.params.commit === true ? calls[0]!.params.challengeNonce : '' });
      // Even after expiry and revoked session/generation, settlement is non-writing
      // and the target's exact immutable binding rejection alone can release it.
      f.advanceTarget(5001);
      f.store.remove('authSessions', f.ownerAuth.session.id);
      f.failWith(new ApiError('forbidden', 'MOCK immutable binding rejection', false, { reason: 'provider_binding_rejected', mutationMayHaveApplied: false }));
      await settleProviderCompletions(f.services);
      expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
      expect(deviceCalls(f).at(-1)!.params).toEqual({ ...journal[0]!.params, commit: false });
      expect(f.writes()).toEqual({ secrets: 0, config: 0 });
    } finally { f.services.lemon.close(); }
  });

  test('offline session, device and owner revocation succeeds with a delayed completion and cannot issue another', async () => {
    for (const authority of ['session', 'device', 'owner'] as const) {
      const f = await fixture(true); const start = body();
      try {
        const device: P.Device = f.services.resource('device', { userId: 'owner', name: 'Mock phone', platform: 'ios', appVersion: 'mock', pushEnabled: false, lastSeenAtMs: f.services.now() });
        f.store.put('devices', device);
        const auth = await f.services.auth.session('owner', device.id, { persistent: true });
        await f.request(base, start, auth.token); f.oauthSuccess(start.clientNonce);
        let entered!: () => void; const entering = new Promise<void>(resolve => { entered = resolve; });
        let release!: () => void;
        f.beforeComplete(() => new Promise<void>(resolve => { release = resolve; entered(); }));
        const pending = f.request(`${base}/${start.clientNonce}/poll`, body(), auth.token);
        await entering;
        f.services.lemon.close();
        expect((await pending).status).toBe(409);
        const generation = providerAuthorityGeneration(f.store);
        if (authority === 'session') f.store.put('sessionSecrets', { ...f.store.require<{ id: string }>('sessionSecrets', auth.session.id), revoked: true });
        else if (authority === 'device') f.store.remove('devices', device.id);
        else f.store.put('members', { ...f.services.auth.member('owner'), role: 'member' });
        expect(providerAuthorityGeneration(f.store)).toBeGreaterThan(generation);
        expect(f.store.list(providerCompletionCollection)).toHaveLength(1);
        await settleProviderCompletions(f.services);
        expect(f.store.list(providerCompletionCollection)).toHaveLength(1);
        f.advanceTarget(5001);
        let finished!: () => void; const finishing = new Promise<void>(resolve => { finished = resolve; });
        f.onDevice(finished); release(); await finishing;
        expect(f.writes()).toEqual({ secrets: 0, config: 0 });
        expect((await f.request(`${base}/${start.clientNonce}/poll`, body(), auth.token)).status).toBeGreaterThanOrEqual(400);
        expect(deviceCalls(f).filter(value => value.params.commit === true)).toHaveLength(1);
      } finally { f.services.lemon.close(); }
    }
  });

  test('revoking then restoring the same authority cannot revive a durably pinned login', async () => {
    for (const authority of ['session', 'device', 'owner', 'machine', 'workspace', 'policy'] as const) {
      const f = await fixture(true);
      try {
        const device: P.Device = f.services.resource('device', { userId: 'owner', name: 'Mock phone', platform: 'ios', appVersion: 'mock', pushEnabled: false, lastSeenAtMs: f.services.now() });
        f.store.put('devices', device);
        const auth = await f.services.auth.session('owner', device.id, { persistent: true });
        const secret = f.store.require<{ id: string }>('sessionSecrets', auth.session.id);
        const member = f.services.auth.member('owner');
        const start = { ...body(), targetId: 'node:node-owned' };
        const path = `/v1/machines/${f.machine.id}/providers/openai_codex/device-login`;
        expect((await f.request(path, start, auth.token)).status).toBe(200);
        if (authority === 'session') {
          f.store.put('sessionSecrets', { ...secret, revoked: true }); f.store.put('sessionSecrets', secret);
        } else if (authority === 'device') {
          f.store.remove('devices', device.id); f.store.put('devices', device);
        } else if (authority === 'owner') {
          f.store.put('members', { ...member, role: 'member' }); f.store.put('members', member);
        } else if (authority === 'machine') {
          f.store.put('machines', { ...f.machine, nodeId: 'node-second' }); f.store.put('machines', f.machine);
        } else if (authority === 'workspace') {
          f.store.put('workspaces', { ...f.workspace, enabled: false }); f.store.put('workspaces', f.workspace);
        } else {
          const governance = f.store.metadata('governance');
          f.store.setMetadata('governance', { groupAccess: 'selected', allowedDirectoryGroupIds: [] }); f.store.setMetadata('governance', governance);
        }
        createProviderRoutes(f.services);
        f.oauthSuccess(start.clientNonce, start.targetId);
        expect((await f.request(`${path}/${start.clientNonce}/poll`, { ...body(), targetId: start.targetId }, auth.token)).status).toBe(403);
        expect((await f.request(path, start, auth.token)).status).toBe(403);
        expect(deviceCalls(f)).toHaveLength(1);
        expect(f.writes()).toEqual({ secrets: 0, config: 0 });
        const fresh = { ...body(), targetId: start.targetId };
        expect((await f.request(path, fresh, auth.token)).status).toBe(200);
      } finally { f.services.lemon.close(); }
    }
  });

  test('the challenge is internal, ready-only, and absent from public responses and durable state', async () => {
    const f = await fixture(true); const start = body();
    try {
      await f.request(base, start);
      const path = `${base}/${start.clientNonce}/poll`;
      const waiting = await f.request(path, body());
      expect(waiting.status).toBe(200);
      expect(await waiting.json()).not.toHaveProperty('challengeNonce');
      expect(deviceCalls(f).at(-1)!.method).toBe('providers.management.device.challenge');
      expect(deviceCalls(f).at(-1)!.mutation).toBe(false);
      expect(deviceCalls(f).filter(value => value.params.commit === true)).toHaveLength(0);
      f.oauthSuccess(start.clientNonce);
      const response = await f.request(path, body());
      expect(response.status).toBe(200);
      const publicResult = await response.json();
      expect(publicResult).toMatchObject({ status: 'completed' });
      expect(publicResult).not.toHaveProperty('challengeNonce');
      const calls = deviceCalls(f);
      expect(calls.at(-2)!.method).toBe('providers.management.device.challenge');
      expect(calls.at(-1)!.method).toBe('providers.management.device.complete');
      const challengeNonce = String(calls.at(-1)!.params.challengeNonce);
      expect(challengeNonce).toMatch(/^[A-Za-z0-9_-]{43}$/);
      const entities = f.store.db.query('SELECT value FROM entities').all();
      const metadata = f.store.db.query('SELECT * FROM metadata').all();
      const nonces = f.store.db.query('SELECT receipt FROM nonces').all() as { receipt: string }[];
      expect(JSON.stringify({ entities, metadata, nonces })).not.toContain(challengeNonce);
      for (const row of nonces) expect(JSON.stringify(f.services.decrypt(row.receipt))).not.toContain(challengeNonce);
      const count = f.writes();
      await f.services.lemon.call(calls.at(-1)!.method, calls.at(-1)!.params, { mutation: true });
      await f.services.lemon.call(calls.at(-1)!.method, { ...calls.at(-1)!.params, completionId: 'another-completion' }, { mutation: true });
      expect(f.writes()).toEqual(count);
    } finally { f.services.lemon.close(); }
  });

  test('session, revocation and generation are rechecked after a delayed challenge before issuance', async () => {
    for (const change of ['revoke', 'expire', 'generation', 'placement'] as const) {
      const f = await fixture(true);
      try {
        const start = { ...body(), targetId: 'node:node-owned' };
        const path = `/v1/machines/${f.machine.id}/providers/openai_codex/device-login`;
        expect((await f.request(path, start)).status).toBe(200);
        f.oauthSuccess(start.clientNonce, start.targetId);
        f.beforeChallenge(() => {
          if (change === 'expire') f.advance(30 * 86400000);
          else if (change === 'placement') f.store.put('machines', { ...f.machine, nodeId: 'node-second' });
          else {
            const secret = f.store.require<{ id: string }>('sessionSecrets', f.ownerAuth.session.id);
            f.store.put('sessionSecrets', { ...secret, revoked: true });
            if (change === 'generation') f.store.put('sessionSecrets', secret);
          }
        });
        const response = await f.request(`${path}/${start.clientNonce}/poll`, { ...body(), targetId: start.targetId });
        expect(response.status).toBeGreaterThanOrEqual(400);
        expect(deviceCalls(f).at(-1)!.method).toBe('node.providers.management.device.challenge');
        expect(deviceCalls(f).filter(value => value.params.commit === true)).toHaveLength(0);
        expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
        expect(f.writes()).toEqual({ secrets: 0, config: 0 });
      } finally { f.services.lemon.close(); }
    }
  });

  test('skewed and backward product/target wall clocks do not authorize or expire a challenge', async () => {
    for (const offset of [86_400_000, -86_400_000]) {
      const f = await fixture(true); const start = body();
      try {
        await f.request(base, start); f.oauthSuccess(start.clientNonce);
        f.beforeChallenge(() => { f.advance(offset); f.targetWall(f.services.now() - offset * 2); });
        const response = await f.request(`${base}/${start.clientNonce}/poll`, body());
        expect(response.status).toBe(200);
        expect((await response.json()).status).toBe('completed');
        expect(deviceCalls(f).at(-1)!.params).not.toHaveProperty('authorizationExpiresAtMs');
        expect(f.writes()).toEqual({ secrets: 1, config: 1 });
      } finally { f.services.lemon.close(); }
    }
    const f = await fixture(true); const start = body();
    try {
      await f.request(base, start); f.oauthSuccess(start.clientNonce);
      f.beforeComplete(() => { f.advance(-86_400_000); f.targetWall(f.services.now() - 86_400_000); f.advanceTarget(5000); });
      expect((await f.request(`${base}/${start.clientNonce}/poll`, body())).status).toBe(200);
      expect(f.writes()).toEqual({ secrets: 0, config: 0 });
    } finally { f.services.lemon.close(); }
  });

  test('challenge response delay consumes its original monotonic window and restart invalidates it', async () => {
    for (const interrupted of ['delayed', 'restart'] as const) {
      const f = await fixture(true); const start = body();
      try {
        await f.request(base, start); f.oauthSuccess(start.clientNonce);
        if (interrupted === 'delayed') f.beforeChallenge(() => { f.advanceTarget(5000); });
        else f.beforeComplete(() => { f.restartDeviceRuntime(); });
        expect((await f.request(`${base}/${start.clientNonce}/poll`, body())).status).toBe(200);
        expect(f.writes()).toEqual({ secrets: 0, config: 0 });
        expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
      } finally { f.services.lemon.close(); }
    }
  });

  test('malformed internal challenges cannot issue completion or enter public/durable state', async () => {
    const privateValue = 'MOCK-private-challenge-data';
    const invalid: ((value: P.ProviderDeviceLogin) => unknown)[] = [
      value => Object.fromEntries(Object.entries(value).filter(([key]) => key !== 'challengeNonce')),
      value => ({ ...value, challengeNonce: '' }),
      value => ({ ...value, challengeNonce: 123 }),
      value => ({ ...value, challengeNonce: privateValue }),
      value => ({ ...value, access_token: privateValue }),
      value => ({ ...value, status: 'completed', verificationUrl: null, userCode: null, expiresAtMs: null, pollIntervalMs: null }),
    ];
    for (const reply of invalid) {
      const f = await fixture(); const start = body();
      await f.request(base, start); f.oauthSuccess(start.clientNonce);
      f.deviceReply(reply);
      const response = await f.request(`${base}/${start.clientNonce}/poll`, body());
      expect(response.status).toBe(409);
      expect(await response.text()).not.toContain(privateValue);
      expect(deviceCalls(f).filter(value => value.params.commit === true)).toHaveLength(0);
      expect(f.store.list(providerCompletionCollection)).toHaveLength(0);
      expect(f.writes()).toEqual({ secrets: 0, config: 0 });
      const entities = f.store.db.query('SELECT value FROM entities').all();
      const metadata = f.store.db.query('SELECT * FROM metadata').all();
      const receipts = f.store.db.query('SELECT receipt FROM nonces').all() as { receipt: string }[];
      expect(JSON.stringify({ entities, metadata, receipts })).not.toContain(privateValue);
      for (const row of receipts) expect(JSON.stringify(f.services.decrypt(row.receipt))).not.toContain(privateValue);
    }
  });

  test('completion generation is checked synchronously after the challenge round trip', async () => {
    const f = await fixture(true); const start = body();
    try {
      f.store.put('authSessions', { ...f.ownerAuth.session, expiresAtMs: f.services.now() + 1250 });
      expect((await f.request(base, start)).status).toBe(200);
      f.oauthSuccess(start.clientNonce);
      expect((await f.request(`${base}/${start.clientNonce}/poll`, body())).status).toBe(200);
      expect(deviceCalls(f).at(-1)!.params).not.toHaveProperty('authorizationExpiresAtMs');
      const secret = f.store.require<{ id: string }>('sessionSecrets', f.ownerAuth.session.id);
      f.beforeChallenge(() => {
        f.store.put('sessionSecrets', { ...secret, revoked: true });
        f.store.put('sessionSecrets', secret);
      });
      expect((await f.request(`${base}/${start.clientNonce}/poll`, body())).status).toBe(409);
      expect(deviceCalls(f).filter(value => value.params.commit === true)).toHaveLength(1);
    } finally { f.services.lemon.close(); }
  });

  test('unsafe response keys, URLs, identities, field shapes and secret-bearing errors never escape or persist', async () => {
    const secret = 'MOCK-device-secret-token-DO-NOT-PERSIST';
    const unsafe: ((value: P.ProviderDeviceLogin) => unknown)[] = [
      value => ({ ...value, device_code: secret }), value => ({ ...value, access_token: secret }),
      value => ({ ...value, refresh_token: secret }), value => ({ ...value, verifier: secret }),
      value => ({ ...value, verificationUrl: `https://auth.openai.com/codex/device?token=${secret}` }),
      value => ({ ...value, verificationUrl: 'https://evil.example/codex/device' }),
      value => ({ ...value, targetId: 'controller:other' }), value => ({ ...value, loginId: crypto.randomUUID() }),
      value => ({ ...value, providerId: 'openai' }), value => ({ ...value, status: 'success' }),
      value => ({ ...value, userCode: secret.repeat(3) }), value => ({ ...value, userCode: '<script>' }),
      value => ({ ...value, pollIntervalMs: 0 }), value => ({ ...value, expiresAtMs: -1 }),
      value => ({ ...value, status: 'completed' }), value => ({ ...value, verificationUrl: null }),
    ];
    const logs: string[] = []; const spies = ['log', 'info', 'warn', 'error', 'debug'].map(name => spyOn(console, name as 'log').mockImplementation((...args: unknown[]) => { logs.push(JSON.stringify(args)); }));
    try {
      for (const reply of [...unsafe, null]) {
        const f = await fixture();
        if (reply) f.deviceReply(reply); else f.failWith(new ApiError('outcome_unknown', `Mock secret-bearing error ${secret}`, false, { secret }));
        const response = await f.request(base, body()); expect(response.status).toBe(409);
        expect(await response.text()).not.toContain(secret);
        const entities = f.store.db.query('SELECT value FROM entities').all();
        const metadata = f.store.db.query('SELECT * FROM metadata').all();
        const nonces = f.store.db.query('SELECT * FROM nonces').all() as { receipt: string }[];
        expect(JSON.stringify({ entities, metadata, nonces })).not.toContain(secret);
        for (const row of nonces) expect(f.services.decrypt(row.receipt)).toEqual({ ok: true, value: { ok: true } });
      }
      const f = await fixture(); const start = body(); await f.request(base, start);
      const nonces = f.store.db.query('SELECT receipt FROM nonces').all() as { receipt: string }[];
      for (const row of nonces) expect(JSON.stringify(f.services.decrypt(row.receipt))).not.toContain('MOCK-1234');
      expect(JSON.stringify(logs)).not.toContain(secret);
    } finally { for (const spy of spies) spy.mockRestore(); }
  });
});
