import { constants, createPublicKey, verify, type JsonWebKey } from 'node:crypto';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { fail } from '../core/errors';
import { equalSecret, secureToken, tokenDigest } from './tokens';

const nonce = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
const id = z.string().min(1).max(256);
const createSchema = z.strictObject({ clientNonce: nonce, name: z.string().trim().min(1).max(120), issuer: z.url(), clientId: id, clientSecretRef: id, scopes: z.array(id).min(1).max(32), allowedEmailDomains: z.array(z.string().regex(/^[a-zA-Z0-9.-]+$/)).max(100), groupClaim: id.optional(), requireSSO: z.boolean() });
const updateSchema = z.strictObject({ clientNonce: nonce, revision: z.number().int().positive(), enabled: z.boolean().optional(), requireSSO: z.boolean().optional(), scopes: z.array(id).min(1).max(32).optional(), allowedEmailDomains: z.array(z.string().regex(/^[a-zA-Z0-9.-]+$/)).max(100).optional() });
const startSchema = z.strictObject({ clientNonce: nonce, providerId: id, redirectUri: z.string().max(2048), codeChallenge: z.string().regex(/^[A-Za-z0-9_-]{43}$/), purpose: z.enum(['login', 'reauth', 'link']), deviceId: id.optional() });
const completeFields = { clientNonce: nonce, flowId: id, completionCode: z.string().regex(/^[A-Za-z0-9_-]{43}$/), codeVerifier: z.string().regex(/^[A-Za-z0-9._~-]{43,128}$/), deviceId: id.optional() };
const completeSchema = z.strictObject(completeFields);
const linkSchema = z.strictObject({ ...completeFields, reauthToken: id });
const unlinkSchema = z.strictObject({ clientNonce: nonce, revision: z.number().int().positive(), reauthToken: id });
const deleteSchema = z.strictObject({ clientNonce: nonce, revision: z.number().int().positive() });
const discoverySchema = z.object({ issuer: z.string(), authorization_endpoint: z.string(), token_endpoint: z.string(), jwks_uri: z.string(), end_session_endpoint: z.string().optional(), code_challenge_methods_supported: z.array(z.string()).optional(), id_token_signing_alg_values_supported: z.array(z.string()).optional(), token_endpoint_auth_methods_supported: z.array(z.string()).optional() });
type Discovery = z.infer<typeof discoverySchema>;
interface Flow {
  id: string; providerId: string; providerRevision: number; issuer: string; clientId: string; discovery: Discovery; redirectUri: string; codeChallenge: string; purpose: P.OIDCStart['purpose']; userId: string | null; sessionId: string | null; deviceId: string | null; createdAtMs: number; expiresAtMs: number; stateDigest: string; nonce: string; encryptedVerifier: string; status: 'pending' | 'exchanging' | 'verified' | 'consumed'; completionDigest: string | null; claims: VerifiedClaims | null; encryptedIDToken: string | null;
}
export interface VerifiedClaims { issuer: string; subject: string; email: string; displayName: string; groups: string[]; authTime: number | null }
interface ProviderSession { id: string; userId: string; providerId: string; encryptedIDToken: string }
interface ManagedIdentity { id: string; requireSSO: boolean; providerIds: string[] }

