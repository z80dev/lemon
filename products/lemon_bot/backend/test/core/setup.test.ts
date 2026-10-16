import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type * as P from '../../../contracts/protocol';
import { preflightBotOrigin } from '../../../contracts/preflight';
import { createBackend, type BackendInstance } from '../../src/index';
import { loadConfiguration } from '../../src/core/config';
import { opaqueToken } from '../../src/core/auth';
import { createAccountRoutes } from '../../src/core/accounts';
import { issueOwnerSetupProof, ownerSetupAttemptLimit, ownerSetupLifetimeMs } from '../../src/core/setup';

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanups.splice(0)) await close(); });
const password = 'Isolated bootstrap test password 42';

/** Isolated real backend/SQLite/encryption/auth. MOCK controller identity; no provider credentials or live token exchange. */
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-owner-setup-'));
  const configuration = await loadConfiguration({ LEMON_BOT_DATA_DIR: directory, LEMON_BOT_OPERATOR_TOKEN: 'MOCK-controller-operator',
    LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:1/ws', LEMON_BOT_PUBLIC_URL: 'https://bootstrap.mock-tailnet.ts.net' });
  let backend: BackendInstance;
  let clock = 1791940000000;
  async function open() { backend = await createBackend(configuration.config, configuration.key); backend.services.now = () => clock; }
  await open();
  cleanups.push(async () => { await backend.stop(); await rm(directory, { recursive: true, force: true }); });
  return {
    get backend() { return backend; }, get services() { return backend.services; }, get store() { return backend.services.store; },
    advance(ms: number) { clock += ms; },
    async restart() { await backend.stop(); await open(); },
    async request(method: string, path: string, body?: unknown, token?: string, headers: Record<string, string> = {}) {
      return backend.router.fetch(new Request(`${configuration.config.publicUrl}${path}`, { method,
        headers: { ...(body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
        ...(body ? { body: JSON.stringify(body) } : {}) }));
    },
  };
}
function claim(code: string, overrides: Partial<P.SetupRequest> = {}): P.SetupRequest {
  return { clientNonce: opaqueToken(), setupCode: code, email: 'owner@example.com', password, displayName: 'Owner', workspaceName: 'My existing backend', ...overrides };
}
async function error(response: Response, status: number, code: P.ErrorCode) {
  expect(response.status).toBe(status);
  const body = await response.json() as P.ErrorEnvelope;
  expect(body.error.code).toBe(code);
  return body;
}

describe('provider-free local owner bootstrap', () => {
  test('no remote issuance or URL/membership authority; TLS preflight explicitly distinguishes empty setup from pairing', async () => {
    const f = await fixture(); const instanceId = f.store.metadata<string>('instanceId')!;
    const setup = await (await f.request('GET', '/v1/setup')).json() as P.SetupStatus;
    expect(setup.setupRequired).toBe(true); expect(setup).not.toHaveProperty('workspaceId'); expect(setup).not.toHaveProperty('setupCode');
    expect(f.store.metadata('setupCode')).toBeNull();
    const fetchMock = ((input: RequestInfo | URL, init?: RequestInit) => {
      // MOCK network transport only; exercises real descriptor/router and shared preflight.
      expect(init?.redirect).toBe('manual'); expect(new Headers(init?.headers).has('Authorization')).toBe(false);
      return f.backend.router.fetch(new Request(input, init));
    }) as typeof fetch;
    await expect(preflightBotOrigin({ origin: f.services.config.publicUrl, expectedInstanceId: instanceId, fetch: fetchMock })).rejects.toMatchObject({ code: 'pairing_unavailable' });
    const verified = await preflightBotOrigin({ origin: f.services.config.publicUrl, expectedInstanceId: instanceId, setup: 'required', fetch: fetchMock });
    expect(verified.setup.instanceId).toBe(instanceId); expect(verified.identity).toBeNull();
    await error(await f.request('POST', '/v1/setup', claim(opaqueToken())), 410, 'expired');
    expect(f.store.list('users')).toHaveLength(0); expect(f.store.metadata('setupCode')).toBeNull();
    await error(await f.request('GET', '/v1/identity'), 401, 'unauthenticated');
  });

  test('provider-free running management API claims once, registers phone/Web devices and restores the same owner/workspace', async () => {
    const f = await fixture();
    // An unavailable MOCK controller and zero model/provider/default configuration do not gate startup or management.
    f.services.config.port = 0;
    const server = f.backend.start(); expect(server.port).toBeGreaterThan(0);
    const proof = issueOwnerSetupProof(f.services); const body = claim(proof.code);
    const response = await f.request('POST', '/v1/setup', body); expect(response.status).toBe(200);
    const owner = await response.json() as P.AuthResult;
    expect(owner.member.role).toBe('owner'); expect(owner.workspace.ownerUserId).toBe(owner.user.id);
    expect(f.store.metadata('setupCode')).toBeNull(); expect(f.store.metadata('setupCodeDigest')).toBeNull(); expect(f.store.metadata('setupCodeState')).toBeNull();
    for (const platform of ['ios', 'web'] as const) {
      const deviceResponse = await f.request('POST', '/v1/devices', { clientNonce: opaqueToken(), installationId: opaqueToken(), platform, name: platform === 'ios' ? 'Phone' : 'Browser', appVersion: 'test' }, owner.token);
      expect(deviceResponse.status).toBe(201);
    }
    const instanceResponse = await f.request('GET', '/v1/instance', undefined, owner.token); expect(instanceResponse.status).toBe(200);
    const instance = await instanceResponse.json() as P.InstanceStatus; expect(instance.lemon).toBeNull();
    const identity = await (await f.request('GET', '/v1/identity', undefined, owner.token)).json() as P.BackendIdentity;
    expect(identity.workspaceId).toBe(owner.workspace.id);
    await f.restart();
    expect((await (await f.request('GET', '/v1/identity', undefined, owner.token)).json() as P.BackendIdentity).instanceId).toBe(identity.instanceId);
    expect((await (await f.request('GET', '/v1/workspace', undefined, owner.token)).json() as P.Workspace).id).toBe(owner.workspace.id);
    expect(() => issueOwnerSetupProof(f.services)).toThrow('Workspace is already configured.');
    await error(await f.request('POST', '/v1/setup', claim(proof.code)), 409, 'conflict');
    expect(f.store.list('users')).toHaveLength(1); expect(f.store.list('workspaces')).toHaveLength(1);
  });

  test('racing different claimants produce exactly one owner/workspace/session, and consumed proof cannot mint again', async () => {
    const f = await fixture(); const proof = issueOwnerSetupProof(f.services);
    const responses = await Promise.all(['one', 'two', 'three', 'four'].map(name => f.request('POST', '/v1/setup', claim(proof.code, { email: `${name}@example.com`, workspaceName: name }))));
    expect(responses.filter(response => response.status === 200)).toHaveLength(1);
    for (const response of responses.filter(response => response.status !== 200)) await error(response, 409, 'conflict');
    expect(f.store.list('users')).toHaveLength(1); expect(f.store.list('members')).toHaveLength(1); expect(f.store.list('workspaces')).toHaveLength(1); expect(f.store.list('authSessions')).toHaveLength(1);
    await error(await f.request('POST', '/v1/setup', claim(proof.code)), 409, 'conflict');
  });

  test('same fixed nonce reconciles only its original authenticated session, not a new bootstrap', async () => {
    const f = await fixture(); const proof = issueOwnerSetupProof(f.services); const body = claim(proof.code);
    const original = await (await f.request('POST', '/v1/setup', body)).json() as P.AuthResult;
    await f.restart(); f.advance(ownerSetupLifetimeMs);
    const replay = await f.request('POST', '/v1/setup', body); expect(replay.status).toBe(200);
    expect(await replay.json()).toEqual(original); expect(f.store.list('authSessions')).toHaveLength(1);
    await error(await f.request('POST', '/v1/setup', { ...body, password: 'Different nonsecret test password' }), 409, 'nonce_conflict');
    expect((await f.request('DELETE', `/v1/auth/sessions/${original.session.id}`, { clientNonce: opaqueToken() }, original.token)).status).toBe(200);
    await error(await f.request('POST', '/v1/setup', body), 401, 'unauthenticated');
  });

  test('wrong proofs persist attempt counts across restart and minute rate reset; only a local reissue unlocks', async () => {
    const f = await fixture(); const proof = issueOwnerSetupProof(f.services);
    for (let i = 0; i < ownerSetupAttemptLimit; i++) {
      const failure = await error(await f.request('POST', '/v1/setup', claim(opaqueToken())), 401, 'unauthenticated');
      expect(JSON.stringify(failure)).not.toContain(proof.code);
    }
    expect(f.store.metadata<{ attempts: number }>('setupCodeState')?.attempts).toBe(ownerSetupAttemptLimit);
    await f.restart(); f.advance(60001);
    await error(await f.request('POST', '/v1/setup', claim(proof.code)), 429, 'rate_limited');
    const replacement = issueOwnerSetupProof(f.services); expect(replacement.code).not.toBe(proof.code);
    await error(await f.request('POST', '/v1/setup', claim(proof.code)), 401, 'unauthenticated');
    expect((await f.request('POST', '/v1/setup', claim(replacement.code))).status).toBe(200);
  });

  test('the existing ten-per-minute setup cap is independent of local proof rotation', async () => {
    const f = await fixture();
    for (let i = 0; i < 10; i++) {
      issueOwnerSetupProof(f.services);
      await error(await f.request('POST', '/v1/setup', claim(opaqueToken())), 401, 'unauthenticated');
    }
    const proof = issueOwnerSetupProof(f.services);
    await error(await f.request('POST', '/v1/setup', claim(proof.code)), 429, 'rate_limited');
    f.advance(60000);
    expect((await f.request('POST', '/v1/setup', claim(proof.code))).status).toBe(200);
  });

  test('absolute expiry survives restart, reprinting never extends it, and local renewal invalidates the old proof', async () => {
    const f = await fixture(); const proof = issueOwnerSetupProof(f.services);
    expect(proof.expiresAtMs).toBe(f.services.now() + ownerSetupLifetimeMs);
    f.advance(ownerSetupLifetimeMs - 1); await f.restart(); expect(issueOwnerSetupProof(f.services)).toEqual(proof);
    f.advance(1); await error(await f.request('POST', '/v1/setup', claim(proof.code)), 410, 'expired');
    const replacement = issueOwnerSetupProof(f.services); expect(replacement.code).not.toBe(proof.code);
    await error(await f.request('POST', '/v1/setup', claim(proof.code)), 401, 'unauthenticated');
    expect((await f.request('POST', '/v1/setup', claim(replacement.code))).status).toBe(200);
  });

  test('expiry is rechecked after asynchronous password hashing, with no partial owner or session', async () => {
    const f = await fixture(); const proof = issueOwnerSetupProof(f.services);
    const route = createAccountRoutes(f.services).find(route => route.path === '/v1/setup' && route.method === 'POST')!;
    const pending = route.handler({ services: f.services, route, request: new Request(`${f.services.config.publicUrl}/v1/setup`), params: {}, query: new URLSearchParams(), user: null, body: claim(proof.code), requestId: 'test-hash-expiry', nonceResourceIds: [] });
    f.advance(ownerSetupLifetimeMs);
    await expect(Promise.resolve(pending)).rejects.toMatchObject({ code: 'expired' });
    for (const collection of ['users', 'members', 'workspaces', 'authSessions']) expect(f.store.list(collection)).toHaveLength(0);
  });

  test('legacy unbounded setup proofs fail closed and require explicit local renewal', async () => {
    const f = await fixture(); const code = opaqueToken();
    f.store.setMetadata('setupCode', f.services.encrypt(code)); f.store.setMetadata('setupCodeDigest', f.services.mutations.digest(code));
    await f.restart(); await error(await f.request('POST', '/v1/setup', claim(code)), 410, 'expired');
    expect(issueOwnerSetupProof(f.services).code).not.toBe(code);
  });

  test('proof stays encrypted at rest and never enters responses, audit/events, requests URLs or errors', async () => {
    const f = await fixture(); const proof = issueOwnerSetupProof(f.services);
    const metadata = JSON.stringify(f.store.db.query('SELECT key,value FROM metadata').all());
    expect(metadata).not.toContain(proof.code); expect(f.services.decrypt(f.store.metadata<string>('setupCode')!)).toBe(proof.code);
    await error(await f.request('POST', '/v1/setup', claim(proof.code), undefined, { Origin: 'https://untrusted.example' }), 403, 'forbidden');
    await error(await f.request('POST', '/v1/setup?setupCode=forbidden-in-url', claim(proof.code)), 400, 'invalid_request');
    expect(f.store.metadata<{ attempts: number }>('setupCodeState')?.attempts).toBe(0);
    const ownerResponse = await f.request('POST', '/v1/setup', claim(proof.code)); expect(ownerResponse.status).toBe(200);
    expect(await ownerResponse.text()).not.toContain(proof.code);
    const raw = JSON.stringify(f.store.db.query('SELECT value FROM metadata UNION ALL SELECT value FROM entities UNION ALL SELECT payload FROM events UNION ALL SELECT receipt FROM nonces').all());
    expect(raw).not.toContain(proof.code); expect(raw).not.toContain(password);
  });
});
