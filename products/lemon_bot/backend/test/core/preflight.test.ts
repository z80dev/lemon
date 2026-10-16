import { afterEach, describe, expect, test } from 'bun:test';
import { randomUUID } from 'node:crypto';
import type { BackendIdentity, PairingIssued, SetupStatus } from '../../../contracts/protocol';
import { preflightBotOrigin, validateBotIdentity, validateBotOrigin, validateBotSetup } from '../../../contracts/preflight';
import { opaqueToken } from '../../src/core/auth';
import { pairingFixture, type PairingFixture } from './pairing.fixture';

const open: PairingFixture[] = [];
afterEach(async () => { for (const fixture of open.splice(0)) await fixture.close(); });
async function fixture() { const value = await pairingFixture(); open.push(value); return value; }
async function json<T>(response: Promise<Response>): Promise<T> {
  const result = await response; expect(result.status).toBe(200); return await result.json() as T;
}
const publicUrl = 'https://desktop.example.ts.net:8449';
const setup: SetupStatus = { product: 'lemon_bot', version: '0.1.0', apiVersion: 1, setupRequired: false, instanceId: 'backend_1', publicUrl, capabilities: { pairing: true } };
const identity: BackendIdentity = { product: setup.product, version: setup.version, apiVersion: 1, instanceId: setup.instanceId, publicUrl, capabilities: setup.capabilities, workspaceId: 'workspace_1' };
function transport(handler: (request: Request) => Response | Promise<Response>): typeof fetch {
  return (async (input: RequestInfo | URL, init?: RequestInit) => handler(new Request(input, init))) as typeof fetch;
}

