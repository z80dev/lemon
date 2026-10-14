import { afterEach, describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { opaqueToken, type SessionSecret } from '../../src/core/auth';
import { deleteUserPairings, revokeUserPairings, revokeWorkspacePairings } from '../../src/core/pairing';
import { pairingFixture, type PairingFixture } from './pairing.fixture';

const open: PairingFixture[] = [];
afterEach(async () => { for (const fixture of open.splice(0)) await fixture.close(); });
async function fixture() { const value = await pairingFixture(); open.push(value); return value; }
async function success<T>(request: Promise<Response>, status = 200): Promise<T> {
  const response = await request;
  const value: unknown = await response.json();
  expect({ status: response.status, value }).toMatchObject({ status });
  expect(value).not.toHaveProperty('error');
  return value as T;
}
async function failure(request: Promise<Response>, code: P.ErrorCode): Promise<P.ErrorEnvelope> {
  const response = await request;
  expect(response.ok).toBe(false);
  const value = await response.json() as P.ErrorEnvelope;
  expect(Object.keys(value)).toEqual(['error']);
  expect(value.error).toMatchObject({ code, requestId: expect.any(String), retrySafe: expect.any(Boolean) });
  return value;
}
interface StartedPairing { issued: P.PairingIssued; pairCode: string; startBody: P.PairingStart }
interface PreparedPairing extends StartedPairing { claimed: P.PairingClaimResult; claimBody: P.PairingClaim; pending: P.Pairing; approveBody: P.PairingApprove; completeBody: P.PairingComplete }
async function start(f: PairingFixture): Promise<StartedPairing> {
  const startBody = { clientNonce: opaqueToken() };
  const issued = await success<P.PairingIssued>(f.fetch('POST', '/v1/pairings', startBody), 201);
  const pairCode = new URL(issued.pairUrl).searchParams.get('code');
  if (!pairCode) throw new Error('Pairing issuance did not contain its one-use QR proof.');
  return { issued, pairCode, startBody };
}
function claimBody(f: PairingFixture, started: StartedPairing, installationId = 'phone-installation'): P.PairingClaim {
  return { clientNonce: opaqueToken(), pairCode: started.pairCode, workspaceId: f.workspace.id, installationId, deviceName: 'Owner iPhone', appVersion: '1.0' };
}
async function prepare(f: PairingFixture, installationId?: string): Promise<PreparedPairing> {
  const started = await start(f);
  const body = claimBody(f, started, installationId);
  const claimed = await success<P.PairingClaimResult>(f.fetch('POST', '/v1/pairings/claim', body, null));
  const pending = await success<P.Pairing>(f.fetch('GET', `/v1/pairings/${claimed.pairingId}`));
  return { ...started, claimed, claimBody: body, pending, approveBody: { clientNonce: opaqueToken(), revision: pending.revision, verificationCode: claimed.verificationCode }, completeBody: { clientNonce: opaqueToken(), claimToken: claimed.claimToken } };
}
async function connect(f: PairingFixture, prepared: PreparedPairing): Promise<Extract<P.PairingCompletion, { status: 'connected' }>> {
  await success<P.Pairing>(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody));
  const completed = await success<P.PairingCompletion>(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null));
  if (completed.status !== 'connected') throw new Error('An approved pairing did not return its actual session.');
  return completed;
}

