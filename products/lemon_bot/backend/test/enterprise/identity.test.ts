import { describe, expect, test } from 'bun:test';
import { Database } from 'bun:sqlite';
import { generateKeyPairSync, sign } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, EntityStore, Principal, RequestContext, Route } from '../../src/core/services';
import { ApiError } from '../../src/core/errors';
import { createIdentityRoutes, createIdentityServices, createProvisionedUser, verifyOIDCToken } from '../../src/enterprise/identity';
import { secureToken, tokenDigest } from '../../src/enterprise/tokens';

/** Real isolated SQLite persistence; provider transport is the only network seam. */
export function identityFixture() {
  const db = new Database(':memory:'); db.exec('CREATE TABLE entities (collection TEXT NOT NULL, id TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(collection,id)); CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  const store: EntityStore = {
    db,
    get<T>(collection: string, id: string): T | null { const row = db.query('SELECT value FROM entities WHERE collection=? AND id=?').get(collection, id) as { value: string } | null; return row ? JSON.parse(row.value) as T : null; },
    require<T>(collection: string, id: string): T { const value = store.get<T>(collection, id); if (!value) throw new ApiError('not_found', 'Resource not found.'); return value; },
    list<T>(collection: string, predicate?: (value: T) => boolean): T[] { const rows = db.query('SELECT value FROM entities WHERE collection=? ORDER BY id').all(collection) as { value: string }[]; const values = rows.map(row => JSON.parse(row.value) as T); return predicate ? values.filter(predicate) : values; },
    put<T>(collection: string, value: T & { id: string }): T { db.query('INSERT INTO entities VALUES(?,?,?) ON CONFLICT(collection,id) DO UPDATE SET value=excluded.value').run(collection, value.id, JSON.stringify(value)); return value; },
    remove(collection, id) { db.query('DELETE FROM entities WHERE collection=? AND id=?').run(collection, id); },
    transaction<T>(operation: () => T): T { return db.transaction(operation)(); },
    metadata<T>(key: string): T | null { const row = db.query('SELECT value FROM metadata WHERE key=?').get(key) as { value: string } | null; return row ? JSON.parse(row.value) as T : null; },
    setMetadata(key, value) { db.query('INSERT INTO metadata VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value').run(key, JSON.stringify(value)); },
  };
  let clock = Date.UTC(2026, 9, 14); let sequence = 0; const events: unknown[] = []; const revoked: string[] = []; const cancelled: string[] = [];
  const unavailable = (): never => { throw new Error('This test does not configure this boundary.'); };
  const operator: P.OperatorConfiguration = { version: 1, trustedFrontendOrigins: [], oauthRedirectUris: ['lemonbot://auth/complete'], serverSecrets: { oidc: { kind: 'env', name: 'OIDC_TEST_SECRET' } }, channelProviders: [], emailProviders: [], eventProviders: [{ id: 'github', source: 'github', signingSecretRef: 'sig', eventNames: ['push'], routineIds: [], principalUserId: 'owner', maxAgeMs: 300000 }], hostDrivers: [], xProvider: null, exportAllowedOrigins: [], requiredRuntimeDestinations: [], breakGlassOwnerUserId: null };
  operator.oidcAllowedOrigins = ['https://idp.example'];
  operator.oidcApprovedPrivateOrigins = ['https://idp.example'];
  operator.oidcClientApprovals = [{ origin: 'https://idp.example', clientId: 'client', clientSecretRef: 'oidc' }];
  const services: BackendServices = {
    config: { publicUrl: 'https://product.example', controlUrl: 'wss://controller.example/ws', operatorToken: 'server-only', dataDir: '/private/test', host: '127.0.0.1', port: 4080, trustedOverlay: false, operator }, store,
    id: prefix => `${prefix ?? 'id'}_${++sequence}`, now: () => clock,
    resource<T extends object>(prefix: string, fields: T): T & P.Resource { return { ...fields, id: services.id(prefix), revision: 1, createdAtMs: clock, updatedAtMs: clock }; },
    update<T extends { revision: number; updatedAtMs: number }>(resource: T, changes: Partial<T>): T { return { ...resource, ...changes, revision: resource.revision + 1, updatedAtMs: clock }; },
    page: (_context, items) => ({ items, nextCursor: null }), pageAfter: unavailable, secret: async () => 'test-client-secret', encrypt: value => Buffer.from(JSON.stringify(value)).toString('base64'), decrypt: <T>(value: string): T => JSON.parse(Buffer.from(value, 'base64').toString()) as T,
    events: { emit: (event, payload) => { const value = { type: 'event' as const, seq: String(++sequence), event, timestampMs: clock, payload }; events.push(value); return value as P.RealtimeEvent; }, cursor: () => String(sequence), earliestCursor: () => '1', replay: () => [], visible: () => true, subscribe: unavailable },
    auth: {
      authenticate: async () => null, user: userId => store.require<P.User>('users', userId), member: userId => { const member = store.list<P.Member>('members').find(value => value.userId === userId); if (!member) throw new ApiError('forbidden', 'No membership.'); return member; }, requireRole: (principal, role) => { if (principal.role !== 'owner' && principal.role !== role) throw new ApiError('forbidden', 'Role required.'); }, bot: unavailable, conversation: unavailable, machine: unavailable, attachment: unavailable, canRead: () => false,
      revokeUser: async userId => { revoked.push(userId); for (const session of store.list<P.AuthSession>('authSessions', value => value.userId === userId)) store.remove('authSessions', session.id); for (const device of store.list<P.Device>('devices', value => value.userId === userId)) store.remove('devices', device.id); for (const routine of store.list<P.Routine>('routines', value => value.ownerUserId === userId)) store.put('routines', services.update(routine, { enabled: false })); },
      session: async (userId, deviceId = null) => { const token = secureToken(); const session = services.resource('session', { userId, deviceId, expiresAtMs: clock + 2592000000, lastSeenAtMs: clock, current: true }); store.put('authSessions', session); store.put('sessionSecrets', { id: session.id, tokenDigest: tokenDigest(token) }); return { token, session, user: services.auth.user(userId), workspace: store.list<P.Workspace>('workspaces')[0]!, member: services.auth.member(userId) }; },
      issueReauth: userId => { const token = secureToken(); const expiresAtMs = clock + 300000; store.put('reauthTokens', { id: tokenDigest(token), userId, expiresAtMs }); return { reauthToken: token, expiresAtMs }; },
      consumeReauth: (userId, token) => { const key = tokenDigest(token); const row = store.get<{ id: string; userId: string; expiresAtMs: number }>('reauthTokens', key); if (!row || row.userId !== userId || row.expiresAtMs <= clock) throw new ApiError('expired', 'Reauth expired.'); store.remove('reauthTokens', key); },
    },
    mutations: { execute: async (_context, operation) => operation(), checkRevision: (resource, revision) => { if (resource.revision !== revision) throw new ApiError('revision_conflict', 'Revision changed.'); }, preview: unavailable, confirm: unavailable, digest: value => tokenDigest(JSON.stringify(value)) },
    lemon: { connected: false, methods: [], call: unavailable, onEvent: unavailable, onConnected: unavailable, start: unavailable, close: unavailable }, runtime: { submit: unavailable, send: unavailable, cancel: unavailable, revokeConnectorInvocations: unavailable, reconcile: unavailable, sessionKey: unavailable }, attachments: { create: unavailable, copy: unavailable, bytes: unavailable, download: unavailable }, gates: { create: unavailable, resolve: unavailable, wait: unavailable, cancelUser: userId => { cancelled.push(userId); } },
    integrations: { admission: unavailable, effectivePolicy: async principal => ({ userId: principal.userId, botId: null, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] }), connectorConfig: unavailable, sendApprovedDraft: unavailable, emitProviderNotifications: unavailable, channelIngress: unavailable, providerCapabilities: () => ({}) },
    audit: (principal, action, targetId, outcome, details, requestId) => { const actor: P.Actor = { kind: principal?.kind === 'user' ? 'user' : principal?.kind === 'bot' ? 'bot' : 'system', id: principal?.id ?? null, displayName: 'Test actor' }; const value = services.resource('audit', { actor, action, resourceType: 'identity', resourceId: targetId, outcome, metadata: details ?? {}, requestId: requestId ?? 'req_test' }); store.put('audit', value); return value; }, entry: unavailable, notify: unavailable, invoke: unavailable,
    syncBotProfile: unavailable,
  };
  const owner = createProvisionedUser(services, 'owner@example.com', 'Owner'); const ownerMember = services.auth.member(owner.id); store.put('members', { ...ownerMember, role: 'owner' }); const workspace = services.resource('workspace', { ownerUserId: owner.id, name: 'Workspace', enabled: true, timezone: 'UTC' }); store.put('workspaces', workspace);
  const principal: Principal = { kind: 'user', id: owner.id, userId: owner.id, workspaceId: workspace.id, role: 'owner', sessionId: 'current-session', deviceId: null, botId: null };
  return { services, principal, events, revoked, cancelled, advance: (ms: number) => { clock += ms; }, close: () => db.close() };
}
export async function invokeRoute(routes: Route[], services: BackendServices, method: string, path: string, body: unknown = undefined, options: { principal?: Principal | null; params?: Record<string, string>; query?: string; headers?: Record<string, string> } = {}): Promise<unknown> {
  const route = routes.find(value => value.method === method && value.path === path); if (!route) throw new Error(`Missing route ${method} ${path}`);
  const query = new URLSearchParams(options.query); const request = new Request(`https://product.example${path}${query.size ? `?${query}` : ''}`, { method, headers: options.headers });
  const context: RequestContext = { request, params: options.params ?? {}, query, body, user: options.principal ?? null, services, requestId: 'req_test', route, nonceResourceIds: [] }; return route.handler(context);
}
const keyPair = generateKeyPairSync('rsa', { modulusLength: 2048 }); const jwk = { ...keyPair.publicKey.export({ format: 'jwk' }), kid: 'test', use: 'sig', alg: 'RS256' };
const discovery = { issuer: 'https://idp.example', authorization_endpoint: 'https://idp.example/authorize', token_endpoint: 'https://idp.example/token', jwks_uri: 'https://idp.example/jwks', code_challenge_methods_supported: ['S256'], id_token_signing_alg_values_supported: ['RS256'] };
function jwt(claims: Record<string, unknown>): string { const header = Buffer.from(JSON.stringify({ alg: 'RS256', kid: 'test' })).toString('base64url'); const payload = Buffer.from(JSON.stringify(claims)).toString('base64url'); const bytes = `${header}.${payload}`; return `${bytes}.${sign('sha256', Buffer.from(bytes), keyPair.privateKey).toString('base64url')}`; }
function registeredProvider(services: BackendServices): P.OIDCProvider { const provider = services.resource('oidc_provider', { name: 'Example', issuer: discovery.issuer, clientId: 'client', scopes: ['openid', 'email'], allowedEmailDomains: ['example.com'], enabled: true, requireSSO: true, groupClaim: 'groups', clientSecretRef: 'oidc', endSessionEndpoint: null }); services.store.put('oidcProviders', provider); return provider; }

