import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../../src/core/services';
import { createAccountRoutes, createAccountService } from '../../src/core/accounts';
import { opaqueToken } from '../../src/core/auth';
import { ApiError } from '../../src/core/errors';
import { authFixture, routeContext } from './auth.test';

function accounts(hooks: Parameters<typeof createAccountRoutes>[1] = {}) {
  const fixture = authFixture(hooks); const routes = createAccountRoutes(fixture.services, hooks);
  async function call<T>(method: string, path: string, body: unknown = undefined, user: Principal | null = fixture.alice, params: Record<string, string> = {}): Promise<T> {
    const route = routes.find(value => value.method === method && value.path === path);
    if (!route) throw new Error('Account route not found.');
    const context = routeContext(fixture.services, route, body, user, params);
    return await route.handler(context) as T;
  }
  return { ...fixture, routes, call };
}
const authenticated = (token: string) => new Request('https://lemon.example/v1/me', { headers: { authorization: `Bearer ${token}` } });
const testPassword = 'Correct test password 42';

describe('account lifecycle', () => {
  test('setup atomically creates owner, session and workspace, consumes its digest and prevents repeats', async () => {
    const f = accounts(); for (const collection of ['users', 'members', 'workspaces']) for (const value of f.store.list<{ id: string }>(collection)) f.store.remove(collection, value.id);
    f.store.setMetadata('workspaceId', null); const setupCode = opaqueToken(); f.store.setMetadata('setupCodeDigest', f.services.mutations.digest(setupCode));
    expect(await f.call<P.SetupStatus>('GET', '/v1/setup', undefined, null)).toEqual({ setupRequired: true, version: '0.1.0', apiVersion: 1 });
    const body = { clientNonce: opaqueToken(), setupCode, email: ' First@Example.com ', password: testPassword, displayName: 'First', workspaceName: 'Work' };
    const result = await f.call<P.AuthResult>('POST', '/v1/setup', body, null);
    expect(result.user.email).toBe('first@example.com'); expect(result.member.role).toBe('owner'); expect(result.workspace.ownerUserId).toBe(result.user.id);
    expect(f.store.metadata('setupCodeDigest')).toBeNull(); expect(f.store.list('authSessions')).toHaveLength(1);
    const credential = f.store.require<{ passwordHash: string }>('credentials', result.user.id); expect(credential.passwordHash).not.toBe(testPassword); expect(await Bun.password.verify(testPassword, credential.passwordHash)).toBe(true);
    await expect(f.call('POST', '/v1/setup', { ...body, clientNonce: opaqueToken() }, null)).rejects.toMatchObject({ code: 'conflict' });
  });
  test('wrong email and password are uniform and authentication is rate-limited', async () => {
    const f = accounts(); f.store.put('credentials', { id: 'alice', passwordHash: await Bun.password.hash(testPassword, { algorithm: 'argon2id' }) });
    let missing: unknown; let wrong: unknown;
    try { await f.call('POST', '/v1/auth/login', { clientNonce: opaqueToken(), email: 'missing@example.com', password: testPassword }, null); } catch (error) { missing = error; }
    try { await f.call('POST', '/v1/auth/login', { clientNonce: opaqueToken(), email: 'alice@example.com', password: 'Incorrect password 42' }, null); } catch (error) { wrong = error; }
    expect(missing).toMatchObject({ code: 'unauthenticated' }); expect(wrong).toMatchObject({ code: 'unauthenticated' });
    expect(missing instanceof Error && wrong instanceof Error && missing.message === wrong.message).toBe(true);
    f.store.setMetadata(`authRate:${f.services.mutations.digest('alice@example.com')}`, { startedAtMs: f.services.now(), count: 10 });
    await expect(f.call('POST', '/v1/auth/login', { clientNonce: opaqueToken(), email: 'alice@example.com', password: testPassword }, null)).rejects.toMatchObject({ code: 'rate_limited' });
  });
  test('required SSO denies local credentials without issuing a session', async () => {
    const f = accounts(); f.store.put('credentials', { id: 'alice', passwordHash: await Bun.password.hash(testPassword) }); f.services.integrations.requireSSO = () => true;
    await expect(f.call('POST', '/v1/auth/login', { clientNonce: opaqueToken(), email: 'alice@example.com', password: testPassword }, null)).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.store.list('authSessions')).toHaveLength(0);
  });
  test('unknown fields, invalid timezones and nonces reject without applying account changes', async () => {
    const f = accounts(); const original = f.services.auth.user('alice');
    await expect(f.call('PATCH', '/v1/me', { clientNonce: opaqueToken(), revision: 1, role: 'owner' })).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(f.call('PATCH', '/v1/me', { clientNonce: 'short', revision: 1, displayName: 'Changed' })).rejects.toMatchObject({ code: 'invalid_request' });
    await expect(f.call('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: 1, timezone: 'Invented/Timezone' }, f.owner)).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.services.auth.user('alice')).toEqual(original);
  });
  test('final enabled owner cannot be demoted, disabled, removed or delete their account', async () => {
    const f = accounts(); const member = f.services.auth.member('owner');
    for (const changes of [{ role: 'admin' }, { enabled: false }]) await expect(f.call('PATCH', '/v1/members/:id', { clientNonce: opaqueToken(), revision: member.revision, ...changes }, f.owner, { id: member.id })).rejects.toMatchObject({ code: 'conflict' });
    await expect(f.call('POST', '/v1/members/:id/preview', { clientNonce: opaqueToken(), action: 'delete' }, f.owner, { id: member.id })).rejects.toMatchObject({ code: 'conflict' });
    await expect(f.call('POST', '/v1/me/preview', { clientNonce: opaqueToken(), action: 'delete' }, f.owner)).rejects.toMatchObject({ code: 'conflict' });
    expect(f.services.auth.member('owner')).toEqual(member);
  });
  test('owner transfer promotes enabled target and demotes old owner atomically', async () => {
    const f = accounts(); const workspace = await f.call<P.Workspace>('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: f.workspace.revision, ownerUserId: 'alice' }, f.owner);
    expect(workspace.ownerUserId).toBe('alice'); expect(f.services.auth.member('alice').role).toBe('owner'); expect(f.services.auth.member('owner').role).toBe('admin');
    const disabled = f.services.update(f.services.auth.member('admin'), { enabled: false }); f.store.put('members', disabled);
    await expect(f.call('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: workspace.revision, ownerUserId: 'admin' }, { ...f.alice, role: 'owner' })).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.store.require<P.Workspace>('workspaces', workspace.id).ownerUserId).toBe('alice');
  });
  test('password change retains current session and revokes every other session with callbacks', async () => {
    const revoked: string[] = []; const f = accounts({ onRevokeSession: sessionId => { revoked.push(sessionId); } });
    f.store.put('credentials', { id: 'alice', passwordHash: await Bun.password.hash(testPassword) });
    const current = await f.services.auth.session('alice'); const other = await f.services.auth.session('alice'); const actor = { ...f.alice, sessionId: current.session.id };
    await f.call('PUT', '/v1/me/password', { clientNonce: opaqueToken(), currentPassword: testPassword, newPassword: 'Replacement password 77' }, actor);
    expect((await f.services.auth.authenticate(authenticated(current.token)))?.sessionId).toBe(current.session.id);
    await expect(f.services.auth.authenticate(authenticated(other.token))).rejects.toMatchObject({ code: 'unauthenticated' }); expect(revoked).toEqual([other.session.id]);
    expect(await Bun.password.verify('Replacement password 77', f.store.require<{ passwordHash: string }>('credentials', 'alice').passwordHash)).toBe(true);
  });
  test('an invitation never resets an existing local password', async () => {
    const f = accounts(); const existing = f.addUser('returning'); f.store.put('members', f.services.update(f.services.auth.member('returning'), { enabled: false }));
    const passwordHash = await Bun.password.hash(testPassword); f.store.put('credentials', { id: existing.userId, passwordHash });
    const issued = await f.call<P.InviteIssued>('POST', '/v1/invites', { clientNonce: opaqueToken(), email: 'returning@example.com', role: 'member' }, f.owner);
    const body = { clientNonce: opaqueToken(), inviteToken: issued.inviteToken, email: 'returning@example.com', password: 'Attack replacement password', displayName: 'Replacement' };
    await expect(f.call('POST', '/v1/auth/invites/accept', body, null)).rejects.toMatchObject({ code: 'unauthenticated' });
    expect(f.store.require('credentials', existing.userId)).toEqual({ id: existing.userId, passwordHash });
    const accepted = await f.call<P.AuthResult>('POST', '/v1/auth/invites/accept', { ...body, clientNonce: opaqueToken(), password: testPassword }, null);
    expect(accepted.user.displayName).toBe('returning'); expect(accepted.member.enabled).toBe(true); expect(f.store.require('credentials', existing.userId)).toEqual({ id: existing.userId, passwordHash });
    await expect(f.call('POST', '/v1/auth/invites/accept', { ...body, clientNonce: opaqueToken(), password: testPassword }, null)).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('installation registration reuses its ID, binds session and never gives another account device authority', async () => {
    const f = accounts(); const auth = await f.services.auth.session('alice'); const actor = { ...f.alice, sessionId: auth.session.id };
    const body = { clientNonce: opaqueToken(), installationId: opaqueToken(), platform: 'web', name: 'Browser', appVersion: '1' };
    const first = await f.call<P.Device>('POST', '/v1/devices', body, actor); const second = await f.call<P.Device>('POST', '/v1/devices', { ...body, clientNonce: opaqueToken(), name: 'Renamed' }, actor);
    expect(second.id).toBe(first.id); expect(second.revision).toBe(first.revision + 1); expect(f.store.require<P.AuthSession>('authSessions', auth.session.id).deviceId).toBe(first.id);
    await expect(f.call('PATCH', '/v1/devices/:id', { clientNonce: opaqueToken(), revision: second.revision, name: 'Stolen' }, f.admin, { id: first.id })).rejects.toMatchObject({ code: 'not_found' });
    const denied = { ...body, clientNonce: opaqueToken(), push: { kind: 'web_push', endpoint: 'http://127.0.0.1/private', keys: { p256dh: 'invalid', auth: 'invalid' } } };
    await expect(f.call('POST', '/v1/devices', denied, actor)).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.store.list('devices')).toHaveLength(1);
  });
  test('logout preserves push only while another live session owns the installation', async () => {
    const f = accounts(); const device: P.Device = f.services.resource('device', { userId: 'alice', platform: 'ios', name: 'Phone', appVersion: '1', pushEnabled: true, lastSeenAtMs: f.services.now() }); f.store.put('devices', device);
    const first = await f.services.auth.session('alice', device.id); const second = await f.services.auth.session('alice', device.id);
    await f.call('POST', '/v1/auth/logout', { clientNonce: opaqueToken() }, { ...f.alice, sessionId: first.session.id }); expect(f.store.require<P.Device>('devices', device.id).pushEnabled).toBe(true);
    await f.call('POST', '/v1/auth/logout', { clientNonce: opaqueToken() }, { ...f.alice, sessionId: second.session.id }); expect(f.store.require<P.Device>('devices', device.id).pushEnabled).toBe(false);
  });
  test('persistent device sessions stay listed past thirty days and device deletion revokes every credential', async () => {
    const revoked: string[] = []; const f = accounts({ onRevokeSession: sessionId => { revoked.push(sessionId); } });
    const device = await f.call<P.Device>('POST', '/v1/devices', { clientNonce: opaqueToken(), installationId: 'phone-persistent', platform: 'ios', name: 'Phone', appVersion: '1.0.0' });
    const first = await f.services.auth.session('alice', device.id, { persistent: true }); const second = await f.services.auth.session('alice', device.id, { persistent: true });
    expect(first.session.expiresAtMs).toBeNull(); expect(second.session.expiresAtMs).toBeNull();
    f.advance(31 * 86400000);
    expect((await f.services.auth.authenticate(authenticated(first.token)))?.deviceId).toBe(device.id);
    const sessions = await f.call<P.Page<P.AuthSession>>('GET', '/v1/auth/sessions');
    expect(sessions.items.map(value => value.id).sort()).toEqual([first.session.id, second.session.id].sort());
    await f.call('DELETE', '/v1/devices/:id', { clientNonce: opaqueToken() }, f.alice, { id: device.id });
    expect(revoked.sort()).toEqual([first.session.id, second.session.id].sort());
    expect(f.store.get('devices', device.id)).toBeNull();
    expect(f.store.get('authSessions', first.session.id)).toBeNull();
    expect(f.store.get('sessionSecrets', first.session.id)).toMatchObject({ revoked: true });
    await expect(f.services.auth.authenticate(authenticated(first.token))).rejects.toMatchObject({ code: 'unauthenticated' });
    await expect(f.services.auth.authenticate(authenticated(second.token))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('membership administration cannot acquire another member live bot even with legacy team labels', async () => {
    const f = accounts(); const bot = f.addBot('alice'); const conversation = f.addConversation(bot, 'alice'); const auth = await f.services.auth.session('alice'); const member = f.services.auth.member('alice');
    const legacy: P.Bot & { visibility: 'team'; published: true; managerUserIds: string[] } = { ...bot, visibility: 'team', published: true, managerUserIds: ['admin', 'owner'] };
    f.store.put('bots', legacy);
    await f.call('GET', '/v1/members', undefined, f.owner);
    expect(() => f.services.auth.bot(f.owner, bot.id)).toThrow(ApiError);
    expect(() => f.services.auth.bot(f.admin, bot.id, true)).toThrow(ApiError);
    await f.call('PATCH', '/v1/members/:id', { clientNonce: opaqueToken(), revision: member.revision, enabled: false }, f.owner, { id: member.id });
    await expect(f.services.auth.authenticate(authenticated(auth.token))).rejects.toMatchObject({ code: 'unauthenticated' }); expect(f.cancelled).toEqual(['alice']);
    expect(f.store.get('conversations', conversation.id)).not.toBeNull(); expect(f.services.auth.canRead(f.owner, 'conversations', conversation)).toBe(false);
  });
  test('stale account preview rejects an expanded resource set before consuming reauth', async () => {
    const f = accounts(); const preview = await f.call<P.Confirmation>('POST', '/v1/me/preview', { clientNonce: opaqueToken(), action: 'delete' }); const reauth = f.services.auth.issueReauth('alice');
    f.store.put('sections', f.services.resource('section', { userId: 'alice', name: 'New', rank: 0, collapsed: false }));
    await expect(f.call('DELETE', '/v1/me', { clientNonce: opaqueToken(), revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName, reauthToken: reauth.reauthToken })).rejects.toMatchObject({ code: 'confirmation_required' });
    f.services.auth.consumeReauth('alice', reauth.reauthToken); expect(f.store.get('users', 'alice')).not.toBeNull();
  });
  test('local account deletion consumes exact preview and reauth, removes data and revokes authority', async () => {
    const f = accounts(); const auth = await f.services.auth.session('alice'); const actor = { ...f.alice, sessionId: auth.session.id };
    f.store.put('sections', f.services.resource('section', { userId: 'alice', name: 'Own', rank: 0, collapsed: false }));
    const preview = await f.call<P.Confirmation>('POST', '/v1/me/preview', { clientNonce: opaqueToken(), action: 'delete' }, actor);
    const reauth = f.services.auth.issueReauth('alice');
    const result = await f.call<P.Deleted>('DELETE', '/v1/me', { clientNonce: opaqueToken(), revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName, reauthToken: reauth.reauthToken }, actor);
    expect(result).toEqual({ id: 'alice', deleted: true }); expect(f.store.get('users', 'alice')).toBeNull(); expect(f.store.list('sections')).toHaveLength(0); expect(f.store.list<P.Member>('members', value => value.userId === 'alice')).toHaveLength(0);
    await expect(f.services.auth.authenticate(authenticated(auth.token))).rejects.toMatchObject({ code: 'unauthenticated' });
    expect(f.store.get('reauthTokens', f.services.mutations.digest(reauth.reauthToken))).toBeNull();
    const records = f.store.list<P.AccountTeardown>('accountTeardowns');
    expect(records).toHaveLength(1); expect(records[0]).toMatchObject({ state: 'completed', productCleanup: { state: 'completed' }, providerCleanup: [] });
  });
  test('provider-owned account data requires a real cleanup preview implementation', async () => {
    const f = accounts(); f.store.put('identityLinks', f.services.resource('identity', { userId: 'alice', providerId: 'configured-provider', issuer: 'https://identity.example', subject: 'subject', lastUsedAtMs: null }));
    await expect(f.call('POST', '/v1/me/preview', { clientNonce: opaqueToken(), action: 'delete' })).rejects.toMatchObject({ code: 'capability_unavailable' });
    expect(f.store.get('users', 'alice')).not.toBeNull();
  });
  test('pre-revocation callback sees enabled target, before membership authority is disabled', async () => {
    const targets: string[] = []; let services: BackendServices | undefined;
    const f = accounts({ beforeRevokeUser: actor => { expect(services?.auth.member(actor.userId).enabled).toBe(true); targets.push(actor.userId); } });
    services = f.services;
    const member = f.services.auth.member('alice');
    await f.call('PATCH', '/v1/members/:id', { clientNonce: opaqueToken(), revision: member.revision, enabled: false }, f.owner, { id: member.id });
    expect(targets).toEqual(['alice']); expect(f.services.auth.member('alice').enabled).toBe(false);
  });
  test('durable account mutation replays exact receipt and rejects conflicting intent', async () => {
    const f = accounts(); const route = f.routes.find(value => value.method === 'PATCH' && value.path === '/v1/me') as Route;
    const body = { clientNonce: opaqueToken(), revision: 1, displayName: 'Updated' }; const context = routeContext(f.services, route, body, f.alice);
    const first = await f.services.mutations.execute(context, () => route.handler(context));
    const repeat = routeContext(f.services, route, body, f.alice); const second = await f.services.mutations.execute(repeat, () => route.handler(repeat));
    expect(second).toEqual(first); expect(f.services.auth.user('alice').revision).toBe(2);
    const conflicting = routeContext(f.services, route, { ...body, displayName: 'Other' }, f.alice);
    await expect(f.services.mutations.execute(conflicting, () => route.handler(conflicting))).rejects.toMatchObject({ code: 'nonce_conflict' });
  });
  test('successful login receipt cannot replay old credentials after a password change', async () => {
    const f = accounts(); f.store.put('credentials', { id: 'alice', passwordHash: await Bun.password.hash(testPassword) });
    const route = f.routes.find(value => value.method === 'POST' && value.path === '/v1/auth/login');
    if (!route) throw new Error('Login route is required.');
    const body = { clientNonce: opaqueToken(), email: 'alice@example.com', password: testPassword };
    const initial = routeContext(f.services, route, body, null);
    const login = await f.services.mutations.execute(initial, () => route.handler(initial)) as P.AuthResult;
    const actor = { ...f.alice, sessionId: login.session.id };
    await f.call('PUT', '/v1/me/password', { clientNonce: opaqueToken(), currentPassword: testPassword, newPassword: 'New current password 42' }, actor);
    const repeat = routeContext(f.services, route, body, null);
    await expect(f.services.mutations.execute(repeat, () => route.handler(repeat))).rejects.toMatchObject({ code: 'unauthenticated' });
    expect((await f.services.auth.authenticate(authenticated(login.token)))?.sessionId).toBe(login.session.id);
  });
  test('provider uncertainty still removes reachable local data and remains Owner-observable without replay', async () => {
    const f = accounts(); const auth = await f.services.auth.session('alice'); const actor = { ...f.alice, sessionId: auth.session.id };
    const provider: P.OIDCProvider = f.services.resource('provider', { name: 'Identity', issuer: 'https://identity.example', clientId: 'client', scopes: ['openid'], allowedEmailDomains: ['example.com'], enabled: true, requireSSO: false, groupClaim: null, clientSecretRef: 'test-provider', endSessionEndpoint: 'https://identity.example/logout' });
    f.store.put('oidcProviders', provider); f.store.put('oidcProviderSessions', { id: f.services.id('provider_session'), userId: 'alice', providerId: provider.id, encryptedIDToken: f.services.encrypt('test-id-token') });
    f.store.put('sections', f.services.resource('section', { userId: 'alice', name: 'Own', rank: 0, collapsed: false }));
    let dispatches = 0;
    f.services.integrations.deprovisionUser = async userId => {
      dispatches++;
      for (const row of f.store.list<P.ProviderCleanupResult & { id: string; userId: string }>('providerTeardownReceipts', row => row.userId === userId)) f.store.put('providerTeardownReceipts', { ...row, state: 'outcome_unknown', errorCode: 'upstream_unavailable' });
      throw new ApiError('outcome_unknown', 'Provider outcome is unconfirmed.', false);
    };
    f.services.integrations.observeAccountTeardown = async operationId => f.store.list<P.ProviderCleanupResult & { operationId: string }>('providerTeardownReceipts', row => row.operationId === operationId).map(row => ({ providerId: row.providerId, kind: row.kind, receiptId: row.receiptId, state: row.state, updatedAtMs: row.updatedAtMs, errorCode: row.errorCode }));
    const preview = await f.call<P.Confirmation>('POST', '/v1/me/preview', { clientNonce: opaqueToken(), action: 'delete' }, actor); const reauth = f.services.auth.issueReauth('alice');
    await expect(f.call('DELETE', '/v1/me', { clientNonce: opaqueToken(), revision: preview.revision, confirmationToken: preview.confirmationToken, confirmName: preview.confirmName, reauthToken: reauth.reauthToken }, actor)).rejects.toMatchObject({ code: 'outcome_unknown', retrySafe: false });
    expect(f.store.get('users', 'alice')).toBeNull(); expect(f.store.list('sections')).toHaveLength(0);
    const ledger = f.store.list<P.AccountTeardown>('accountTeardowns')[0]; if (!ledger) throw new Error('Durable teardown is required.');
    const status = await f.call<P.AccountTeardown>('GET', '/v1/account-teardowns/:id', undefined, f.owner, { id: ledger.id });
    expect(status).toMatchObject({ state: 'outcome_unknown', productCleanup: { state: 'completed' }, providerCleanup: [{ state: 'outcome_unknown' }] });
    expect(JSON.stringify(status)).not.toContain('encryptedBinding'); expect(JSON.stringify(status)).not.toContain('encryptedCapability');
    await expect(f.call('GET', '/v1/account-teardowns/:id', undefined, f.admin, { id: ledger.id })).rejects.toMatchObject({ code: 'forbidden' });
    await createAccountService(f.services).reconcile(); expect(dispatches).toBe(1);
    await expect(f.services.auth.authenticate(authenticated(auth.token))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('ordinary login input cannot request persistent session authority', async () => {
    const f = accounts();
    await expect(f.call('POST', '/v1/auth/login', { clientNonce: opaqueToken(), email: 'alice@example.com', password: testPassword, persistent: true }, null)).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.store.list('authSessions')).toHaveLength(0);
  });
  test('workspace disable permanently revokes paired credentials while bounded Owner authority can repair', async () => {
    const revoked: string[] = []; const f = accounts({ onRevokeSession: sessionId => { revoked.push(sessionId); } });
    const device = await f.call<P.Device>('POST', '/v1/devices', { clientNonce: opaqueToken(), installationId: 'revoked-phone', platform: 'ios', name: 'Phone', appVersion: '1.0.0' });
    const paired = await f.services.auth.session('alice', device.id, { persistent: true });
    const desktop = await f.services.auth.session('owner');
    const owner: Principal = { ...f.owner, sessionId: desktop.session.id };
    const disabled = await f.call<P.Workspace>('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: f.workspace.revision, enabled: false }, owner);
    expect(revoked).toEqual([paired.session.id]);
    expect(f.store.get('authSessions', paired.session.id)).toBeNull();
    expect(f.store.get('sessionSecrets', paired.session.id)).toMatchObject({ revoked: true });
    expect((await f.services.auth.authenticate(authenticated(desktop.token), 'owner'))?.userId).toBe('owner');
    await f.call('PATCH', '/v1/workspace', { clientNonce: opaqueToken(), revision: disabled.revision, enabled: true }, owner);
    await expect(f.services.auth.authenticate(authenticated(paired.token))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('a persistent bearer cannot rebind itself to another installation to evade device revocation', async () => {
    const f = accounts();
    const body = { clientNonce: opaqueToken(), installationId: 'original-phone', platform: 'ios', name: 'Phone', appVersion: '1.0.0' };
    const device = await f.call<P.Device>('POST', '/v1/devices', body);
    const paired = await f.services.auth.session('alice', device.id, { persistent: true });
    const actor: Principal = { ...f.alice, sessionId: paired.session.id, deviceId: device.id };
    await expect(f.call('POST', '/v1/devices', { ...body, clientNonce: opaqueToken(), installationId: 'other-phone' }, actor)).rejects.toMatchObject({ code: 'forbidden' });
    expect(f.store.list('devices')).toHaveLength(1);
    const refreshed = await f.call<P.Device>('POST', '/v1/devices', { ...body, clientNonce: opaqueToken(), appVersion: '2.0.0' }, actor);
    expect(refreshed.id).toBe(device.id);
    expect(f.store.require<P.AuthSession>('authSessions', paired.session.id).deviceId).toBe(device.id);
    await f.call('DELETE', '/v1/devices/:id', { clientNonce: opaqueToken() }, f.alice, { id: device.id });
    await expect(f.services.auth.authenticate(authenticated(paired.token))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
});
