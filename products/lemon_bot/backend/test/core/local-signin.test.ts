import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, readFile, rm, writeFile, symlink, lstat, utimes } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir, userInfo } from 'node:os';
import type * as P from '../../../contracts/protocol';
import { createBackend } from '../../src/index';
import { loadConfiguration, loopbackOrigin } from '../../src/core/config';
import { opaqueToken } from '../../src/core/auth';
import { localAccessPath } from '../../src/core/local-access';
import { issueOwnerSetupProof } from '../../src/core/setup';
import { issueLocalSignInTicket, localSignInTicketState, revokeLocalSignInTicket, sweepLocalSignIn, type LocalTicketDeps, type LocalTicketRow, type LocalTicketChannel, type LocalTicketIssued } from '../../src/core/local-signin';

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanups.splice(0)) await close(); });
const origin = 'http://127.0.0.1:4100';
const secretPassword = 'Isolated local sign-in test password 42';
async function fixture(environment: Record<string, string> = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-local-signin-'));
  const { config, key } = await loadConfiguration({ LEMON_BOT_DATA_DIR: directory, LEMON_BOT_OPERATOR_TOKEN: 'MOCK-controller-operator', LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:1/ws', ...environment });
  const backend = await createBackend(config, key);
  cleanups.push(async () => { await backend.stop(); await rm(directory, { recursive: true, force: true }); });
  let now = Date.now(); backend.services.now = () => now;
  const deps: LocalTicketDeps = { store: backend.services.store, now: () => now, digest: backend.services.mutations.digest, dataDir: directory };
  const request = (path: string, body?: unknown, token?: string, headers: Record<string, string> = {}, method = body === undefined ? 'GET' : 'POST') => backend.router.fetch(new Request(`${origin}/v1${path}`, { method, headers: { ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
  const issue = (channel: LocalTicketChannel = 'browser', withHandoffFile = false) => issueLocalSignInTicket(deps, { origin, channel, withHandoffFile });
  const ticket = (issued: LocalTicketIssued) => issued.url.split('=')[1]!;
  const redeem = (issued: LocalTicketIssued, headers: Record<string, string> = { Origin: origin, Host: '127.0.0.1:4100' }) => request('/auth/local/redeem', { ticket: ticket(issued) }, undefined, headers);
  return { directory, backend, deps, request, issue, redeem, ticket, advance(ms: number) { now += ms; }, now: () => now,
    async local() { const key = (await readFile(localAccessPath(directory), 'utf8')).trim(); return await (await request('/auth/local', {}, key)).json() as P.AuthResult; },
    async methods(token: string) { return await (await request('/me/sign-in', undefined, token)).json() as P.SignInMethods; },
  };
}
async function error(response: Response, status: number, code: P.ErrorCode) { expect(response.status).toBe(status); expect((await response.json()).error.code).toBe(code); }

describe('local sign-in tickets', () => {
  test('creates a passwordless owner once, consumes the setup proof and exposes no ticket in audit or cookie', async () => {
    const f = await fixture(); issueOwnerSetupProof(f.backend.services);
    const issued = f.issue();
    expect(f.deps.store.require<LocalTicketRow>('signInTickets', issued.id).digest).not.toBe(f.ticket(issued));
    const response = await f.redeem(issued); expect(response.status).toBe(200); expect(response.headers.has('Set-Cookie')).toBe(false);
    const result = await response.json() as P.AuthResult;
    expect(result.user.email).toBe(`${userInfo().username.toLowerCase().replace(/[^a-z0-9_+-]/g, '') || 'owner'}@lemon.local`);
    expect(result.workspace.ownerUserId).toBe(result.user.id); expect(f.deps.store.get('credentials', result.user.id)).toBeNull();
    for (const name of ['setupCode', 'setupCodeDigest', 'setupCodeState']) expect(f.deps.store.metadata(name)).toBeNull();
    expect(localSignInTicketState(f.deps, issued.id)).toBe('redeemed');
    expect(JSON.stringify(f.deps.store.list('auditRecords'))).not.toContain(f.ticket(issued));
    const methods = await f.methods(result.token);
    expect(methods.password).toBe(false); expect(methods.emailIsPlaceholder).toBe(true); expect(methods.localOwner?.osUser).toBe(userInfo().username);
    expect(methods.localConfirmedUntilMs).toBe(f.now() + 600_000);
    await error(await f.redeem(issued), 401, 'unauthenticated');
  });

  test('browser and terminal lifetimes are distinct and terminal tickets work until expiry', async () => {
    for (const [channel, duration] of [['browser', 60_000], ['terminal', 300_000]] as const) {
      const f = await fixture(); const issued = f.issue(channel);
      expect(issued.expiresAtMs).toBe(f.now() + duration);
      f.advance(duration + 1); expect(localSignInTicketState(f.deps, issued.id)).toBe('expired');
      await error(await f.redeem(issued), 410, 'expired');
    }
    const f = await fixture(); const issued = f.issue('terminal'); f.advance(299_000); expect((await f.redeem(issued)).status).toBe(200);
  });

  test('origin, host and all proxy headers are bound without consuming a ticket', async () => {
    const f = await fixture({ LEMON_BOT_PUBLIC_URL: 'https://x.ts.net' }); const issued = f.issue();
    for (const value of ['https://x.ts.net', 'http://localhost:4100', 'null']) {
      await error(await f.redeem(issued, { Origin: value, Host: '127.0.0.1:4100' }), 403, 'forbidden');
      expect(localSignInTicketState(f.deps, issued.id)).toBe('pending');
    }
    const refused: Record<string, string>[] = [{ Host: '127.0.0.1:4100' }, { Origin: origin, Host: 'localhost:4100' }, ...['Forwarded', 'X-Forwarded-For', 'X-Forwarded-Host', 'X-Forwarded-Proto', 'X-Real-IP', 'Tailscale-User-Login'].map(name => ({ Origin: origin, Host: '127.0.0.1:4100', [name]: 'MOCK-proxy' }))];
    for (const headers of refused) {
      expect((await f.redeem(issued, headers)).status).toBe(403); expect(localSignInTicketState(f.deps, issued.id)).toBe('pending');
    }
    expect((await f.redeem(issued, { Host: '127.0.0.1:4100', 'Sec-Fetch-Site': 'same-origin' })).status).toBe(200);
  });

  test('requires a numeric loopback listener and refuses persisted origin mismatches', async () => {
    expect(loopbackOrigin('127.0.0.1', 4100)).toBe(origin);
    expect(loopbackOrigin('::1', 4100)).toBe('http://[::1]:4100'); expect(loopbackOrigin('[::1]', 4100)).toBe('http://[::1]:4100');
    expect(loopbackOrigin('localhost', 4100)).toBeNull(); expect(loopbackOrigin('0.0.0.0', 4100)).toBeNull();
    const remote = await fixture({ LEMON_BOT_HOST: '0.0.0.0', LEMON_BOT_PUBLIC_URL: 'https://x.ts.net' });
    expect(() => issueLocalSignInTicket(remote.deps, { origin: 'https://x.ts.net', channel: 'browser', withHandoffFile: false })).toThrow();
    await error(await remote.request('/auth/local/redeem', { ticket: opaqueToken() }, undefined, { Host: '127.0.0.1:4100' }), 503, 'capability_unavailable');
    const f = await fixture(); const issued = f.issue(); const row = f.deps.store.require<LocalTicketRow>('signInTickets', issued.id);
    f.deps.store.put('signInTickets', { ...row, origin: 'http://127.0.0.1:9999' });
    await error(await f.redeem(issued), 403, 'forbidden'); expect(localSignInTicketState(f.deps, issued.id)).toBe('pending');
  });

  test('failure-only throttling persists, resets and never blocks valid tickets', async () => {
    const f = await fixture(); const headers = { Host: '127.0.0.1:4100', Origin: origin };
    for (let i = 0; i < 10; i++) await error(await f.request('/auth/local/redeem', { ticket: opaqueToken() }, undefined, headers), 401, 'unauthenticated');
    await error(await f.request('/auth/local/redeem', { ticket: opaqueToken() }, undefined, headers), 429, 'rate_limited');
    expect(f.deps.store.metadata<{ count: number }>('localTicketFail')?.count).toBe(11);
    expect((await f.redeem(f.issue())).status).toBe(200);
    f.advance(60_000); await error(await f.request('/auth/local/redeem', { ticket: opaqueToken() }, undefined, headers), 401, 'unauthenticated');
    expect(f.deps.store.metadata<{ count: number }>('localTicketFail')?.count).toBe(1);
  });

  test('caps outstanding tickets, frees expired/revoked/redeemed capacity and rejects malformed bodies/queries', async () => {
    const f = await fixture(); const first = f.issue(); for (let i = 1; i < 5; i++) f.issue('terminal');
    expect(() => f.issue()).toThrow(); f.advance(60_001); expect(f.issue().id).toStartWith('lst_');
    revokeLocalSignInTicket(f.deps, first.id); expect(localSignInTicketState(f.deps, first.id)).toBe('missing');
    const current = f.deps.store.list<LocalTicketRow>('signInTickets')[0]!; revokeLocalSignInTicket(f.deps, current.id); const next = f.issue();
    expect((await f.redeem(next)).status).toBe(200); expect(f.issue().id).toStartWith('lst_');
    for (const body of [{ ticket: 'invalid' }, { ticket: opaqueToken(), extra: true }, {}]) await error(await f.request('/auth/local/redeem', body, undefined, { Host: '127.0.0.1:4100', Origin: origin }), 400, 'invalid_request');
    await error(await f.request('/auth/local/redeem?extra=1', { ticket: opaqueToken() }), 400, 'invalid_request');
  });

  test('cleans redeemed/expired/orphan files but never arbitrary paths or symlinks', async () => {
    const f = await fixture(); const issued = f.issue('browser', true); await writeFile(issued.handoffFile!, 'MOCK-private-handoff');
    expect((await f.redeem(issued)).status).toBe(200); expect(await Bun.file(issued.handoffFile!).exists()).toBe(false);
    const outside = join(f.directory, 'keep.html'); await writeFile(outside, 'MOCK-keep');
    const tampered = f.issue(); const row = f.deps.store.require<LocalTicketRow>('signInTickets', tampered.id); f.deps.store.put('signInTickets', { ...row, handoffFile: outside });
    expect((await f.redeem(tampered)).status).toBe(200); expect(await Bun.file(outside).exists()).toBe(true);
    const linked = f.issue('browser', true); await symlink(outside, linked.handoffFile!); expect((await f.redeem(linked)).status).toBe(200); expect((await lstat(linked.handoffFile!)).isSymbolicLink()).toBe(true);
    const expired = f.issue('browser', true); await writeFile(expired.handoffFile!, 'MOCK-expired');
    const orphan = join(f.directory, 'handoff', 'open-lst_orphan.html'); const fresh = join(f.directory, 'handoff', 'open-lst_fresh.html'); const unrelated = join(f.directory, 'handoff', 'keep.html');
    await writeFile(orphan, 'MOCK-orphan'); await writeFile(fresh, 'MOCK-fresh'); await writeFile(unrelated, 'MOCK-keep');
    await utimes(orphan, new Date(f.now() - 700_000), new Date(f.now() - 700_000));
    f.advance(120_001); await sweepLocalSignIn(f.deps);
    expect(f.deps.store.get('signInTickets', expired.id)).toBeNull(); expect(await Bun.file(expired.handoffFile!).exists()).toBe(false);
    expect(await Bun.file(orphan).exists()).toBe(false); expect(await Bun.file(fresh).exists()).toBe(true); expect(await Bun.file(unrelated).exists()).toBe(true);
    expect((await lstat(linked.handoffFile!)).isSymbolicLink()).toBe(true);
  });

  test('tickets resolve the current workspace owner and nonowners have no local-owner method', async () => {
    const f = await fixture(); const owner = await f.local(); const issued = f.issue();
    const other = { ...owner.user, id: 'user_other', email: 'other@example.com' }; const member = { ...owner.member, id: 'member_other', userId: other.id, email: other.email, role: 'owner' as const };
    f.deps.store.put('users', other); f.deps.store.put('members', member); f.deps.store.put('members', { ...owner.member, role: 'member' });
    f.deps.store.put('workspaces', { ...owner.workspace, ownerUserId: other.id });
    const result = await (await f.redeem(issued)).json() as P.AuthResult; expect(result.user.id).toBe(other.id);
    expect((await f.methods(owner.token)).localOwner).toBeNull();
  });

  test('exact loopback frontend is trusted with a remote public origin, including realtime origin checks', async () => {
    const f = await fixture({ LEMON_BOT_PUBLIC_URL: 'https://x.ts.net' });
    expect(f.backend.router.originAllowed(new Request(origin, { headers: { Origin: origin } }))).toBe(true);
    expect(f.backend.router.originAllowed(new Request(origin, { headers: { Origin: 'http://localhost:4100' } }))).toBe(false);
    expect((await f.redeem(f.issue())).status).toBe(200);
    expect((await f.request('/auth/local/redeem', { ticket: opaqueToken() }, undefined, { Host: '127.0.0.1:4100', Origin: 'http://localhost:4100' })).status).toBe(403);
  });
});

describe('locally confirmed account methods', () => {
  test('first password updates email/member, replays its receipt, keeps sessions and allows ordinary password login', async () => {
    const f = await fixture(); const local = await f.local(); const body = { clientNonce: opaqueToken(), email: 'owner@example.com', password: secretPassword };
    expect((await f.methods(local.token)).localConfirmedUntilMs).toBe(f.now() + 600_000);
    const response = await f.request('/me/password', body, local.token); expect(response.status).toBe(200); const user = await response.json() as P.User;
    expect(user.email).toBe(body.email); expect(f.backend.services.auth.member(user.id).email).toBe(body.email);
    expect(await (await f.request('/me/password', body, local.token)).json()).toEqual(user);
    await error(await f.request('/me/password', { ...body, clientNonce: opaqueToken() }, local.token), 409, 'conflict');
    const loginResponse = await f.request('/auth/login', { clientNonce: opaqueToken(), email: body.email, password: body.password }); expect(loginResponse.status).toBe(200);
    const login = await loginResponse.json() as P.AuthResult; expect(login.user.id).toBe(local.user.id); expect((await f.methods(login.token)).localConfirmedUntilMs).toBeNull();
    expect((await f.methods(local.token)).password).toBe(true); expect((await f.methods(local.token)).emailIsPlaceholder).toBe(false); expect((await f.local()).user.id).toBe(local.user.id);
  });

  test('first password requires freshness, real unique email, no prior credential and non-SSO policy', async () => {
    const f = await fixture(); const local = await f.local(); const add = (email: string, token = local.token) => f.request('/me/password', { clientNonce: opaqueToken(), email, password: secretPassword }, token);
    await error(await add('owner@lemon.local'), 400, 'invalid_request');
    const other = { ...local.user, id: 'user_duplicate', email: 'taken@example.com' }; f.deps.store.put('users', other);
    await error(await add(other.email), 409, 'conflict');
    f.backend.services.integrations.requireSSO = () => true; await error(await add('new@example.com'), 403, 'policy_denied'); f.backend.services.integrations.requireSSO = () => false;
    const unconfirmed = await f.backend.services.auth.session(local.user.id); await error(await add('new@example.com', unconfirmed.token), 410, 'expired');
    f.advance(600_001); expect((await f.methods(local.token)).localConfirmedUntilMs).toBeNull(); await error(await add('new@example.com'), 410, 'expired');
  });

  test('local reauthentication is fresh-only, strictly shaped, honors SSO and authorizes account deletion', async () => {
    const f = await fixture(); const local = await f.local();
    await error(await f.request('/auth/reauth', {}, local.token), 400, 'invalid_request');
    await error(await f.request('/auth/reauth', { local: true, password: secretPassword }, local.token), 400, 'invalid_request');
    f.backend.services.integrations.requireSSO = () => true; await error(await f.request('/auth/reauth', { local: true }, local.token), 403, 'policy_denied'); f.backend.services.integrations.requireSSO = () => false;
    const result = await (await f.request('/auth/reauth', { local: true }, local.token)).json() as P.ReauthResult; expect(result.reauthToken).toBeString();
    // Account deletion still requires transferring the workspace; local reauth does not bypass that invariant.
    f.deps.store.put('users', { ...local.user, id: 'user_successor', email: 'successor@example.com' });
    f.deps.store.put('members', { ...local.member, id: 'member_successor', userId: 'user_successor', email: 'successor@example.com' });
    f.deps.store.put('members', { ...local.member, role: 'member' });
    f.deps.store.put('workspaces', { ...local.workspace, ownerUserId: 'user_successor' });
    const previewResponse = await f.request('/me/preview', { clientNonce: opaqueToken(), action: 'delete' }, local.token); expect(previewResponse.status).toBe(200); const preview = await previewResponse.json() as P.Confirmation;
    const deleted = await f.request('/me', { clientNonce: opaqueToken(), revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName, reauthToken: result.reauthToken }, local.token, {}, 'DELETE'); expect(deleted.status).toBe(200);
    const stale = await fixture(); const staleLocal = await stale.local(); stale.advance(600_001); await error(await stale.request('/auth/reauth', { local: true }, staleLocal.token), 401, 'unauthenticated');
  });

  test('password reauthentication remains supported and local proof also works for password users', async () => {
    const f = await fixture(); const local = await f.local();
    expect((await f.request('/me/password', { clientNonce: opaqueToken(), email: 'password@example.com', password: secretPassword }, local.token)).status).toBe(200);
    expect((await f.request('/auth/reauth', { password: secretPassword }, local.token)).status).toBe(200);
    expect((await f.request('/auth/reauth', { local: true }, local.token)).status).toBe(200);
    await error(await f.request('/auth/reauth', { password: 'MOCK-wrong-password' }, local.token), 401, 'unauthenticated');
  });
});
