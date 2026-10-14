import { describe, expect, test } from 'bun:test';
import { LemonBotClient, parsePairUrl, type Pairing, type PairingClaimResult, type PairingCompletion, type PairingIssued, type PairingPreviewResult } from '../src/index.ts';
import { fetchBoundary, snapshot } from './fixtures.ts';

const origin = 'https://desktop.example.ts.net';
const code = 'a'.repeat(43);
const pairUrl = `lemonbot://pair?backend=${encodeURIComponent(origin)}&cluster=workspace_1&code=${code}`;
const pairing: Pairing = {
  id: 'pairing_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, workspaceId: 'workspace_1',
  ownerUserId: 'user_1', clusterName: 'My desktop', backendUrl: origin, status: 'waiting',
  expiresAtMs: 300001, deviceName: null, verificationCode: null,
};

describe('owner pairing boundary', () => {
  test('strict parsing preserves exact origin, opaque cluster and one-use secret', () => {
    expect(parsePairUrl(pairUrl)).toEqual({ backendUrl: origin, workspaceId: 'workspace_1', pairCode: code });
    expect(parsePairUrl(pairUrl.replace(encodeURIComponent(origin), encodeURIComponent('http://127.0.0.1:4080'))).backendUrl).toBe('http://127.0.0.1:4080');
    const opaque = pairUrl.replace('workspace_1', encodeURIComponent('cluster + local'));
    expect(parsePairUrl(opaque).workspaceId).toBe('cluster + local');
  });

  test('rejects credentials, fragments, duplicate/unknown keys, routes and non-HTTPS remote origins', () => {
    for (const value of [
      pairUrl + '&code=' + code, pairUrl + '&token=secret', pairUrl + '#', pairUrl + '#secret',
      pairUrl.replace('lemonbot://pair?', 'lemonbot://pair:443?'),
      pairUrl.replace('lemonbot://pair?', 'lemonbot://user@pair?'),
      pairUrl.replace('lemonbot://pair?', 'lemonbot://pair/extra?'),
      pairUrl.replace(encodeURIComponent(origin), encodeURIComponent(origin + '/v1')),
      pairUrl.replace(encodeURIComponent(origin), encodeURIComponent('https://user:secret@desktop.example.ts.net')),
      pairUrl.replace(encodeURIComponent(origin), encodeURIComponent('http://desktop.example.ts.net')),
      pairUrl.replace(code, 'a'.repeat(42)), pairUrl.replace(code, 'a'.repeat(44)),
      pairUrl.replace('workspace_1', 'x'.repeat(129)), pairUrl + 'x'.repeat(4096),
    ]) {
      expect(() => parsePairUrl(value)).toThrow();
    }
    try { parsePairUrl('lemonbot://pair?secret=do-not-disclose'); }
    catch (failure) { expect(String(failure)).not.toContain('do-not-disclose'); }
  });
  test('non-consuming preview uses its actual nonce-free DTO and never reports a lost read as mutation uncertainty', async () => {
    const preview: PairingPreviewResult = { clusterName: pairing.clusterName, backendUrl: pairing.backendUrl, expiresAtMs: pairing.expiresAtMs };
    const boundary = fetchBoundary(async request => {
      expect(new URL(request.url).pathname).toBe('/v1/pairings/preview');
      expect(request.headers.get('Authorization')).toBeNull();
      expect(await request.json()).toEqual({ pairCode: code, workspaceId: pairing.workspaceId });
      return Response.json(preview);
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    expect(await client.call('POST /pairings/preview', { body: { pairCode: code, workspaceId: pairing.workspaceId } })).toEqual(preview);
    const lost = fetchBoundary(() => { throw new Error('lost preview response'); });
    await expect(new LemonBotClient({ baseUrl: origin, fetch: lost.clientFetch }).call('POST /pairings/preview', { body: { pairCode: code, workspaceId: pairing.workspaceId } })).rejects.toMatchObject({ code: 'upstream_unavailable', outcomeUnknown: false });
    expect(lost.requests).toHaveLength(1);
  });


  test('owner issuance/read/approval use the canonical body without propagating QR secrets into reads', async () => {
    const issued: PairingIssued = { pairing, pairUrl };
    const pending: Pairing = { ...pairing, revision: 2, status: 'pending_approval', deviceName: 'My iPhone', verificationCode: '123456' };
    const boundary = fetchBoundary(async request => {
      expect(request.headers.get('Authorization')).toBe('Bearer desktop-session');
      expect(request.cache).toBe('no-store');
      const path = new URL(request.url).pathname;
      if (path === '/v1/pairings' && request.method === 'POST') {
        expect(await request.json()).toEqual({ clientNonce: 'fixed_start_nonce' });
        return Response.json(issued);
      }
      if (request.method === 'GET') {
        expect(request.body).toBeNull();
        expect(request.url).not.toContain(code);
        return Response.json(path === '/v1/pairings' ? [pending] : pending);
      }
      expect(await request.json()).toEqual({ clientNonce: 'fixed_approve_nonce', revision: 2, verificationCode: '123456' });
      return Response.json({ ...pending, revision: 3, status: 'approved' });
    });
    const client = new LemonBotClient({ baseUrl: origin, token: 'desktop-session', fetch: boundary.clientFetch });
    expect(await client.call('POST /pairings', { body: { clientNonce: 'fixed_start_nonce' } })).toEqual(issued);
    expect(await client.call('GET /pairings')).toEqual([pending]);
    expect(await client.call('GET /pairings/:id', { params: { id: pairing.id } })).toEqual(pending);
    expect((await client.call('POST /pairings/:id/approve', { params: { id: pairing.id }, body: { clientNonce: 'fixed_approve_nonce', revision: 2, verificationCode: '123456' } })).status).toBe('approved');
    expect(boundary.requests.map(request => request.method)).toEqual(['POST', 'GET', 'GET', 'POST']);
  });

  test('public claim never receives the browser credential and a lost approval is not replayed', async () => {
    const claimed: PairingClaimResult = { pairingId: pairing.id, claimToken: 'b'.repeat(43), verificationCode: '123456',
      expiresAtMs: pairing.expiresAtMs, clusterName: pairing.clusterName, backendUrl: origin };
    const publicBoundary = fetchBoundary(async request => {
      expect(request.headers.get('Authorization')).toBeNull();
      expect(new URL(request.url).search).toBe('');
      expect(await request.json()).toEqual({ clientNonce: 'fixed_claim_nonce', pairCode: code, workspaceId: 'workspace_1', installationId: 'phone_installation', deviceName: 'My iPhone', appVersion: '1.0.0' });
      return Response.json(claimed);
    });
    const publicClient = new LemonBotClient({ baseUrl: origin, fetch: publicBoundary.clientFetch });
    expect(await publicClient.call('POST /pairings/claim', { body: { clientNonce: 'fixed_claim_nonce', pairCode: code, workspaceId: 'workspace_1', installationId: 'phone_installation', deviceName: 'My iPhone', appVersion: '1.0.0' } })).toEqual(claimed);
    const boundary = fetchBoundary(request => {
      if (request.method === 'POST') throw new Error('lost response');
      return Response.json({ ...pairing, revision: 3, status: 'approved', deviceName: 'My iPhone', verificationCode: '123456' });
    });
    const owner = new LemonBotClient({ baseUrl: origin, token: 'desktop-session', fetch: boundary.clientFetch });
    await expect(owner.call('POST /pairings/:id/approve', { params: { id: pairing.id }, body: { clientNonce: 'fixed_approve_nonce', revision: 2, verificationCode: '123456' } })).rejects.toMatchObject({ code: 'outcome_unknown', clientNonce: 'fixed_approve_nonce', resourceIds: [pairing.id], retrySafe: false });
    expect((await owner.call('GET /pairings/:id', { params: { id: pairing.id } })).status).toBe('approved');
    expect(boundary.requests.map(request => request.method)).toEqual(['POST', 'GET']);
  });
  test('explicit fixed completion intent progresses to the same device-bound session with null expiry', async () => {
    const connected: PairingCompletion = {
      status: 'connected',
      device: { id: 'phone_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, userId: snapshot.user.id,
        platform: 'ios', name: 'My iPhone', appVersion: '1.0.0', pushEnabled: false, lastSeenAtMs: 1 },
      auth: { token: 'phone-session', user: snapshot.user, workspace: snapshot.workspace, member: snapshot.member,
        session: { id: 'phone_session_1', revision: 1, createdAtMs: 1, updatedAtMs: 1, userId: snapshot.user.id,
          deviceId: 'phone_1', expiresAtMs: null, lastSeenAtMs: 1, current: true } },
    };
    let calls = 0;
    const boundary = fetchBoundary(async request => {
      expect(request.headers.get('Authorization')).toBeNull();
      expect(new URL(request.url).pathname).toBe(`/v1/pairings/${pairing.id}/complete`);
      expect(await request.json()).toEqual({ clientNonce: 'fixed_complete_nonce', claimToken: 'b'.repeat(43) });
      calls++;
      return Response.json(calls === 1 ? { status: 'pending', pairingId: pairing.id, expiresAtMs: pairing.expiresAtMs } : connected);
    });
    const client = new LemonBotClient({ baseUrl: origin, fetch: boundary.clientFetch });
    const body = { clientNonce: 'fixed_complete_nonce', claimToken: 'b'.repeat(43) };
    expect((await client.call('POST /pairings/:id/complete', { params: { id: pairing.id }, body })).status).toBe('pending');
    const result = await client.call('POST /pairings/:id/complete', { params: { id: pairing.id }, body });
    expect(result).toEqual(connected);
    if (result.status === 'connected') expect(result.auth.session.expiresAtMs).toBeNull();
    expect(boundary.requests).toHaveLength(2);
  });
});