describe('OIDC identity security', () => {
  test('signature, issuer, audience, nonce, expiration, nbf and verified email are enforced', async () => {
    const f = identityFixture(); try { const p = registeredProvider(f.services); const now = f.services.now(); const claims = { iss: p.issuer, sub: 'subject', aud: 'client', nonce: 'nonce', email: 'user@example.com', email_verified: true, exp: now / 1000 + 300, iat: now / 1000, nbf: now / 1000 };
      f.services.http = (async () => Response.json({ keys: [jwk] }));
      expect((await verifyOIDCToken(jwt(claims), p, discovery, 'nonce', now, now, 'login', f.services)).subject).toBe('subject');
      for (const changes of [{ iss: 'https://evil.example' }, { aud: 'other' }, { nonce: 'wrong' }, { exp: now / 1000 }, { nbf: now / 1000 + 1 }, { email_verified: false }, { auth_time: now / 1000 - 600 }]) {
        await expect(verifyOIDCToken(jwt({ ...claims, ...changes }), p, discovery, 'nonce', now, now, 'auth_time' in changes ? 'reauth' : 'login', f.services)).rejects.toBeInstanceOf(ApiError);
      }
      const token = jwt(claims); await expect(verifyOIDCToken(`${token.slice(0, -8)}AAAAAAAA`, p, discovery, 'nonce', now, now, 'login', f.services)).rejects.toBeInstanceOf(ApiError);
    } finally { f.close(); }
  });
  test('browser and backend PKCE, callback state, subject linking and one-time completion', async () => {
    const f = identityFixture(); try { const p = registeredProvider(f.services); const routes = createIdentityRoutes(f.services); const verifier = secureToken(); let expectedNonce = ''; let backendChallenge = ''; let returnedToken = ''; let calls = 0;
      f.services.http = (async (input: string | URL | Request, init?: RequestInit) => {
        const url = String(input); if (url.endsWith('openid-configuration')) return Response.json(discovery); if (url.endsWith('/jwks')) return Response.json({ keys: [jwk] });
        calls++; const form = new URLSearchParams(String(init?.body)); expect(Buffer.from(tokenDigest(form.get('code_verifier')!), 'hex').toString('base64url')).toBe(backendChallenge); expect(form.get('redirect_uri')).toContain(encodeURIComponent(p.id)); expect(init?.headers).toBeDefined(); return Response.json({ id_token: returnedToken });
      });
      const flow = await invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/start', { clientNonce: secureToken(), providerId: p.id, redirectUri: 'https://product.example/auth/complete', codeChallenge: Buffer.from(tokenDigest(verifier), 'hex').toString('base64url'), purpose: 'login' }) as P.OIDCFlow;
      const authURL = new URL(flow.authorizationUrl); expectedNonce = authURL.searchParams.get('nonce')!; backendChallenge = authURL.searchParams.get('code_challenge')!; expect(backendChallenge).not.toBe(Buffer.from(tokenDigest(verifier), 'hex').toString('base64url'));
      returnedToken = jwt({ iss: p.issuer, sub: 'owner-subject', aud: p.clientId, nonce: expectedNonce, email: 'owner@example.com', email_verified: true, exp: f.services.now() / 1000 + 300, iat: f.services.now() / 1000 });
      await expect(invokeRoute(routes, f.services, 'GET', '/v1/auth/oidc/callback/:providerId', undefined, { params: { providerId: p.id }, query: `state=${secureToken()}&code=authcode` })).rejects.toBeInstanceOf(ApiError); expect(calls).toBe(0);
      const redirect = await invokeRoute(routes, f.services, 'GET', '/v1/auth/oidc/callback/:providerId', undefined, { params: { providerId: p.id }, query: `state=${authURL.searchParams.get('state')}&code=authcode` }) as P.RedirectResponse;
      expect(redirect.status).toBe(302); expect(redirect.location).not.toContain('token='); const completeURL = new URL(redirect.location); const body = { clientNonce: secureToken(), flowId: flow.id, completionCode: completeURL.searchParams.get('completionCode')!, codeVerifier: verifier };
      await expect(invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/complete', { ...body, codeVerifier: secureToken() })).rejects.toBeInstanceOf(ApiError);
      await expect(invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/complete', body)).rejects.toBeInstanceOf(ApiError); // Existing email is never an account merge.
      expect(f.services.store.list('identityLinks')).toHaveLength(0);
      await expect(invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/complete', body)).rejects.toBeInstanceOf(ApiError);
    } finally { f.close(); }
  });
  test('invited verified subject logs in, fresh reauth is user-bound and arbitrary group roles are ignored', async () => {
    const f = identityFixture(); try {
      const p = registeredProvider(f.services); const routes = createIdentityRoutes(f.services);
      f.services.store.put('invites', f.services.resource('invite', { email: 'invited@example.com', role: 'member' as const, expiresAtMs: f.services.now() + 86400000, status: 'pending' as const }));
      f.services.config.operator.oidcGroupMappings = [{ providerId: p.id, externalId: 'approved', directoryGroupId: 'configured-group', name: 'Configured group' }];
      let currentNonce = '';
      f.services.http = (async (input: string | URL | Request) => {
        const url = String(input);
        if (url.endsWith('openid-configuration')) return Response.json(discovery);
        if (url.endsWith('/jwks')) return Response.json({ keys: [jwk] });
        return Response.json({ id_token: jwt({ iss: p.issuer, sub: 'invited-subject', aud: p.clientId, nonce: currentNonce, email: 'invited@example.com', email_verified: true, exp: f.services.now() / 1000 + 300, iat: f.services.now() / 1000, auth_time: f.services.now() / 1000, groups: ['approved', 'owner', 'admin'] }) });
      });
      let principal: Principal | null = null;
      for (const purpose of ['login', 'reauth'] as const) {
        const verifier = secureToken();
        const flow = await invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/start', { clientNonce: secureToken(), providerId: p.id, redirectUri: 'lemonbot://auth/complete', purpose, codeChallenge: Buffer.from(tokenDigest(verifier), 'hex').toString('base64url') }, { principal }) as P.OIDCFlow;
        const authorization = new URL(flow.authorizationUrl); currentNonce = authorization.searchParams.get('nonce')!;
        if (purpose === 'reauth') expect(authorization.searchParams.get('prompt')).toBe('login');
        const callback = await invokeRoute(routes, f.services, 'GET', '/v1/auth/oidc/callback/:providerId', undefined, { params: { providerId: p.id }, query: `state=${authorization.searchParams.get('state')}&code=code` }) as P.RedirectResponse;
        const redirect = new URL(callback.location);
        const result = await invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/complete', { clientNonce: secureToken(), flowId: flow.id, completionCode: redirect.searchParams.get('completionCode'), codeVerifier: verifier }, { principal }) as P.AuthResult | P.ReauthResult;
        if ('token' in result) {
          expect(result.member.role).toBe('member'); expect(result.user.email).toBe('invited@example.com');
          expect(f.services.store.get<P.DirectoryGroup>('directoryGroups', 'configured-group')?.memberUserIds).toEqual([result.user.id]);
          expect(f.services.store.list<P.DirectoryGroup>('directoryGroups')).toHaveLength(1);
          principal = { ...f.principal, id: result.user.id, userId: result.user.id, role: 'member', sessionId: result.session.id };
        } else {
          expect(result.expiresAtMs).toBe(f.services.now() + 300000);
          expect(() => f.services.auth.consumeReauth(f.principal.userId, result.reauthToken)).toThrow();
          f.services.auth.consumeReauth(principal!.userId, result.reauthToken);
        }
      }
      f.services.store.put('oidcProviders', f.services.update(p, { enabled: false }));
      expect(createIdentityServices(f.services).requireSSO(principal!.userId)).toBe(true);
    } finally { f.close(); }
  });
  test('discovery and JWKS endpoints cannot escape the registered issuer origin', async () => {
    const f = identityFixture(); try {
      const p = registeredProvider(f.services); const routes = createIdentityRoutes(f.services);
      f.services.http = (async () => Response.json({ ...discovery, jwks_uri: 'https://evil.example/keys' }));
      await expect(invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/start', { clientNonce: secureToken(), providerId: p.id, redirectUri: 'https://product.example/auth', purpose: 'login', codeChallenge: secureToken() })).rejects.toBeInstanceOf(ApiError);
      expect(f.services.store.list('oidcFlows')).toHaveLength(0);
    } finally { f.close(); }
  });
  test('product deprovision is immediate while an uncertain external end-session is reported separately', async () => {
    const f = identityFixture(); try {
      const p = registeredProvider(f.services); f.services.store.put('oidcProviders', { ...p, endSessionEndpoint: 'https://idp.example/logout' });
      const user = createProvisionedUser(f.services, 'departing@example.com', 'Departing'); const auth = await f.services.auth.session(user.id);
      f.services.store.put('oidcProviderSessions', { id: auth.session.id, userId: user.id, providerId: p.id, encryptedIDToken: f.services.encrypt('identity-token-hint') });
      f.services.http = (async () => { throw new Error('Provider timeout after possible logout.'); });
      await createIdentityServices(f.services).deprovisionUser(user.id);
      expect(f.services.auth.member(user.id).enabled).toBe(false); expect(f.revoked).toContain(user.id); expect(f.services.store.list('oidcProviderSessions')).toHaveLength(0);
      const record = f.services.store.list<P.AuditRecord>('audit').find(value => value.action === 'identity.provider_end_session');
      expect(record?.outcome).toBe('outcome_unknown'); expect(record?.metadata.state).toBe('outcome_unknown');
      expect(JSON.stringify(record)).not.toContain('identity-token-hint');
    } finally { f.close(); }
  });
  test('explicit link requires own session and one-use reauth; required SSO cannot be unlinked', async () => {
    const f = identityFixture(); try { const p = registeredProvider(f.services); const verifier = secureToken(); const code = secureToken(); const flowId = 'link-flow';
      f.services.store.put('oidcFlows', { id: flowId, providerId: p.id, providerRevision: p.revision, purpose: 'link', userId: f.principal.userId, sessionId: f.principal.sessionId, deviceId: null, expiresAtMs: f.services.now() + 600000, status: 'verified', codeChallenge: Buffer.from(tokenDigest(verifier), 'hex').toString('base64url'), completionDigest: tokenDigest(code), claims: { issuer: p.issuer, subject: 'owner-subject', email: 'owner@example.com', groups: [], displayName: 'Owner', authTime: null } });
      const reauth = f.services.auth.issueReauth(f.principal.userId); const routes = createIdentityRoutes(f.services);
      await expect(invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/complete', { clientNonce: secureToken(), flowId, completionCode: code, codeVerifier: verifier }, { principal: f.principal })).rejects.toBeInstanceOf(ApiError);
      const link = await invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/link', { clientNonce: secureToken(), flowId, completionCode: code, codeVerifier: verifier, reauthToken: reauth.reauthToken }, { principal: f.principal }) as P.IdentityLink;
      expect(link.userId).toBe(f.principal.userId); expect(JSON.stringify(link)).not.toContain('reauthToken'); expect(createIdentityServices(f.services).requireSSO(link.userId)).toBe(true);
      expect(() => f.services.auth.consumeReauth(link.userId, reauth.reauthToken)).toThrow();
      f.services.store.put('credentials', { id: link.userId, passwordHash: 'local-hash' });
      await expect(invokeRoute(routes, f.services, 'DELETE', '/v1/auth/identities/:id', { clientNonce: secureToken(), revision: link.revision, reauthToken: f.services.auth.issueReauth(link.userId).reauthToken }, { principal: f.principal, params: { id: link.id } })).rejects.toBeInstanceOf(ApiError);
      f.services.config.operator.breakGlassOwnerUserId = link.userId; expect(createIdentityServices(f.services).requireSSO(link.userId)).toBe(false);
    } finally { f.close(); }
  });
  test('unlink revokes only the linked provider sessions and retains local work authority', async () => {
    const f = identityFixture();
    try {
      const p = { ...registeredProvider(f.services), requireSSO: false };
      f.services.store.put('oidcProviders', p);
      const userId = f.principal.userId;
      f.services.store.put('credentials', { id: userId, passwordHash: 'local-hash' });
      const link = f.services.resource('identity', { userId, providerId: p.id, issuer: p.issuer, subject: 'subject', lastUsedAtMs: null });
      f.services.store.put('identityLinks', link);
      for (const id of ['provider-session', 'local-session']) f.services.store.put('authSessions', { ...f.services.resource('session', { userId, deviceId: null, expiresAtMs: f.services.now() + 600000, lastSeenAtMs: f.services.now(), current: false }), id });
      f.services.store.put('oidcProviderSessions', { id: 'provider-session', userId, providerId: p.id, encryptedIDToken: f.services.encrypt('private-id-token') });
      const revokedSessions: string[] = [];
      f.services.invoke = async <T>(_principal: Principal, method: string, path: string): Promise<T> => {
        expect(method).toBe('DELETE');
        const id = decodeURIComponent(path.split('/').at(-1)!);
        const session = f.services.store.require<P.AuthSession>('authSessions', id);
        expect(session.userId).toBe(userId);
        revokedSessions.push(id); f.services.store.remove('authSessions', id);
        const response: unknown = { id, deleted: true }; return response as T;
      };
      await invokeRoute(createIdentityRoutes(f.services), f.services, 'DELETE', '/v1/auth/identities/:id', { clientNonce: secureToken(), revision: link.revision, reauthToken: f.services.auth.issueReauth(userId).reauthToken }, { principal: f.principal, params: { id: link.id } });
      expect(revokedSessions).toEqual(['provider-session']);
      expect(f.services.store.get('authSessions', 'local-session')).not.toBeNull();
      expect(f.revoked).toEqual([]); expect(f.cancelled).toEqual([]);
      expect(f.services.auth.member(userId).enabled).toBe(true);
      expect(f.services.store.list('oidcProviderSessions')).toEqual([]);
      expect(JSON.stringify(f.services.store.list('audit'))).not.toContain('private-id-token');
    } finally { f.close(); }
  });
  test('expired flow, public privacy and final-owner deprovision protection', async () => {
    const f = identityFixture(); try { const p = registeredProvider(f.services); const routes = createIdentityRoutes(f.services); const result = await invokeRoute(routes, f.services, 'GET', '/v1/auth/oidc/providers'); expect(Object.keys((result as object[])[0]!)).toEqual(['id', 'name', 'enabled', 'requireSSO']);
      await expect(createIdentityServices(f.services).deprovisionUser(f.principal.userId)).rejects.toBeInstanceOf(ApiError); expect(f.revoked).toHaveLength(0);
      f.services.store.put('oidcFlows', { id: 'expired', providerId: p.id, expiresAtMs: f.services.now() });
      await expect(invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/complete', { clientNonce: secureToken(), flowId: 'expired', completionCode: secureToken(), codeVerifier: secureToken() })).rejects.toBeInstanceOf(ApiError);
      await expect(invokeRoute(routes, f.services, 'POST', '/v1/auth/oidc/start', { clientNonce: secureToken(), providerId: p.id, redirectUri: 'https://evil.example', codeChallenge: secureToken(), purpose: 'login' })).rejects.toBeInstanceOf(ApiError);
    } finally { f.close(); }
  });
});