describe('owner phone pairing', () => {
  test('one-use QR has exact configured origin; read-only preview supplies the exact cluster name', async () => {
    const f = await fixture(); const started = await start(f);
    const link = new URL(started.issued.pairUrl);
    expect(link.protocol).toBe('lemonbot:'); expect(link.host).toBe('pair');
    expect(link.username).toBe(''); expect(link.password).toBe(''); expect(link.hash).toBe('');
    expect([...link.searchParams.keys()].sort()).toEqual(['backend', 'cluster', 'code']);
    expect(link.searchParams.get('backend')).toBe(f.services.config.publicUrl);
    expect(link.searchParams.get('cluster')).toBe(f.workspace.id);
    expect(started.pairCode).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(started.issued.pairUrl).not.toContain(f.owner.token);
    expect(started.issued.pairUrl).not.toContain(f.services.config.operatorToken);
    expect(started.issued.pairing).toMatchObject({ status: 'waiting', deviceName: null, verificationCode: null, clusterName: f.workspace.name, backendUrl: f.services.config.publicUrl, ownerUserId: f.owner.user.id });
    expect(started.issued.pairing.expiresAtMs - f.services.now()).toBe(300000);
    const previewBody: P.PairingPreviewRequest = { pairCode: started.pairCode, workspaceId: f.workspace.id };
    const preview = await success<P.PairingPreviewResult>(f.fetch('POST', '/v1/pairings/preview', previewBody, null));
    expect(preview).toEqual({ clusterName: f.workspace.name, backendUrl: f.services.config.publicUrl, expiresAtMs: started.issued.pairing.expiresAtMs });
    expect(await success(f.fetch('POST', '/v1/pairings/preview', previewBody, null))).toEqual(preview);
    expect(await success(f.fetch('GET', `/v1/pairings/${started.issued.pairing.id}`))).toEqual(started.issued.pairing);
    f.restart();
    expect(await success(f.fetch('POST', '/v1/pairings', started.startBody), 201)).toEqual(started.issued);
    const claimed = await success<P.PairingClaimResult>(f.fetch('POST', '/v1/pairings/claim', claimBody(f, started), null));
    expect(claimed.clusterName).toBe(preview.clusterName); expect(claimed.backendUrl).toBe(preview.backendUrl);
    await failure(f.fetch('POST', '/v1/pairings/preview', previewBody, null), 'conflict');
    const listed = await success<P.Pairing[]>(f.fetch('GET', '/v1/pairings'));
    expect(Array.isArray(listed)).toBe(true); expect(listed).toHaveLength(1);
    const serialized = JSON.stringify(listed);
    for (const credential of [started.pairCode, claimed.claimToken, f.owner.token]) expect(serialized).not.toContain(credential);
    expect(f.owner.session.expiresAtMs).not.toBeNull();
  });

  test('two phones racing one QR produce exactly one claim and exact-nonce retry replays the private result across restart', async () => {
    const f = await fixture(); const started = await start(f);
    const first = claimBody(f, started, 'phone-one'); const second = claimBody(f, started, 'phone-two');
    const responses = await Promise.all([f.fetch('POST', '/v1/pairings/claim', first, null), f.fetch('POST', '/v1/pairings/claim', second, null)]);
    expect(responses.filter(response => response.ok)).toHaveLength(1);
    const winner = responses[0]!.ok ? first : second;
    const accepted = await responses.find(response => response.ok)!.json() as P.PairingClaimResult;
    const rejected = await responses.find(response => !response.ok)!.json() as P.ErrorEnvelope;
    expect(rejected.error.code).toBe('nonce_conflict');
    expect(accepted.claimToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(accepted.verificationCode).toMatch(/^\d{6}$/);
    f.restart();
    expect(await success(f.fetch('POST', '/v1/pairings/claim', winner, null))).toEqual(accepted);
    await failure(f.fetch('POST', '/v1/pairings/claim', { ...winner, clientNonce: opaqueToken() }, null), 'nonce_conflict');
    await failure(f.fetch('POST', '/v1/pairings/claim', { ...winner, deviceName: 'Changed phone' }, null), 'nonce_conflict');
    expect(f.store.list<P.Device>('devices', device => device.platform === 'ios')).toHaveLength(0);
    expect(f.persistentCalls).toBe(0);
  });

  test('public receipts are secret-proof-bound before nonce or selector parsing, and identical nonces on independent QR proofs do not collide', async () => {
    const f = await fixture(); const first = await start(f); const second = await start(f);
    const body = claimBody(f, first, 'phone-one');
    const accepted = await success<P.PairingClaimResult>(f.fetch('POST', '/v1/pairings/claim', body, null));
    await failure(f.fetch('POST', '/v1/pairings/claim', { ...body, pairCode: 'A'.repeat(43), clientNonce: 1, ownerUserId: f.owner.user.id }, null), 'unauthenticated');
    await failure(f.fetch('POST', '/v1/pairings/claim', { ...body, ownerUserId: f.other.user.id }, null), 'invalid_request');
    await failure(f.fetch('POST', '/v1/pairings/claim', { ...claimBody(f, second), workspaceId: 'forged-workspace' }, null), 'forbidden');
    const independent = await success<P.PairingClaimResult>(f.fetch('POST', '/v1/pairings/claim', { ...claimBody(f, second, 'phone-two'), clientNonce: body.clientNonce }, null));
    expect(independent.pairingId).not.toBe(accepted.pairingId); expect(independent.claimToken).not.toBe(accepted.claimToken);
    await failure(f.fetch('POST', `/v1/pairings/${accepted.pairingId}/complete`, { clientNonce: 1, claimToken: 'B'.repeat(43), userId: f.owner.user.id }, null), 'unauthenticated');
    await failure(f.fetch('POST', `/v1/pairings/${independent.pairingId}/complete`, { clientNonce: opaqueToken(), claimToken: accepted.claimToken }, null), 'unauthenticated');
    await failure(f.fetch('POST', '/v1/pairings/preview', { pairCode: first.pairCode, workspaceId: f.workspace.id, backendUrl: 'https://forged.example', ownerUserId: f.owner.user.id }, null), 'invalid_request');
    await failure(f.fetch('POST', '/v1/pairings/preview', { pairCode: 'C'.repeat(43), workspaceId: 5 }, null), 'unauthenticated');
    await failure(f.fetch('POST', '/v1/pairings/claim', claimBody(f, second), null, { Origin: 'https://forged.example' }), 'forbidden');
    await failure(f.fetch('GET', '/v1/pairings?ownerUserId=other-owner'), 'invalid_request');
  });

  test('current owner, verification code and revision are required before any device/session issuance', async () => {
    const f = await fixture(); const prepared = await prepare(f);
    const path = `/v1/pairings/${prepared.pending.id}/approve`;
    await failure(f.fetch('POST', path, prepared.approveBody, f.other.token), 'forbidden');
    const wrongCode = prepared.claimed.verificationCode === '000000' ? '000001' : '000000';
    await failure(f.fetch('POST', path, { ...prepared.approveBody, clientNonce: opaqueToken(), verificationCode: wrongCode }), 'confirmation_required');
    await failure(f.fetch('POST', path, { ...prepared.approveBody, clientNonce: opaqueToken(), revision: prepared.pending.revision + 1 }), 'revision_conflict');
    await failure(f.fetch('POST', path, { ...prepared.approveBody, ownerUserId: f.other.user.id }), 'invalid_request');
    expect(f.persistentCalls).toBe(0); expect(f.store.list<P.Device>('devices', device => device.platform === 'ios')).toHaveLength(0);
    const workspace = f.store.require<P.Workspace>('workspaces', f.workspace.id);
    await success(f.fetch('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: workspace.revision, ownerUserId: f.other.user.id }));
    await failure(f.fetch('POST', path, prepared.approveBody), 'forbidden');
    await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null), 'unauthenticated');
    expect(f.persistentCalls).toBe(0);
  });

  test('pending completion progresses with the same fixed nonce; approval and lost completion replay one real device/session', async () => {
    const f = await fixture(); const prepared = await prepare(f);
    const completePath = `/v1/pairings/${prepared.pending.id}/complete`;
    const pending = { status: 'pending', pairingId: prepared.pending.id, expiresAtMs: prepared.pending.expiresAtMs };
    expect(await success(f.fetch('POST', completePath, prepared.completeBody, null))).toEqual(pending);
    f.restart();
    expect(await success(f.fetch('POST', completePath, prepared.completeBody, null))).toEqual(pending);
    const approved = await success<P.Pairing>(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody));
    expect(approved.status).toBe('approved'); expect(approved.verificationCode).toBe(prepared.claimed.verificationCode);
    expect(approved).not.toHaveProperty('auth'); expect(approved).not.toHaveProperty('token');
    const first = await success<P.PairingCompletion>(f.fetch('POST', completePath, prepared.completeBody, null));
    if (first.status !== 'connected') throw new Error('Expected actual connected credential.');
    expect(first.auth.user.id).toBe(f.owner.user.id); expect(first.auth.workspace.id).toBe(f.workspace.id);
    expect(first.auth.session.deviceId).toBe(first.device.id); expect(first.auth.session.expiresAtMs).toBeNull();
    expect(first.device).toMatchObject({ userId: f.owner.user.id, platform: 'ios', name: 'Owner iPhone', appVersion: '1.0' });
    expect(f.store.metadata(`deviceInstallation:${first.device.id}`)).toBe(prepared.claimBody.installationId);
    expect(f.persistentCalls).toBe(1);
    f.restart();
    expect(await success(f.fetch('POST', completePath, prepared.completeBody, null))).toEqual(first);
    expect(await success(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody))).toEqual(approved);
    expect(await success(f.fetch('POST', '/v1/pairings/claim', prepared.claimBody, null))).toEqual(prepared.claimed);
    await failure(f.fetch('POST', completePath, { ...prepared.completeBody, clientNonce: opaqueToken() }, null), 'nonce_conflict');
    const sessions = await success<P.Page<P.AuthSession>>(f.fetch('GET', '/v1/auth/sessions'));
    expect(sessions.items.filter(session => session.deviceId === first.device.id)).toHaveLength(1);
    expect(sessions.items.find(session => session.id === first.auth.session.id)?.expiresAtMs).toBeNull();
    expect(f.store.list<P.Device>('devices', device => device.platform === 'ios')).toHaveLength(1);
    expect(f.persistentCalls).toBe(1);
    const phone = await f.services.auth.authenticate(new Request('https://desktop.example/v1/me', { headers: { Authorization: `Bearer ${first.auth.token}` } }), 'member');
    const desktop = await f.services.auth.authenticate(new Request('https://desktop.example/v1/me', { headers: { Authorization: `Bearer ${f.owner.token}` } }), 'owner');
    if (!phone || !desktop) throw new Error('Real issued sessions must authenticate.');
    expect(f.services.events.replay(phone, '0').filter(event => event.event === 'pairing.upserted')).toHaveLength(0);
    const pairingEvents = f.services.events.replay(desktop, '0').filter(event => event.event === 'pairing.upserted');
    expect(pairingEvents.length).toBeGreaterThan(0);
    const auditAndEvents = JSON.stringify({ audit: f.store.list('auditRecords'), events: pairingEvents });
    for (const credential of [first.auth.token, prepared.claimed.claimToken, prepared.pairCode]) expect(auditAndEvents).not.toContain(credential);
    const privateRecord = JSON.stringify(f.store.require('pairingSecrets', prepared.pending.id));
    for (const credential of [first.auth.token, prepared.claimed.claimToken, prepared.pairCode]) expect(privateRecord).not.toContain(credential);
  });

  test('a lost generic approval receipt reconciles from durable private custody without minting again', async () => {
    const f = await fixture(); const prepared = await prepare(f);
    const approved = await success<P.Pairing>(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody));
    f.store.db.query("UPDATE nonces SET state='reserved',receipt=NULL WHERE nonce=?").run(prepared.approveBody.clientNonce);
    f.restart();
    expect(await success(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody))).toEqual(approved);
    const first = await success<P.PairingCompletion>(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null));
    f.restart();
    expect(await success(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null))).toEqual(first);
    expect(f.persistentCalls).toBe(1); expect(f.store.list<P.Device>('devices', device => device.platform === 'ios')).toHaveLength(1);
  });

  test('concurrent identical owner approvals share actual issuance and different approval intent is fenced', async () => {
    const f = await fixture(); const prepared = await prepare(f);
    const issue = f.services.auth.session;
    let entered!: () => void; let release!: () => void;
    const started = new Promise<void>(resolve => { entered = resolve; });
    const hold = new Promise<void>(resolve => { release = resolve; });
    f.services.auth.session = async (userId, deviceId, options) => { const auth = await issue(userId, deviceId, options); entered(); await hold; return auth; };
    const path = `/v1/pairings/${prepared.pending.id}/approve`;
    const first = f.fetch('POST', path, prepared.approveBody); await started;
    const second = f.fetch('POST', path, prepared.approveBody);
    await failure(f.fetch('POST', path, { ...prepared.approveBody, clientNonce: opaqueToken() }), 'nonce_conflict');
    release();
    const results = await Promise.all([success<P.Pairing>(first), success<P.Pairing>(second)]);
    expect(results[0]).toEqual(results[1]); expect(f.persistentCalls).toBe(1);
    expect(f.store.list<P.AuthSession>('authSessions', session => session.expiresAtMs === null)).toHaveLength(1);
  });

  test('durably uncertain issuance survives restart as a fence, never an automatic retry or public mint', async () => {
    const f = await fixture(); const prepared = await prepare(f);
    const issue = f.services.auth.session;
    f.services.auth.session = async (userId, deviceId, options) => { await issue(userId, deviceId, options); throw new Error('private upstream outcome must not escape'); };
    const path = `/v1/pairings/${prepared.pending.id}/approve`;
    const error = await failure(f.fetch('POST', path, prepared.approveBody), 'outcome_unknown');
    expect(error.error.retrySafe).toBe(false); expect(JSON.stringify(error)).not.toContain('private upstream');
    f.restart();
    await failure(f.fetch('POST', path, prepared.approveBody), 'outcome_unknown');
    await failure(f.fetch('POST', path, { ...prepared.approveBody, clientNonce: opaqueToken() }), 'nonce_conflict');
    await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null), 'outcome_unknown');
    expect(f.persistentCalls).toBe(1); expect(f.store.list<P.AuthSession>('authSessions', session => session.expiresAtMs === null)).toHaveLength(1);
    f.advance(300000); await f.pairingService.sweep();
    const fresh = await start(f);
    await failure(f.fetch('POST', '/v1/pairings/claim', claimBody(f, fresh, prepared.claimBody.installationId), null), 'conflict');
    const device = f.store.list<P.Device>('devices', value => value.platform === 'ios')[0]!;
    await success(f.fetch('DELETE', `/v1/devices/${device.id}`, { clientNonce: opaqueToken() }));
    await f.pairingService.sweep();
    await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null), 'unauthenticated');
    expect(f.persistentCalls).toBe(1);
  });

  test('denial and five-minute expiry are explicit and never issue a device/session', async () => {
    const f = await fixture(); const denied = await prepare(f, 'denied-phone');
    await success(f.fetch('POST', `/v1/pairings/${denied.pending.id}/complete`, denied.completeBody, null));
    const denyBody: P.PairingDeny = { clientNonce: opaqueToken(), revision: denied.pending.revision };
    await failure(f.fetch('POST', `/v1/pairings/${denied.pending.id}/deny`, { ...denyBody, clientNonce: opaqueToken(), revision: 99 }), 'revision_conflict');
    const decision = await success<P.Pairing>(f.fetch('POST', `/v1/pairings/${denied.pending.id}/deny`, denyBody));
    f.restart(); expect(await success(f.fetch('POST', `/v1/pairings/${denied.pending.id}/deny`, denyBody))).toEqual(decision);
    expect(await success(f.fetch('POST', `/v1/pairings/${denied.pending.id}/complete`, denied.completeBody, null))).toEqual({ status: 'denied', pairingId: denied.pending.id, expiresAtMs: denied.pending.expiresAtMs });
    const expired = await prepare(f, 'expired-phone');
    await success(f.fetch('POST', `/v1/pairings/${expired.pending.id}/complete`, expired.completeBody, null));
    f.advance(300000); await f.pairingService.sweep();
    expect(await success(f.fetch('POST', `/v1/pairings/${expired.pending.id}/complete`, expired.completeBody, null))).toEqual({ status: 'expired', pairingId: expired.pending.id, expiresAtMs: expired.pending.expiresAtMs });
    await failure(f.fetch('POST', `/v1/pairings/${expired.pending.id}/approve`, expired.approveBody), 'expired');
    await failure(f.fetch('POST', '/v1/pairings/claim', expired.claimBody, null), 'expired');
    expect(await success(f.fetch('GET', '/v1/pairings'))).toEqual([]);
    expect((await success<P.Pairing>(f.fetch('GET', `/v1/pairings/${expired.pending.id}`))).status).toBe('expired');
    expect(f.persistentCalls).toBe(0);
  });

  test('original deadline erases credential receipts without shortening any approved persistent session', async () => {
    const f = await fixture(); const staged = await prepare(f, 'staged-phone');
    await success(f.fetch('POST', `/v1/pairings/${staged.pending.id}/approve`, staged.approveBody));
    const connected = await prepare(f, 'connected-phone'); const auth = await connect(f, connected);
    f.advance(300000); await f.pairingService.sweep();
    expect(f.store.list<P.AuthSession>('authSessions', session => session.expiresAtMs === null)).toHaveLength(2);
    expect(await success(f.fetch('POST', `/v1/pairings/${staged.pending.id}/complete`, staged.completeBody, null))).toEqual({ status: 'expired', pairingId: staged.pending.id, expiresAtMs: staged.pending.expiresAtMs });
    expect(await success(f.fetch('POST', `/v1/pairings/${connected.pending.id}/complete`, connected.completeBody, null))).toEqual({ status: 'expired', pairingId: connected.pending.id, expiresAtMs: connected.pending.expiresAtMs });
    await failure(f.fetch('POST', '/v1/pairings', connected.startBody), 'expired');
    const custody = f.store.require<{ approval: { encryptedAuth: string | null }; completion: { receipt: string | null } }>('pairingSecrets', connected.pending.id);
    expect(custody.approval.encryptedAuth).toBeNull(); expect(custody.completion.receipt).toBeNull();
    const unused = f.store.list<P.AuthSession>('authSessions', session => session.expiresAtMs === null && session.id !== auth.auth.session.id)[0]!;
    await success(f.fetch('DELETE', `/v1/auth/sessions/${unused.id}`, { clientNonce: opaqueToken() }));
    expect(f.store.list<P.AuthSession>('authSessions', session => session.expiresAtMs === null).map(session => session.id)).toEqual([auth.auth.session.id]);
    f.advance(31 * 86400000);
    expect((await f.services.auth.authenticate(new Request('https://desktop.example/v1/me', { headers: { Authorization: `Bearer ${auth.auth.token}` } }), 'member'))?.deviceId).toBe(auth.device.id);
    expect(f.persistentCalls).toBe(2);
  });

  test('session and actual device revocation fence retained claim and completion credentials', async () => {
    for (const resource of ['session', 'device'] as const) {
      const f = await fixture(); const prepared = await prepare(f); const connected = await connect(f, prepared);
      const path = resource === 'session' ? `/v1/auth/sessions/${connected.auth.session.id}` : `/v1/devices/${connected.device.id}`;
      await success(f.fetch('DELETE', path, { clientNonce: opaqueToken() }));
      f.restart();
      await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null), 'unauthenticated');
      await failure(f.fetch('POST', '/v1/pairings/claim', prepared.claimBody, null), 'unauthenticated');
      await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody), 'unauthenticated');
      expect(f.store.get<SessionSecret>('sessionSecrets', connected.auth.session.id)?.revoked).toBe(true);
      await expect(f.services.auth.authenticate(new Request('https://desktop.example/v1/me', { headers: { Authorization: `Bearer ${connected.auth.token}` } }), 'member')).rejects.toMatchObject({ code: 'unauthenticated' });
      expect(f.persistentCalls).toBe(1);
    }
  });

  test('workspace disable and re-enable do not resurrect pending or connected credential authority', async () => {
    const f = await fixture(); const pending = await prepare(f, 'pending-phone'); const connected = await prepare(f, 'connected-phone'); const auth = await connect(f, connected);
    const disabled = await success<P.Workspace>(f.fetch('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: f.workspace.revision, enabled: false }));
    expect(disabled.enabled).toBe(false);
    await failure(f.fetch('POST', `/v1/pairings/${pending.pending.id}/complete`, pending.completeBody, null), 'unauthenticated');
    await success(f.fetch('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: disabled.revision, enabled: true }));
    f.restart();
    await failure(f.fetch('POST', '/v1/pairings/claim', pending.claimBody, null), 'unauthenticated');
    await failure(f.fetch('POST', `/v1/pairings/${connected.pending.id}/complete`, connected.completeBody, null), 'unauthenticated');
    expect(f.store.get<SessionSecret>('sessionSecrets', auth.auth.session.id)?.revoked).toBe(true);
    expect(f.persistentCalls).toBe(1);
  });

  test('account revocation and actual deletion clear private pairing custody without borrowing another owner', async () => {
    const f = await fixture(); const pending = await prepare(f, 'pending-phone'); const connected = await prepare(f, 'connected-phone'); await connect(f, connected);
    await f.services.auth.revokeUser(f.owner.user.id);
    await failure(f.fetch('POST', '/v1/pairings/claim', pending.claimBody, null), 'unauthenticated');
    await failure(f.fetch('POST', `/v1/pairings/${connected.pending.id}/complete`, connected.completeBody, null), 'unauthenticated');
    deleteUserPairings(f.services, f.owner.user.id);
    expect(f.store.list('pairingSecrets')).toEqual([]); expect(f.store.list('pairings')).toEqual([]);
    const nonces = f.store.db.query('SELECT scope FROM nonces').all() as { scope: string }[];
    expect(nonces.filter(row => row.scope.includes('/v1/pairings'))).toEqual([]);
    expect((await f.services.auth.authenticate(new Request('https://desktop.example/v1/me', { headers: { Authorization: `Bearer ${f.other.token}` } }), 'owner'))?.userId).toBe(f.other.user.id);
    expect(f.persistentCalls).toBe(1);
  });

  test('owning revocation helpers are durable for pending proofs even if accounts and workspace stay enabled', async () => {
    for (const target of ['user', 'workspace'] as const) {
      const f = await fixture(); const prepared = await prepare(f);
      if (target === 'user') revokeUserPairings(f.services, f.owner.user.id); else revokeWorkspacePairings(f.services, f.workspace.id);
      f.restart();
      await failure(f.fetch('POST', '/v1/pairings/claim', prepared.claimBody, null), 'unauthenticated');
      await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/complete`, prepared.completeBody, null), 'unauthenticated');
      expect(f.persistentCalls).toBe(0);
    }
  });

  test('one installation cannot claim two active pairings; explicit reconnect reuses its actual device after session revocation', async () => {
    const f = await fixture(); const first = await prepare(f, 'same-installation'); const second = await start(f);
    const nextClaim = claimBody(f, second, 'same-installation');
    await failure(f.fetch('POST', '/v1/pairings/claim', nextClaim, null), 'conflict');
    const connected = await connect(f, first);
    await success(f.fetch('DELETE', `/v1/auth/sessions/${connected.auth.session.id}`, { clientNonce: opaqueToken() }));
    const claimed = await success<P.PairingClaimResult>(f.fetch('POST', '/v1/pairings/claim', nextClaim, null));
    const pending = await success<P.Pairing>(f.fetch('GET', `/v1/pairings/${claimed.pairingId}`));
    await success(f.fetch('POST', `/v1/pairings/${pending.id}/approve`, { clientNonce: opaqueToken(), revision: pending.revision, verificationCode: claimed.verificationCode }));
    const next = await success<P.PairingCompletion>(f.fetch('POST', `/v1/pairings/${pending.id}/complete`, { clientNonce: opaqueToken(), claimToken: claimed.claimToken }, null));
    if (next.status !== 'connected') throw new Error('Explicit reconnect did not connect.');
    expect(next.device.id).toBe(connected.device.id); expect(next.auth.session.id).not.toBe(connected.auth.session.id);
    expect(f.store.list<P.Device>('devices', device => device.platform === 'ios')).toHaveLength(1);
    await failure(f.fetch('POST', `/v1/pairings/${first.pending.id}/complete`, first.completeBody, null), 'unauthenticated');
    expect(f.persistentCalls).toBe(2);
  });

  test('revoked approving owner session or desktop device cannot authorize a pending phone', async () => {
    for (const target of ['session', 'device'] as const) {
      const f = await fixture(); const prepared = await prepare(f);
      const path = target === 'session' ? `/v1/auth/sessions/${f.owner.session.id}` : `/v1/devices/${f.desktop.id}`;
      await success(f.fetch('DELETE', path, { clientNonce: opaqueToken() }));
      await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody), 'unauthenticated');
      expect(f.persistentCalls).toBe(0);
      expect(f.store.list<P.Device>('devices', device => device.platform === 'ios')).toHaveLength(0);
    }
  });

  test('an existing installation belonging to another account cannot be rebound by owner approval', async () => {
    const f = await fixture(); const prepared = await prepare(f, 'foreign-installation');
    const foreign: P.Device = f.services.resource('device', { userId: f.other.user.id, platform: 'ios', name: 'Other account phone', appVersion: '1', pushEnabled: false, lastSeenAtMs: f.services.now() });
    f.store.put('devices', foreign); f.store.setMetadata(`deviceInstallation:${foreign.id}`, prepared.claimBody.installationId);
    await failure(f.fetch('POST', `/v1/pairings/${prepared.pending.id}/approve`, prepared.approveBody), 'conflict');
    expect(f.store.require<P.Device>('devices', foreign.id)).toEqual(foreign);
    expect(f.persistentCalls).toBe(0);
  });

  test('preview rate limits are durable, proof scoped and never consume a QR', async () => {
    const f = await fixture(); const started = await start(f);
    const body: P.PairingPreviewRequest = { pairCode: started.pairCode, workspaceId: f.workspace.id };
    for (let index = 0; index < 120; index += 1) await success(f.fetch('POST', '/v1/pairings/preview', body, null));
    f.restart();
    const limited = await failure(f.fetch('POST', '/v1/pairings/preview', body, null), 'rate_limited');
    expect(JSON.stringify(limited)).not.toContain(started.pairCode);
    expect(f.store.require<P.Pairing>('pairings', started.issued.pairing.id).status).toBe('waiting');
    f.advance(60000);
    const claimed = await success<P.PairingClaimResult>(f.fetch('POST', '/v1/pairings/claim', claimBody(f, started), null));
    expect(claimed.pairingId).toBe(started.issued.pairing.id); expect(f.persistentCalls).toBe(0);
  });

  test('paired bearer device registration cannot rebind the persistent session to a different installation', async () => {
    const f = await fixture(); const prepared = await prepare(f); const connected = await connect(f, prepared);
    const registration: P.DeviceRegister = { clientNonce: opaqueToken(), installationId: 'another-phone-installation', platform: 'ios', name: 'Another phone', appVersion: '1.0' };
    await failure(f.fetch('POST', '/v1/devices', registration, connected.auth.token), 'conflict');
    expect(f.store.require<P.AuthSession>('authSessions', connected.auth.session.id).deviceId).toBe(connected.device.id);
    expect(f.store.list<P.Device>('devices', device => device.platform === 'ios')).toHaveLength(1);
    const same = await success<P.Device>(f.fetch('POST', '/v1/devices', { ...registration, clientNonce: opaqueToken(), installationId: prepared.claimBody.installationId }, connected.auth.token), 201);
    expect(same.id).toBe(connected.device.id);
    expect(f.store.require<P.AuthSession>('authSessions', connected.auth.session.id).deviceId).toBe(connected.device.id);
  });

  test('canonical claim bounds reject malformed fields without consuming the QR', async () => {
    const f = await fixture(); const started = await start(f); const body = claimBody(f, started);
    for (const invalid of [{ installationId: '' }, { installationId: 'x'.repeat(129) }, { deviceName: '' }, { deviceName: 'x'.repeat(121) }, { appVersion: 'x'.repeat(65) }, { deviceName: 'hidden\nname' }, { backendUrl: 'https://forged.example' }]) await failure(f.fetch('POST', '/v1/pairings/claim', { ...body, ...invalid }, null), 'invalid_request');
    const accepted = await success<P.PairingClaimResult>(f.fetch('POST', '/v1/pairings/claim', { ...body, installationId: 'x' }, null));
    expect(accepted.pairingId).toBe(started.issued.pairing.id); expect(f.persistentCalls).toBe(0);
  });

  test('HTTPS is required off loopback even with trustedOverlay; origin credentials, path/query/fragment and inferred Host are refused', async () => {
    const f = await fixture(); f.services.config.trustedOverlay = true;
    for (const origin of ['http://tailnet.example:4080', 'https://owner:token@desktop.example', 'https://desktop.example/private', 'https://desktop.example?token=bad', 'https://desktop.example#token', 'https://desktop.example/']) {
      f.services.config.publicUrl = origin;
      await failure(f.fetch('POST', '/v1/pairings', { clientNonce: opaqueToken() }), 'invalid_request');
    }
    f.services.config.publicUrl = 'http://127.0.0.1:4080';
    const local = await start(f);
    expect(new URL(local.issued.pairUrl).searchParams.get('backend')).toBe('http://127.0.0.1:4080');
    f.services.config.publicUrl = 'https://desktop.example';
    await failure(f.fetch('POST', '/v1/pairings/preview', { pairCode: local.pairCode, workspaceId: f.workspace.id }, null), 'forbidden');
    const configured = await success<P.PairingIssued>(f.fetch('POST', '/v1/pairings', { clientNonce: opaqueToken() }, undefined, { Host: 'forged.example', 'X-Forwarded-Host': 'forged.example' }), 201);
    expect(new URL(configured.pairUrl).searchParams.get('backend')).toBe('https://desktop.example');
    expect(f.persistentCalls).toBe(0);
  });
});