function parse<T>(schema: z.ZodType<T>, body: unknown): T {
  const result = schema.safeParse(body); if (!result.success) fail('invalid_request', 'Invalid identity request.'); return result.data;
}
function provider(services: BackendServices, providerId: string, enabled = true): P.OIDCProvider {
  const result = services.store.get<P.OIDCProvider>('oidcProviders', providerId);
  if (!result) fail('not_found', 'Identity provider not found.');
  if (enabled && !result.enabled) fail('policy_denied', 'Identity provider is disabled.');
  return result;
}
function pinnedUrl(value: string, issuer: string): URL {
  let url: URL; let origin: URL;
  try { url = new URL(value); origin = new URL(issuer); } catch { fail('capability_unavailable', 'Identity provider endpoint is invalid.'); }
  if (url.protocol !== 'https:' || url.origin !== origin.origin || url.username || url.password || url.hash) fail('capability_unavailable', 'Identity endpoints must use the approved HTTPS issuer origin.');
  return url;
}
async function providerFetch(url: URL, init?: RequestInit): Promise<unknown> {
  let response: Response;
  try { response = await fetch(url, { ...init, redirect: 'error', signal: AbortSignal.timeout(10000) }); } catch { fail('upstream_unavailable', 'Identity provider could not be reached.'); }
  if (!response.ok) fail('upstream_unavailable', 'Identity provider rejected the request.');
  if (Number(response.headers.get('content-length') ?? 0) > 1048576) fail('upstream_unavailable', 'Identity provider response exceeds the allowed size.');
  const reader = response.body?.getReader(); if (!reader) fail('upstream_unavailable', 'Identity provider returned no response.');
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    for (;;) { const result = await reader.read(); if (result.done) break; size += result.value.length; if (size > 1048576) { await reader.cancel(); fail('upstream_unavailable', 'Identity provider response exceeds the allowed size.'); } chunks.push(result.value); }
  } catch { fail('upstream_unavailable', 'Identity provider response was interrupted or exceeded its size bound.'); }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown; } catch { fail('upstream_unavailable', 'Identity provider returned malformed JSON.'); }
}
async function discover(p: P.OIDCProvider): Promise<Discovery> {
  const endpoint = pinnedUrl(`${p.issuer.replace(/\/$/, '')}/.well-known/openid-configuration`, p.issuer);
  const parsed = discoverySchema.safeParse(await providerFetch(endpoint));
  if (!parsed.success || parsed.data.issuer !== p.issuer) fail('capability_unavailable', 'Discovery issuer does not match the registered issuer.');
  const d = parsed.data;
  for (const endpoint of [d.authorization_endpoint, d.token_endpoint, d.jwks_uri, ...(d.end_session_endpoint ? [d.end_session_endpoint] : [])]) pinnedUrl(endpoint, p.issuer);
  if (d.code_challenge_methods_supported && !d.code_challenge_methods_supported.includes('S256')) fail('capability_unavailable', 'Identity provider must support S256 PKCE.');
  return d;
}