describe('Bot product identity and shared preflight', () => {
  test('public descriptor is minimal; authenticated workspace identity is stable across restart, URL aliases and controller changes', async () => {
    const f = await fixture();
    const first = await json<SetupStatus>(f.fetch('GET', '/v1/setup', undefined, null));
    expect(Object.keys(first).sort()).toEqual(['apiVersion', 'capabilities', 'instanceId', 'product', 'publicUrl', 'setupRequired', 'version']);
    expect(first).toMatchObject({ product: 'lemon_bot', apiVersion: 1, setupRequired: false, capabilities: { pairing: true } });
    expect(first.instanceId).toMatch(/^[0-9a-f-]{36}$/);
    expect(first).not.toHaveProperty('workspaceId'); expect(first).not.toHaveProperty('clusterName');
    const baseline = await json<BackendIdentity>(f.fetch('GET', '/v1/identity'));
    expect(baseline).toEqual({ product: first.product, apiVersion: 1, version: first.version, instanceId: first.instanceId, publicUrl: first.publicUrl, capabilities: first.capabilities, workspaceId: f.workspace.id });
    const rejected = await f.fetch('GET', '/v1/identity', undefined, null);
    expect(rejected.status).toBe(401);
    f.restart();
    f.services.config.publicUrl = publicUrl;
    f.services.config.controlUrl = 'wss://other-controller.example/ws';
    const result = await preflightBotOrigin({ origin: publicUrl, expectedInstanceId: baseline.instanceId,
      session: { token: f.owner.token, workspaceId: baseline.workspaceId }, fetch: transport(request => f.router.fetch(request)) });
    expect(result.identity?.instanceId).toBe(baseline.instanceId);
    expect(result.identity?.workspaceId).toBe(baseline.workspaceId);
    const other = await fixture();
    expect((await json<SetupStatus>(other.fetch('GET', '/v1/setup', undefined, null))).instanceId).not.toBe(first.instanceId);
    for (const secret of [f.owner.token, f.services.config.operatorToken, f.workspace.name, f.owner.user.email]) expect(JSON.stringify(first)).not.toContain(secret);
  });

  test('public setup is recognizable before bootstrap and never leaks workspace identity', async () => {
    const f = await fixture(); f.store.setMetadata('workspaceId', null);
    const descriptor = await json<SetupStatus>(f.fetch('GET', '/v1/setup', undefined, null));
    expect(descriptor.setupRequired).toBe(true); expect(descriptor).not.toHaveProperty('workspaceId');
    expect(() => validateBotSetup(descriptor, descriptor.instanceId)).toThrow(expect.objectContaining({ code: 'pairing_unavailable' }));
  });

  test('corrupt persisted identity fails closed across restart instead of silently minting a replacement', async () => {
    const f = await fixture();
    f.store.setMetadata('instanceId', null); f.restart();
    const response = await f.fetch('GET', '/v1/setup', undefined, null);
    expect(response.status).toBe(500);
    expect(await response.json()).toMatchObject({ error: { code: 'internal_error', retrySafe: false } });
    expect(f.store.metadata('instanceId')).toBeNull();
  });

  test('Phoenix 404 wrong-service, HTML landing pages and arbitrary/controller 200 are not Bot APIs', async () => {
    for (const response of [
      () => new Response('<html>Phoenix.Router.NoRouteError: no route found for GET /v1/setup</html>', { status: 404, headers: { 'Content-Type': 'text/html' } }),
      () => new Response('<html>Tailnet landing app</html>', { status: 200, headers: { 'Content-Type': 'text/html' } }),
      () => Response.json({ status: 'ok', controlConnected: true }),
      () => Response.json({ setupRequired: false, version: '0.1.0', apiVersion: 1 }),
      () => Response.json({ ...setup, product: 'lemon_web' }),
      () => Response.json({ ...setup, apiVersion: 2 }),
      () => Response.json({ ...setup, capabilities: { pairing: 'true' } }),
      () => new Response('not JSON', { headers: { 'Content-Type': 'application/json' } }),
      () => Response.json({ ...setup, padding: 'x'.repeat(16384) }),
    ]) {
      let calls = 0;
      await expect(preflightBotOrigin({ origin: publicUrl, expectedInstanceId: identity.instanceId, fetch: transport(request => {
        calls++; expect(request.url).toBe(`${publicUrl}/v1/setup`); expect(request.headers.get('Authorization')).toBeNull(); return response();
      }) })).rejects.toMatchObject({ code: 'wrong_service' });
      expect(calls).toBe(1);
    }
  });

  test('rejects phone loopback including advertised origins, numeric aliases and IPv6, but explicit local baseline may use loopback', async () => {
    for (const origin of ['http://127.0.0.1:4080', 'https://127.0.0.2', 'https://localhost', 'https://phone.localhost', 'https://localhost.', 'https://[::1]', 'https://[::ffff:7f00:1]', 'https://0.0.0.0', 'https://[::]']) {
      expect(() => validateBotOrigin(origin)).toThrow(expect.objectContaining({ code: 'loopback_origin' }));
    }
    // Noncanonical numeric spellings are refused before any request rather than normalized silently.
    for (const origin of ['https://127.1', 'https://2130706433', 'https://0x7f000001']) expect(() => validateBotOrigin(origin)).toThrow();
    expect(validateBotOrigin('http://127.0.0.1:4080', 'same-machine')).toBe('http://127.0.0.1:4080');
    await expect(preflightBotOrigin({ origin: publicUrl, expectedInstanceId: identity.instanceId,
      fetch: transport(() => Response.json({ ...setup, publicUrl: 'https://127.0.0.1:4080' })) })).rejects.toMatchObject({ code: 'loopback_origin' });
  });

  test('HTTPS cannot be replaced by overlay claims, redirects, invalid origins or TLS verification bypass', async () => {
    for (const origin of ['http://desktop.example.ts.net', 'https://user:secret@desktop.example.ts.net', publicUrl + '/v1', publicUrl + '?insecure=true', publicUrl + '#', publicUrl + '/', 'ftp://desktop.example.ts.net']) {
      let calls = 0;
      await expect(preflightBotOrigin({ origin, expectedInstanceId: identity.instanceId, fetch: transport(() => { calls++; return Response.json(setup); }) })).rejects.toBeInstanceOf(Error);
      expect(calls).toBe(0);
    }
    await expect(preflightBotOrigin({ origin: publicUrl, expectedInstanceId: identity.instanceId,
      fetch: transport(request => { expect(request.redirect).toBe('manual'); return new Response(null, { status: 302, headers: { Location: 'https://other.example/v1/setup' } }); }) })).rejects.toMatchObject({ code: 'wrong_service' });
    await expect(preflightBotOrigin({ origin: publicUrl, expectedInstanceId: identity.instanceId,
      fetch: transport(() => { throw new Error('private certificate failure'); }) })).rejects.toMatchObject({ code: 'unavailable' });
    const previous = process.env.NODE_TLS_REJECT_UNAUTHORIZED;
    try {
      process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0'; let calls = 0;
      await expect(preflightBotOrigin({ origin: publicUrl, expectedInstanceId: identity.instanceId,
        fetch: transport(() => { calls++; return Response.json(setup); }) })).rejects.toMatchObject({ code: 'tls_required' });
      expect(calls).toBe(0);
    } finally { if (previous === undefined) delete process.env.NODE_TLS_REJECT_UNAUTHORIZED; else process.env.NODE_TLS_REJECT_UNAUTHORIZED = previous; }
  });

  test('instance mismatch prevents credential dispatch; authenticated workspace mismatch and changed identity fail closed', async () => {
    let calls = 0;
    await expect(preflightBotOrigin({ origin: publicUrl, expectedInstanceId: 'old_backend', session: { token: 'private-product-session', workspaceId: identity.workspaceId },
      fetch: transport(request => { calls++; expect(request.headers.get('Authorization')).toBeNull(); return Response.json(setup); }) })).rejects.toMatchObject({ code: 'instance_mismatch' });
    expect(calls).toBe(1);
    const requests: Request[] = [];
    await expect(preflightBotOrigin({ origin: publicUrl, expectedInstanceId: identity.instanceId, session: { token: 'private-product-session', workspaceId: 'another_workspace' },
      fetch: transport(request => { requests.push(request); return Response.json(request.url.endsWith('/setup') ? setup : identity); }) })).rejects.toMatchObject({ code: 'workspace_mismatch' });
    expect(requests.map(request => request.method)).toEqual(['GET', 'GET']);
    expect(requests[0]!.headers.get('Authorization')).toBeNull(); expect(requests[1]!.headers.get('Authorization')).toBe('Bearer private-product-session');
    expect(() => validateBotIdentity({ ...identity, instanceId: 'replacement' }, identity)).toThrow(expect.objectContaining({ code: 'instance_mismatch' }));
    expect(() => validateBotIdentity({ ...identity, workspaceId: 'replacement' }, identity)).toThrow(expect.objectContaining({ code: 'workspace_mismatch' }));
    const f = await fixture();
    const baseline = await json<BackendIdentity>(f.fetch('GET', '/v1/identity'));
    f.store.setMetadata('instanceId', randomUUID()); f.restart();
    await expect(preflightBotOrigin({ origin: f.services.config.publicUrl, expectedInstanceId: baseline.instanceId,
      fetch: transport(request => f.router.fetch(request)) })).rejects.toMatchObject({ code: 'instance_mismatch' });
  });

  test('changed server identity invalidates outstanding QR proofs without issuing any device credential', async () => {
    const f = await fixture();
    const issuedResponse = await f.fetch('POST', '/v1/pairings', { clientNonce: opaqueToken() });
    expect(issuedResponse.status).toBe(201);
    const issued = await issuedResponse.json() as PairingIssued;
    const pairCode = new URL(issued.pairUrl).searchParams.get('code');
    f.store.setMetadata('instanceId', randomUUID()); f.restart();
    const response = await f.fetch('POST', '/v1/pairings/preview', { pairCode, workspaceId: f.workspace.id }, null);
    expect(response.status).toBe(403); expect(await response.json()).toMatchObject({ error: { code: 'forbidden' } });
    expect(f.persistentCalls).toBe(0);
  });
});