/** Verify the JWT, never trust a decoded token or email without its verified claim. */
export async function verifyOIDCToken(token: string, p: P.OIDCProvider, d: Discovery, expectedNonce: string, now: number, flowStarted: number, purpose: P.OIDCStart['purpose']): Promise<VerifiedClaims> {
  if (token.length > 131072) fail('unauthenticated', 'Invalid identity token.');
  const parts = token.split('.'); if (parts.length !== 3 || parts.some(part => !/^[A-Za-z0-9_-]+$/.test(part))) fail('unauthenticated', 'Invalid identity token.');
  let header: Record<string, unknown>; let claims: Record<string, unknown>;
  try { header = JSON.parse(Buffer.from(parts[0]!, 'base64url').toString()) as Record<string, unknown>; claims = JSON.parse(Buffer.from(parts[1]!, 'base64url').toString()) as Record<string, unknown>; } catch { fail('unauthenticated', 'Invalid identity token.'); }
  if (!header || typeof header !== 'object' || !claims || typeof claims !== 'object' || typeof header.alg !== 'string' || !['RS256', 'PS256', 'ES256', 'EdDSA'].includes(header.alg) || header.crit !== undefined || header.jku !== undefined || header.jwk !== undefined || header.x5u !== undefined) fail('unauthenticated', 'Unsupported identity token signature.');
  if (d.id_token_signing_alg_values_supported && !d.id_token_signing_alg_values_supported.includes(header.alg)) fail('unauthenticated', 'Unexpected identity token signature.');
  const jwks = z.object({ keys: z.array(z.record(z.string(), z.unknown())).max(100) }).safeParse(await providerFetch(pinnedUrl(d.jwks_uri, p.issuer)));
  if (!jwks.success) fail('upstream_unavailable', 'Identity signing keys are invalid.');
  const kty = header.alg === 'ES256' ? 'EC' : header.alg === 'EdDSA' ? 'OKP' : 'RSA';
  const keys = jwks.data.keys.filter(key => (header.kid === undefined || key.kid === header.kid) && key.kty === kty && (key.use === undefined || key.use === 'sig') && (key.alg === undefined || key.alg === header.alg) && (key.key_ops === undefined || Array.isArray(key.key_ops) && key.key_ops.includes('verify')) && (header.alg !== 'ES256' || key.crv === 'P-256') && (header.alg !== 'EdDSA' || key.crv === 'Ed25519'));
  if (keys.length !== 1) fail('unauthenticated', 'Identity signing key could not be selected.');
  let valid = false;
  try {
    const key = createPublicKey({ key: keys[0] as JsonWebKey, format: 'jwk' });
    if (kty === 'RSA' && (key.asymmetricKeyDetails?.modulusLength ?? 0) < 2048) fail('unauthenticated', 'Weak identity signing key.');
    valid = verify(header.alg === 'EdDSA' ? null : 'sha256', Buffer.from(`${parts[0]}.${parts[1]}`), { key, ...(header.alg === 'PS256' ? { padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 } : {}), ...(header.alg === 'ES256' ? { dsaEncoding: 'ieee-p1363' as const } : {}) }, Buffer.from(parts[2]!, 'base64url'));
  } catch { fail('unauthenticated', 'Invalid identity signature.'); }
  const audience = typeof claims.aud === 'string' ? [claims.aud] : Array.isArray(claims.aud) && claims.aud.every(value => typeof value === 'string') ? claims.aud : [];
  const seconds = now / 1000;
  if (!valid || claims.iss !== p.issuer || !audience.includes(p.clientId) || (audience.length > 1 && claims.azp !== p.clientId) || (claims.azp !== undefined && claims.azp !== p.clientId) || typeof claims.exp !== 'number' || !Number.isFinite(claims.exp) || claims.exp <= seconds || (claims.nbf !== undefined && (typeof claims.nbf !== 'number' || !Number.isFinite(claims.nbf) || claims.nbf > seconds)) || typeof claims.iat !== 'number' || !Number.isFinite(claims.iat) || claims.iat > seconds || typeof claims.nonce !== 'string' || !equalSecret(claims.nonce, expectedNonce) || typeof claims.sub !== 'string' || !claims.sub || claims.sub.length > 256 || claims.email_verified !== true || typeof claims.email !== 'string' || !z.email().safeParse(claims.email).success) fail('unauthenticated', 'Identity token verification failed.');
  if ((purpose === 'reauth') && (typeof claims.auth_time !== 'number' || !Number.isFinite(claims.auth_time) || claims.auth_time < flowStarted / 1000 - 60 || claims.auth_time > seconds)) fail('unauthenticated', 'Fresh provider authentication is required.');
  const email = claims.email.trim().toLowerCase();
  if (p.allowedEmailDomains.length && !p.allowedEmailDomains.includes(email.split('@')[1]!)) fail('policy_denied', 'Identity email domain is not allowed.');
  const groupValue = p.groupClaim ? claims[p.groupClaim] : undefined;
  return { issuer: p.issuer, subject: claims.sub, email, displayName: typeof claims.name === 'string' && claims.name.trim() ? claims.name.slice(0, 120) : email, groups: Array.isArray(groupValue) ? groupValue.filter((value): value is string => typeof value === 'string').slice(0, 1000) : [], authTime: typeof claims.auth_time === 'number' ? claims.auth_time : null };
}
function checkedFlow(services: BackendServices, flowId: string): Flow {
  const flow = services.store.get<Flow>('oidcFlows', flowId); if (!flow) fail('unauthenticated', 'Invalid identity flow.');
  if (flow.expiresAtMs <= services.now()) fail('expired', 'Identity flow expired.');
  const p = provider(services, flow.providerId); if (p.revision !== flow.providerRevision) fail('expired', 'Identity provider changed; start a new flow.');
  return flow;
}
function completion(services: BackendServices, body: P.OIDCComplete, user: Principal | null, purpose?: 'link'): Flow & { claims: VerifiedClaims } {
  return services.store.transaction(() => {
    const flow = checkedFlow(services, body.flowId);
    if (flow.status !== 'verified' || !flow.claims || !flow.completionDigest || !equalSecret(flow.completionDigest, tokenDigest(body.completionCode)) || !equalSecret(flow.codeChallenge, Buffer.from(tokenDigest(body.codeVerifier), 'hex').toString('base64url'))) fail('unauthenticated', 'Invalid identity completion.');
    if ((purpose === 'link') !== (flow.purpose === 'link')) fail('policy_denied', 'Wrong endpoint for this identity flow.');
    if (flow.userId && (!user || user.kind !== 'user' || user.userId !== flow.userId || user.sessionId !== flow.sessionId)) fail('unauthenticated', 'Identity flow belongs to another session.');
    if ((body.deviceId ?? null) !== flow.deviceId) fail('invalid_request', 'Device does not match the identity flow.');
    services.store.remove('oidcFlows', flow.id);
    return { ...flow, claims: flow.claims };
  });
}
function linked(services: BackendServices, claims: VerifiedClaims): P.IdentityLink | undefined {
  return services.store.list<P.IdentityLink>('identityLinks').find(link => link.issuer === claims.issuer && link.subject === claims.subject);
}
function reviewedSubject(services: BackendServices, providerId: string, subject: string): string | null {
  const mappings = z.array(z.strictObject({ providerId: id, subject: id, userId: id })).safeParse(services.config.operatorExtras?.oidcSubjectMappings ?? []);
  if (!mappings.success) fail('capability_unavailable', 'Operator OIDC subject mappings are invalid.');
  const matching = mappings.data.filter(mapping => mapping.providerId === providerId && mapping.subject === subject);
  if (matching.length > 1) fail('capability_unavailable', 'OIDC subject mapping is ambiguous.');
  const userId = matching[0]?.userId;
  if (!userId) return null;
  if (!services.store.get<P.SCIMUser>('scimUsers', userId)?.active || !services.auth.member(userId).enabled) fail('policy_denied', 'Mapped SCIM membership is not active.');
  return userId;
}
function synchronize(services: BackendServices, userId: string, p: P.OIDCProvider, claims: VerifiedClaims): void {
  const configured = z.array(z.strictObject({ providerId: id, externalId: id, directoryGroupId: id, name: z.string().min(1).max(120).optional() })).safeParse(services.config.operatorExtras?.oidcGroupMappings ?? []);
  if (!configured.success) fail('capability_unavailable', 'Operator OIDC group mappings are invalid.');
  for (const mapping of configured.data.filter(value => value.providerId === p.id)) {
    let group = services.store.get<P.DirectoryGroup>('directoryGroups', mapping.directoryGroupId);
    if (!group) {
      if (!mapping.name) fail('capability_unavailable', 'A new OIDC directory group requires an operator-configured name.');
      group = { ...services.resource('directory_group', { name: mapping.name, externalId: mapping.externalId, source: 'oidc' as const, memberUserIds: [] as string[] }), id: mapping.directoryGroupId };
      services.store.put('directoryGroups', group);
      services.events.emit('directory_group.upserted', group, { admin: true });
      const policy = services.resource('group_policy', { directoryGroupId: group.id, productAccess: true, defaultBotIds: [] as string[], capabilityModes: {}, requiredRuleIds: [] as string[], localExecutionCeiling: 'ask' as const, allowEgress: false, allowSudo: false, networkPolicyId: null, reviewExempt: false });
      services.store.put('groupPolicies', policy); services.events.emit('group_policy.upserted', policy, { admin: true });
    }
    if (group.source !== 'oidc' || group.externalId !== mapping.externalId) fail('capability_unavailable', 'OIDC mapping cannot overwrite local or SCIM directory provenance.');
    const desired = claims.groups.includes(mapping.externalId);
    if (desired === group.memberUserIds.includes(userId)) continue;
    const updated = services.update(group, { memberUserIds: desired ? [...group.memberUserIds, userId] : group.memberUserIds.filter(member => member !== userId) });
    services.store.put('directoryGroups', updated); services.events.emit('directory_group.upserted', updated, { admin: true });
  }
  const managed = services.store.get<ManagedIdentity>('managedIdentities', userId);
  services.store.put('managedIdentities', { id: userId, requireSSO: (managed?.requireSSO ?? false) || p.requireSSO, providerIds: [...new Set([...(managed?.providerIds ?? []), p.id])] });
}
export function createProvisionedUser(services: BackendServices, email: string, displayName: string, role: 'member' | 'admin' = 'member'): P.User {
  const user = services.resource('user', { email, displayName, avatarAttachmentId: null, preferences: { appearance: 'system' as const, language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false }, notifications: { enabled: true, sound: true, previews: true, completed: true, needsInput: true } });
  services.store.put('users', user);
  services.store.put('members', services.resource('member', { userId: user.id, displayName, email, role, enabled: true }));
  return user;
}
function resolveLogin(services: BackendServices, p: P.OIDCProvider, claims: VerifiedClaims): P.IdentityLink {
  const existing = linked(services, claims); if (existing) return existing;
  const mappedUserId = reviewedSubject(services, p.id, claims.subject);
  const scim = mappedUserId ? services.store.get<P.SCIMUser>('scimUsers', mappedUserId)! : services.store.list<P.SCIMUser>('scimUsers').find(user => user.active && user.userName === claims.email);
  let user: P.User;
  if (scim) {
    user = services.store.require<P.User>('users', scim.id);
    if (mappedUserId !== scim.id) {
      const groups = services.store.list<P.DirectoryGroup>('directoryGroups', group => group.source === 'scim' && group.memberUserIds.includes(scim.id));
      if (!groups.some(group => services.store.list<P.GroupPolicy>('groupPolicies').some(policy => policy.directoryGroupId === group.id && policy.productAccess))) fail('policy_denied', 'SCIM identity requires a reviewed provider mapping or directory access grant.');
    }
  } else {
    if (services.store.list<P.User>('users').some(user => user.email === claims.email)) fail('policy_denied', 'Existing accounts must explicitly link this identity.');
    const invite = services.store.list<P.MemberInvite>('invites').find(invite => invite.email === claims.email && invite.status === 'pending' && invite.expiresAtMs > services.now());
    if (!invite) fail('policy_denied', 'A valid invitation or approved directory identity is required.');
    user = createProvisionedUser(services, claims.email, claims.displayName, invite.role);
    services.store.put('invites', services.update(invite, { status: 'accepted' }));
  }
  const link = services.resource('identity', { userId: user.id, providerId: p.id, issuer: p.issuer, subject: claims.subject, lastUsedAtMs: services.now() }); services.store.put('identityLinks', link); return link;
}
async function endProviderSessions(services: BackendServices, userId: string, providerId?: string): Promise<void> {
  for (const session of services.store.list<ProviderSession>('oidcProviderSessions', value => value.userId === userId && (!providerId || value.providerId === providerId))) {
    services.store.remove('oidcProviderSessions', session.id);
    const p = services.store.get<P.OIDCProvider>('oidcProviders', session.providerId);
    let outcome: 'unsupported' | 'succeeded' | 'failed' | 'outcome_unknown' = 'unsupported';
    if (p?.endSessionEndpoint) {
      try {
        const url = pinnedUrl(p.endSessionEndpoint, p.issuer); url.searchParams.set('id_token_hint', services.decrypt<string>(session.encryptedIDToken)); url.searchParams.set('client_id', p.clientId);
        const result = await fetch(url, { redirect: 'manual', signal: AbortSignal.timeout(10000) }); await result.body?.cancel();
        outcome = result.ok ? 'succeeded' : result.status >= 400 && result.status < 500 ? 'failed' : 'outcome_unknown';
      } catch { outcome = 'outcome_unknown'; }
    }
    services.audit(null, 'identity.provider_end_session', userId, outcome === 'unsupported' ? 'succeeded' : outcome, { providerId: session.providerId, status: outcome });
  }
}
/** Core must invoke requireSSO before password login/reauth and this hook on deprovision. */
export function createIdentityServices(services: BackendServices) {
  return {
    requireSSO(userId: string): boolean {
      const member = services.store.list<P.Member>('members').find(value => value.userId === userId);
      if (member?.role === 'owner' && services.config.operator.breakGlassOwnerUserId === userId) return false;
      const managed = services.store.get<ManagedIdentity>('managedIdentities', userId);
      const associated = [...(managed?.providerIds ?? []), ...services.store.list<P.IdentityLink>('identityLinks', value => value.userId === userId).map(link => link.providerId)];
      const directoryRequired = services.store.metadata<boolean>(`scimManaged:${userId}`) === true && services.store.list<P.OIDCProvider>('oidcProviders').some(value => value.requireSSO);
      return directoryRequired || associated.some(providerId => services.store.get<P.OIDCProvider>('oidcProviders', providerId)?.requireSSO ?? managed?.requireSSO ?? false);
    },
    consumeReauth: services.auth.consumeReauth.bind(services.auth),
    async deprovisionUser(userId: string): Promise<void> {
      services.store.transaction(() => {
        const member = services.store.list<P.Member>('members').find(value => value.userId === userId);
        if (member?.role === 'owner' && member.enabled && services.store.list<P.Member>('members', value => value.enabled && value.role === 'owner').length <= 1) fail('conflict', 'The final owner cannot be deprovisioned.');
        if (member?.enabled) services.store.put('members', services.update(member, { enabled: false }));
      });
      await services.auth.revokeUser(userId); services.gates.cancelUser(userId); await endProviderSessions(services, userId);
    },
    endProviderSessions: (userId: string) => endProviderSessions(services, userId),
    async reconcile(): Promise<void> {
      for (const flow of services.store.list<Flow>('oidcFlows')) if (flow.expiresAtMs <= services.now()) services.store.remove('oidcFlows', flow.id);
    },
  };
}
export function createIdentityRoutes(services: BackendServices): Route[] {
  const identity = createIdentityServices(services);
  return [
    { method: 'GET', path: '/v1/auth/oidc/providers', auth: 'public', handler: () => services.store.list<P.OIDCProvider>('oidcProviders').map(({ id, name, enabled, requireSSO }) => ({ id, name, enabled, requireSSO })) },
    { method: 'GET', path: '/v1/admin/oidc/providers', auth: 'owner', handler: context => services.page(context, services.store.list<P.OIDCProvider>('oidcProviders')) },
    { method: 'POST', path: '/v1/admin/oidc/providers', auth: 'owner', status: 201, handler: async context => {
      const body = parse(createSchema, context.body); pinnedUrl(body.issuer, body.issuer);
      if (!services.config.operator.serverSecrets[body.clientSecretRef]) fail('capability_unavailable', 'Register the confidential client secret in operator serverSecrets.');
      if (!body.scopes.includes('openid') || !body.scopes.includes('email')) fail('invalid_request', 'OIDC scopes must include openid and email.');
      if (services.store.list<P.OIDCProvider>('oidcProviders').some(value => value.issuer === body.issuer && value.clientId === body.clientId)) fail('conflict', 'Identity provider already exists.');
      const p = services.resource('oidc_provider', { name: body.name, issuer: body.issuer, clientId: body.clientId, clientSecretRef: body.clientSecretRef, scopes: body.scopes, allowedEmailDomains: body.allowedEmailDomains.map(value => value.toLowerCase()), groupClaim: body.groupClaim ?? null, enabled: true, requireSSO: body.requireSSO, endSessionEndpoint: null as string | null });
      const d = await discover(p); await services.secret(p.clientSecretRef); p.endSessionEndpoint = d.end_session_endpoint ?? null;
      services.store.transaction(() => { if (services.store.list<P.OIDCProvider>('oidcProviders').some(value => value.issuer === p.issuer && value.clientId === p.clientId)) fail('conflict', 'Identity provider already exists.'); services.store.put('oidcProviders', p); services.audit(context.user, 'identity.provider_create', p.id, 'succeeded', undefined, context.requestId); }); return p;
    } },
    { method: 'PATCH', path: '/v1/admin/oidc/providers/:id', auth: 'owner', handler: context => services.store.transaction(() => {
      const body = parse(updateSchema, context.body); const p = provider(services, context.params.id!, false); services.mutations.checkRevision(p, body.revision);
      if (body.scopes && (!body.scopes.includes('openid') || !body.scopes.includes('email'))) fail('invalid_request', 'OIDC scopes must include openid and email.');
      const { clientNonce: _, revision: __, ...changes } = body;
      const updated = services.update(p, { ...changes, ...(body.allowedEmailDomains ? { allowedEmailDomains: body.allowedEmailDomains.map(value => value.toLowerCase()) } : {}) }); services.store.put('oidcProviders', updated); services.audit(context.user, 'identity.provider_update', p.id, 'succeeded', undefined, context.requestId); return updated;
    }) },
    { method: 'DELETE', path: '/v1/admin/oidc/providers/:id', auth: 'owner', handler: context => services.store.transaction(() => {
      const body = parse(deleteSchema, context.body); const p = provider(services, context.params.id!, false); services.mutations.checkRevision(p, body.revision);
      if (services.store.list<P.IdentityLink>('identityLinks', value => value.providerId === p.id).length) fail('conflict', 'Unlink identities before removing their provider.');
      services.store.remove('oidcProviders', p.id); services.audit(context.user, 'identity.provider_delete', p.id, 'succeeded', undefined, context.requestId); return { id: p.id, deleted: true };
    }) },
    { method: 'POST', path: '/v1/auth/oidc/start', auth: 'optional', mutation: true, handler: async context => {
      const body = parse(startSchema, context.body); const p = provider(services, body.providerId);
      const user = context.user; if (body.purpose !== 'login' && (!user || user.kind !== 'user')) fail('unauthenticated', 'Sign in before reauthenticating or linking.');
      let redirect: URL; try { redirect = new URL(body.redirectUri); } catch { fail('invalid_request', 'Invalid client redirect.'); }
      const web = redirect.origin === new URL(services.config.publicUrl).origin && ['https:', 'http:'].includes(redirect.protocol) && !redirect.username && !redirect.password && !redirect.hash;
      const native = body.redirectUri === 'lemonbot://auth/complete' && services.config.operator.oauthRedirectUris.includes(body.redirectUri);
      if ((!web && !native) || redirect.searchParams.has('completionCode') || redirect.searchParams.has('flowId')) fail('invalid_request', 'Client redirect is not allowlisted.');
      if (body.deviceId) { const device = services.store.get<P.Device>('devices', body.deviceId); if (!user || !device || device.userId !== user.userId) fail('forbidden', 'Device must belong to the current account.'); }
      const d = await discover(p); const state = secureToken(); const verifier = secureToken();
      const flow: Flow = { id: services.id('oidc_flow'), providerId: p.id, providerRevision: p.revision, issuer: p.issuer, clientId: p.clientId, discovery: d, redirectUri: body.redirectUri, codeChallenge: body.codeChallenge, purpose: body.purpose, userId: body.purpose === 'login' ? null : user!.userId, sessionId: body.purpose === 'login' ? null : user!.sessionId, deviceId: body.deviceId ?? null, createdAtMs: services.now(), expiresAtMs: services.now() + 600000, stateDigest: tokenDigest(state), nonce: secureToken(), encryptedVerifier: services.encrypt(verifier), status: 'pending', completionDigest: null, claims: null, encryptedIDToken: null };
      const url = pinnedUrl(d.authorization_endpoint, p.issuer);
      for (const [key, value] of Object.entries({ client_id: p.clientId, response_type: 'code', redirect_uri: `${services.config.publicUrl.replace(/\/$/, '')}/v1/auth/oidc/callback/${encodeURIComponent(p.id)}`, scope: p.scopes.join(' '), state, nonce: flow.nonce, code_challenge: Buffer.from(tokenDigest(verifier), 'hex').toString('base64url'), code_challenge_method: 'S256' })) url.searchParams.set(key, value);
      if (body.purpose === 'reauth') { url.searchParams.set('prompt', 'login'); url.searchParams.set('max_age', '0'); }
      services.store.put('oidcFlows', flow); return { id: flow.id, authorizationUrl: url.toString(), expiresAtMs: flow.expiresAtMs } satisfies P.OIDCFlow;
    } },
    { method: 'GET', path: '/v1/auth/oidc/callback/:providerId', auth: 'public', mutation: false, handler: async context => {
      const query = parse(z.strictObject({ state: z.string().regex(/^[A-Za-z0-9_-]{43}$/), code: z.string().min(1).max(4096).optional(), error: z.string().max(256).optional() }), Object.fromEntries(context.query));
      const flow = services.store.transaction(() => {
        const found = services.store.list<Flow>('oidcFlows').find(value => value.providerId === context.params.providerId && equalSecret(value.stateDigest, tokenDigest(query.state)));
        if (!found) fail('unauthenticated', 'Invalid identity state.'); const current = checkedFlow(services, found.id);
        if (current.status !== 'pending') fail('unauthenticated', 'Identity callback was already used.'); services.store.put('oidcFlows', { ...current, status: 'exchanging' }); return current;
      });
      if (query.error || !query.code) fail('unauthenticated', 'Provider authentication was not completed.');
      const p = provider(services, flow.providerId); const secret = await services.secret(p.clientSecretRef);
      const form = new URLSearchParams({ grant_type: 'authorization_code', code: query.code, redirect_uri: `${services.config.publicUrl.replace(/\/$/, '')}/v1/auth/oidc/callback/${encodeURIComponent(p.id)}`, code_verifier: services.decrypt<string>(flow.encryptedVerifier) });
      const methods = flow.discovery.token_endpoint_auth_methods_supported ?? ['client_secret_basic']; const headers: Record<string, string> = { 'content-type': 'application/x-www-form-urlencoded' };
      if (methods.includes('client_secret_basic')) headers.authorization = `Basic ${Buffer.from(`${encodeURIComponent(p.clientId)}:${encodeURIComponent(secret)}`).toString('base64')}`;
      else if (methods.includes('client_secret_post')) { form.set('client_id', p.clientId); form.set('client_secret', secret); }
      else fail('capability_unavailable', 'Provider requires an unsupported confidential client authentication method.');
      const tokens = z.object({ id_token: z.string() }).safeParse(await providerFetch(pinnedUrl(flow.discovery.token_endpoint, p.issuer), { method: 'POST', headers, body: form })); if (!tokens.success) fail('unauthenticated', 'Provider did not return an identity token.');
      const claims = await verifyOIDCToken(tokens.data.id_token, p, flow.discovery, flow.nonce, services.now(), flow.createdAtMs, flow.purpose);
      const code = secureToken(); const location = new URL(flow.redirectUri); location.searchParams.set('flowId', flow.id); location.searchParams.set('completionCode', code);
      services.store.transaction(() => { checkedFlow(services, flow.id); services.store.put('oidcFlows', { ...flow, status: 'verified', completionDigest: tokenDigest(code), claims, encryptedVerifier: '', encryptedIDToken: services.encrypt(tokens.data.id_token) }); });
      return { status: 302, location: location.toString() } satisfies P.RedirectResponse;
    } },
    { method: 'POST', path: '/v1/auth/oidc/complete', auth: 'optional', mutation: true, handler: async context => {
      const body = parse(completeSchema, context.body); const flow = completion(services, body, context.user); const p = provider(services, flow.providerId);
      const link = services.store.transaction(() => {
        const existing = linked(services, flow.claims);
        if (flow.purpose === 'reauth' && (!existing || existing.userId !== flow.userId || existing.providerId !== flow.providerId)) fail('unauthenticated', 'Reauthentication must use the current linked identity.');
        const identityLink = existing ?? resolveLogin(services, p, flow.claims); const member = services.auth.member(identityLink.userId); if (!member.enabled) fail('policy_denied', 'Workspace membership is disabled.');
        synchronize(services, identityLink.userId, p, flow.claims); const updated = services.update(identityLink, { lastUsedAtMs: services.now() }); services.store.put('identityLinks', updated); return updated;
      });
      const member = services.auth.member(link.userId); const workspace = services.store.list<P.Workspace>('workspaces')[0];
      if (!workspace) fail('policy_denied', 'Workspace is not configured.');
      await services.integrations.effectivePolicy({ kind: 'user', id: link.userId, userId: link.userId, workspaceId: workspace.id, role: member.role, sessionId: flow.sessionId, deviceId: flow.deviceId, botId: null }).then(policy => { if (!policy.productAccess) fail('policy_denied', 'Directory policy denies product access.'); });
      if (flow.purpose === 'reauth') return services.auth.issueReauth(link.userId);
      const result = await services.auth.session(link.userId, flow.deviceId);
      if (flow.encryptedIDToken) services.store.put('oidcProviderSessions', { id: result.session.id, userId: link.userId, providerId: p.id, encryptedIDToken: flow.encryptedIDToken });
      services.audit(context.user, 'identity.login', link.userId, 'succeeded', { providerId: p.id }, context.requestId); return result;
    } },
    { method: 'GET', path: '/v1/auth/identities', auth: 'member', handler: context => services.page(context, services.store.list<P.IdentityLink>('identityLinks', link => link.userId === context.user!.userId)) },
    { method: 'POST', path: '/v1/auth/oidc/link', auth: 'member', handler: context => services.store.transaction(() => {
      const body = parse(linkSchema, context.body); const flow = completion(services, body, context.user, 'link'); const p = provider(services, flow.providerId); const user = services.auth.user(context.user!.userId);
      if (linked(services, flow.claims)) fail('conflict', 'This identity is already linked.');
      if (user.email !== flow.claims.email && reviewedSubject(services, p.id, flow.claims.subject) !== user.id) fail('policy_denied', 'Verified email does not match this account.');
      identity.consumeReauth(user.id, body.reauthToken);
      const link = services.resource('identity', { userId: user.id, providerId: p.id, issuer: p.issuer, subject: flow.claims.subject, lastUsedAtMs: null }); services.store.put('identityLinks', link); synchronize(services, user.id, p, flow.claims); services.audit(context.user, 'identity.link', link.id, 'succeeded', undefined, context.requestId); return link;
    }) },
    { method: 'DELETE', path: '/v1/auth/identities/:id', auth: 'member', handler: async context => {
      const body = parse(unlinkSchema, context.body);
      const link = services.store.transaction(() => {
        const value = services.store.get<P.IdentityLink>('identityLinks', context.params.id!); if (!value || value.userId !== context.user!.userId) fail('not_found', 'Identity not found.'); services.mutations.checkRevision(value, body.revision);
        const other = services.store.list<P.IdentityLink>('identityLinks', link => link.userId === value.userId && link.id !== value.id);
        const password = services.store.get<{ id: string; passwordHash: string }>('credentials', value.userId)?.passwordHash;
        if ((!password && other.length === 0) || (identity.requireSSO(value.userId) && !other.some(link => services.store.get<P.OIDCProvider>('oidcProviders', link.providerId)?.enabled))) fail('policy_denied', 'Cannot remove the final login method or required SSO identity.');
        identity.consumeReauth(value.userId, body.reauthToken); services.store.remove('identityLinks', value.id); services.audit(context.user, 'identity.unlink', value.id, 'succeeded', undefined, context.requestId); return value;
      });
      await services.auth.revokeUser(link.userId); await endProviderSessions(services, link.userId, link.providerId); return { id: link.id, deleted: true } satisfies P.Deleted;
    } },
  ];
}
