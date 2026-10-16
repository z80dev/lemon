import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from './services';
import { ApiError, fail } from './errors';
import { z, parse, principal, id, mutation, update, confirm, voice, queryObject } from './validation';
import { opaqueToken, type AccountDeletionFence, type Credential, type SessionSecret, type RevocationHooks } from './auth';
import { validatePushRegistration } from '../integrations/push';
import { clearUserConversationState } from './conversations';
import { deleteUserPairings, revokeWorkspacePairings } from './pairing';
import { hasProductAccess } from '../enterprise/policy';
import { prepareProviderTeardown } from '../enterprise/teardown';
import { backendDescriptor } from './identity';
import { beginOwnerSetupClaim, consumeOwnerSetupProof } from './setup';

const name = z.string().trim().min(1).max(120);
const email = z.string().trim().toLowerCase().pipe(z.email().max(254));
const password = z.string().refine(value => { const size = Buffer.byteLength(value, 'utf8'); return size >= 12 && size <= 1024; });
const timezone = z.string().min(1).max(120).refine(value => { try { new Intl.DateTimeFormat('en', { timeZone: value }); return true; } catch { return false; } });
const language = z.string().min(2).max(64).refine(value => { try { return Intl.getCanonicalLocales(value).length === 1; } catch { return false; } });
const preferences = z.object({ appearance: z.enum(['system', 'light', 'dark']), language: language.nullable(), timezone, botColors: z.boolean(), threadsBesideChat: z.boolean(), voice: voice.extend({ language: language.nullable() }), celebrationsEnabled: z.boolean() }).strict();
const notifications = z.object({ enabled: z.boolean(), sound: z.boolean(), previews: z.boolean(), completed: z.boolean(), needsInput: z.boolean() }).strict();
const push = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('apns'), token: z.string().regex(/^[a-fA-F0-9]{64}$/), environment: z.enum(['sandbox', 'production']), topic: z.string().min(1).max(255) }).strict(),
  z.object({ kind: z.literal('web_push'), endpoint: z.url().max(4096), keys: z.object({ p256dh: z.string().min(1).max(256), auth: z.string().min(1).max(128) }).strict() }).strict(),
]);
const setupSchema = mutation.extend({ setupCode: z.string().min(16).max(512), email, password, displayName: name, workspaceName: name });
const loginSchema = mutation.extend({ email, password, deviceId: id.optional() });
const acceptSchema = mutation.extend({ inviteToken: z.string().min(16).max(512), email, password, displayName: name });
const userSchema = update.extend({ displayName: name.optional(), email: email.optional(), avatarAttachmentId: id.nullable().optional(), preferences: preferences.optional(), notifications: notifications.optional() });
const workspaceSchema = update.extend({ name: name.optional(), timezone: timezone.optional(), enabled: z.boolean().optional(), ownerUserId: id.optional() });
const memberSchema = update.extend({ role: z.enum(['owner', 'admin', 'member']).optional(), enabled: z.boolean().optional() });
const previewSchema = mutation.extend({ action: z.literal('delete') });
const deleteSchema = confirm.extend({ reauthToken: z.string().min(16).max(512) });
const registerSchema = mutation.extend({ installationId: z.string().min(16).max(256).regex(/^[A-Za-z0-9_-]+$/), platform: z.enum(['web', 'macos', 'ios']), name, appVersion: z.string().min(1).max(120), push: push.optional() });
const deviceSchema = update.extend({ name: name.optional(), appVersion: z.string().min(1).max(120).optional(), push: push.nullable().optional(), pushEnabled: z.boolean().optional() });
interface CleanupItem { collection: string; id: string; revision: number; path: string; confirmation: P.Confirmation | null }
interface CleanupPlan { items: CleanupItem[]; fingerprint: string; affected: P.ScopeEffect[]; providerBinding: P.JSONObject; metadataKeys: string[] }
const localCleanupCollections = ['sections', 'devices', 'notifications', 'composerDrafts', 'voiceSessions', 'milestones', 'reminders', 'identityLinks', 'feedbacks', 'memoryImportPreviews', 'preferenceChanges', 'preferenceUndoAttempts', 'reauthTokens'] as const;
const activeAccountDeletions = new WeakMap<BackendServices, Set<string>>();
export interface AccountService { reconcile(): Promise<P.AccountTeardown[]> }
const cleanupState = z.enum(['pending', 'running', 'completed', 'failed', 'outcome_unknown', 'not_required']);
const cleanupError = z.enum(['invalid_request', 'unauthenticated', 'forbidden', 'not_found', 'conflict', 'nonce_conflict', 'revision_conflict', 'confirmation_required', 'expired', 'too_large', 'unsupported_media', 'rate_limited', 'machine_offline', 'upstream_unavailable', 'capability_unavailable', 'policy_denied', 'outcome_unknown', 'cursor_expired', 'internal_error']);
const providerRows = z.array(z.object({ providerId: z.string().min(1).max(256).regex(/^[^/\u0000-\u0020]+$/), kind: z.enum(['email', 'oidc', 'connector', 'channel', 'x']), receiptId: id.nullable(), state: cleanupState, updatedAtMs: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER), errorCode: cleanupError.nullable() }).strict()).max(200);
function activeDeletions(services: BackendServices): Set<string> {
  let active = activeAccountDeletions.get(services);
  if (!active) { active = new Set<string>(); activeAccountDeletions.set(services, active); }
  return active;
}
/** Only read-only receipt probes are allowed here; missing evidence is never completion. */
async function observeTeardown(services: BackendServices, teardownId: string): Promise<P.AccountTeardown> {
  const initial = services.store.require<P.AccountTeardown>('accountTeardowns', teardownId);
  let observed = initial.providerCleanup;
  if (initial.providerCleanup.length > 0) {
    try {
      if (!services.integrations.observeAccountTeardown) fail('capability_unavailable', 'Provider receipt observation is not registered.');
      observed = parse(providerRows, await services.integrations.observeAccountTeardown(teardownId));
      const expected = initial.providerCleanup.map(row => `${row.providerId}:${row.kind}:${row.receiptId}`).sort();
      const actual = observed.map(row => `${row.providerId}:${row.kind}:${row.receiptId}`).sort();
      if (services.mutations.digest(expected) !== services.mutations.digest(actual)) fail('upstream_unavailable', 'Provider receipt observations do not match the original targets.');
      if (observed.some(row => row.state === 'not_required' && !initial.providerCleanup.some(prior => prior.providerId === row.providerId && prior.kind === row.kind && prior.receiptId === row.receiptId && prior.state === 'not_required'))) fail('upstream_unavailable', 'An existing provider cleanup target cannot become not-required without original evidence.');
    } catch (error) {
      observed = initial.providerCleanup.map<P.ProviderCleanupResult>(row => row.state === 'completed' || row.state === 'not_required' ? row : { ...row, state: 'outcome_unknown', errorCode: error instanceof ApiError && error.code !== 'invalid_request' ? error.code : 'upstream_unavailable', updatedAtMs: services.now() });
    }
  }
  return services.store.transaction(() => {
    const current = services.store.require<P.AccountTeardown>('accountTeardowns', teardownId);
    let fence = services.store.metadata<AccountDeletionFence>(`accountDeletion:${current.userId}`);
    const running = activeDeletions(services).has(current.userId);
    if (fence?.status === 'running' && !running) {
      fence = { ...fence, status: 'outcome_unknown', lastErrorCode: 'outcome_unknown', updatedAtMs: services.now() };
      services.store.setMetadata(`accountDeletion:${current.userId}`, fence);
    }
    const rows: P.ProviderCleanupResult[] = observed.map(row => {
      const prior = current.providerCleanup.find(value => value.providerId === row.providerId && value.kind === row.kind && value.receiptId === row.receiptId);
      return prior && prior.updatedAtMs > row.updatedAtMs ? prior : row;
    });
    const providersComplete = rows.every(row => row.state === 'completed' || row.state === 'not_required');
    let productCleanup = current.productCleanup;
    if (fence?.productCleanupComplete) productCleanup = { state: 'completed', updatedAtMs: current.productCleanup.state === 'completed' ? current.productCleanup.updatedAtMs : fence.updatedAtMs, errorCode: null };
    else if (!running && productCleanup.state === 'running') productCleanup = { state: 'outcome_unknown', updatedAtMs: services.now(), errorCode: fence?.lastErrorCode ?? 'outcome_unknown' };
    const complete = productCleanup.state === 'completed' && providersComplete;
    const state: P.AccountTeardown['state'] = complete ? 'completed' : running ? 'running' : 'outcome_unknown';
    const changes = { providerCleanup: rows, productCleanup, state, completedAtMs: complete ? current.completedAtMs ?? services.now() : null };
    if (services.mutations.digest({ providerCleanup: current.providerCleanup, productCleanup: current.productCleanup, state: current.state, completedAtMs: current.completedAtMs }) === services.mutations.digest(changes)) return current;
    const updated = services.update(current, changes); services.store.put('accountTeardowns', updated);
    if (complete && fence) services.store.setMetadata(`accountDeletion:${current.userId}`, { ...fence, status: 'completed', phase: 'completed', providerAcknowledged: true, capabilityDigest: '', encryptedCapability: '', updatedAtMs: services.now() });
    return updated;
  });
}
export async function reconcileAccountDeletions(services: BackendServices): Promise<P.AccountTeardown[]> {
  const records = services.store.list<P.AccountTeardown>('accountTeardowns', row => row.state !== 'completed').slice(0, 200);
  const observed: P.AccountTeardown[] = [];
  for (const record of records) observed.push(await observeTeardown(services, record.id));
  return observed;
}
export function createAccountService(services: BackendServices): AccountService {
  activeDeletions(services);
  return { reconcile: () => reconcileAccountDeletions(services) };
}

/** Account routes never expose credential rows or private resources in membership projections. */
export function createAccountRoutes(services: BackendServices, hooks: RevocationHooks = {}): Route[] {
  const { store } = services;
  const active = activeDeletions(services);
  let dummyHash: Promise<string> | undefined;
  const workspace = () => store.require<P.Workspace>('workspaces', store.metadata<string>('workspaceId') ?? '');
  function current(context: RequestContext): Principal {
    const actor = principal(context.user);
    if (actor.kind !== 'user') fail('forbidden', 'A primary user session is required.');
    if (actor.sessionId !== null) {
      const session = store.get<P.AuthSession>('authSessions', actor.sessionId);
      if (!session || session.expiresAtMs !== null && session.expiresAtMs <= services.now() || store.get<SessionSecret>('sessionSecrets', actor.sessionId)?.revoked !== false) fail('unauthenticated', 'Session expired or revoked.');
      if (session.deviceId !== null && store.get<P.Device>('devices', session.deviceId)?.userId !== actor.userId || session.expiresAtMs === null && (session.deviceId === null || !workspace().enabled)) fail('unauthenticated', 'Device connection was revoked.');
    }
    if (!services.auth.canRead(actor, 'users', services.auth.user(actor.userId))) fail('unauthenticated', 'Account authority was revoked.');
    return actor;
  }
  function rateLimit(address: string) {
    store.transaction(() => {
      const now = services.now();
      for (const [key, maximum] of [[`authRate:${services.mutations.digest(address)}`, 10], ['authRate:global', 200]] as const) {
        const previous = store.metadata<{ startedAtMs: number; count: number }>(key);
        const value = previous && now - previous.startedAtMs < 60000 ? previous : { startedAtMs: now, count: 0 };
        if (value.count >= maximum) fail('rate_limited', 'Too many authentication attempts. Try again later.');
        store.setMetadata(key, { startedAtMs: value.startedAtMs, count: value.count + 1 });
      }
    });
  }
  async function verify(userId: string | undefined, supplied: string): Promise<boolean> {
    const credential = userId ? store.get<Credential>('credentials', userId) : null;
    dummyHash ??= Bun.password.hash(opaqueToken(), { algorithm: 'argon2id' });
    const valid = await Bun.password.verify(supplied, credential?.passwordHash ?? await dummyHash);
    return credential !== null && userId !== undefined && valid && store.get<Credential>('credentials', userId)?.passwordHash === credential.passwordHash;
  }
  async function localAccount(address: string, supplied: string): Promise<P.User> {
    const user = store.list<P.User>('users', value => value.email === address)[0];
    const passwordHash = user ? store.get<Credential>('credentials', user.id)?.passwordHash : undefined;
    if (!await verify(user?.id, supplied) || !user) fail('unauthenticated', 'Email or password is incorrect.');
    if (await services.integrations.requireSSO?.(user.id)) fail('policy_denied', 'This account requires configured SSO.');
    if (store.get<Credential>('credentials', user.id)?.passwordHash !== passwordHash) fail('unauthenticated', 'Email or password is incorrect.');
    return user;
  }
  async function authorizeLocalReplay(context: RequestContext) {
    const body = context.route.path === '/v1/setup' ? parse(setupSchema, context.body) : context.route.path === '/v1/auth/invites/accept' ? parse(acceptSchema, context.body) : parse(loginSchema, context.body);
    rateLimit(body.email);
    const user = await localAccount(body.email, body.password);
    const member = services.auth.member(user.id);
    if (!member.enabled) fail('unauthenticated', 'Account is not an enabled workspace member.');
    if (!hasProductAccess(services, user.id) && member.role === 'member') fail('policy_denied', 'Workspace or directory policy denies product access.');
  }
  function uniqueEmail(address: string, except?: string) {
    if (store.list<P.User>('users', value => value.email === address && value.id !== except).length) fail('conflict', 'Email is already registered.');
  }
  function makeUser(address: string, displayName: string): P.User {
    return services.resource('user', { email: address, displayName, avatarAttachmentId: null,
      preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false },
      notifications: { enabled: true, sound: true, previews: true, completed: true, needsInput: true } });
  }
  function finalOwner(target: P.Member, nextRole: P.Role | undefined, nextEnabled: boolean | undefined) {
    const losesOwnership = target.role === 'owner' && target.enabled && (nextRole !== undefined && nextRole !== 'owner' || nextEnabled === false);
    if (losesOwnership && (workspace().ownerUserId === target.userId || store.list<P.Member>('members', value => value.enabled && value.role === 'owner' && value.id !== target.id).length === 0)) fail('conflict', 'Transfer workspace ownership before removing this owner.');
  }
  function managedMember(context: RequestContext): P.Member {
    const actor = current(context);
    services.auth.requireRole(actor, 'admin');
    const target = store.require<P.Member>('members', parse(id, context.params.id));
    if (store.metadata(`accountDeletion:${target.userId}`)) fail('conflict', 'Account deletion is in progress.');
    if (target.role === 'owner') services.auth.requireRole(actor, 'owner');
    return target;
  }
  function ownedDevice(actor: Principal, deviceId: string): P.Device {
    const result = store.get<P.Device>('devices', deviceId);
    if (!result || result.userId !== actor.userId || !services.auth.canRead(actor, 'devices', result)) fail('not_found', 'Device not found.');
    return result;
  }
  function revokeSessionAuthority(actor: Principal, sessionId: string) {
    const session = store.get<P.AuthSession>('authSessions', sessionId);
    if (!session || session.userId !== actor.userId) fail('not_found', 'Session not found.');
    store.transaction(() => {
      const authority = store.get<SessionSecret>('sessionSecrets', sessionId);
      if (authority) store.put('sessionSecrets', { ...authority, revoked: true });
      store.remove('authSessions', sessionId);
      if (session.deviceId !== null) {
        const another = store.list<P.AuthSession>('authSessions', value => value.userId === actor.userId && value.deviceId === session.deviceId && (value.expiresAtMs === null || value.expiresAtMs > services.now()) && store.get<SessionSecret>('sessionSecrets', value.id)?.revoked === false);
        if (!another.length) {
          const device = store.get<P.Device>('devices', session.deviceId);
          if (device) {
            const updated = services.update(device, { pushEnabled: false });
            store.put('devices', updated);
            services.events.emit('device.upserted', updated, { userIds: [actor.userId] });
          }
        }
      }
    });
  }
  async function revokeSession(actor: Principal, sessionId: string) {
    revokeSessionAuthority(actor, sessionId);
    await hooks.onRevokeSession?.(sessionId);
  }
  async function revokeSessions(actor: Principal, except: string | null = null) {
    const sessions = store.list<P.AuthSession>('authSessions', value => value.userId === actor.userId && value.id !== except);
    store.transaction(() => { for (const session of sessions) revokeSessionAuthority(actor, session.id); });
    let failure: P.ErrorCode | null = null;
    for (const session of sessions) {
      try { await hooks.onRevokeSession?.(session.id); } catch (error) { failure ??= error instanceof ApiError ? error.code : 'internal_error'; }
    }
    if (failure) fail('outcome_unknown', 'Session authority was revoked but external session cleanup remains unconfirmed.', false, { cause: failure });
  }
  function targetPrincipal(target: P.Member): Principal {
    return { kind: 'user', id: target.userId, userId: target.userId, workspaceId: workspace().id, role: target.role, sessionId: null, deviceId: null, botId: null };
  }
  function providerPreview(userId: string): { affected: P.ScopeEffect[]; binding: P.JSONObject } {
    if (services.integrations.previewDeprovisionUser) {
      const preview = services.integrations.previewDeprovisionUser(userId);
      if (preview.affected.some(effect => effect.operation !== 'retain') && !services.integrations.deprovisionUser) fail('capability_unavailable', 'The provider account cleanup implementation is not registered.');
      return preview;
    }
    if (['emailAccounts', 'xConnections', 'identityLinks'].some(collection => store.list<{ userId?: string; ownerUserId?: string }>(collection, value => value.userId === userId || value.ownerUserId === userId).length > 0)) fail('capability_unavailable', 'The registered provider lifecycle service is required to preview account deletion.');
    return { affected: [], binding: {} };
  }
  function listQuery(context: RequestContext) { parse(z.object({ cursor: z.string().min(1).optional(), limit: z.string().regex(/^\d+$/).refine(value => Number(value) >= 1 && Number(value) <= 200).optional() }).strict(), queryObject(context.query)); }
  function accountMetadataKeys(userId: string): string[] {
    const keys = store.list<P.Conversation>('conversations').flatMap(room => [`composer:${userId}:${room.id}`, `conversationRead:${userId}:${room.id}`]);
    keys.push(...store.list<P.Bot>('bots').flatMap(bot => [`botSidebar:${userId}:${bot.id}`, `presenceDigest:${bot.id}:${userId}`]));
    keys.push(...store.list<P.MemoryImportPreview>('memoryImportPreviews', preview => preview.userId === userId).map(preview => `memoryImport:${preview.id}`));
    keys.push(...store.list<P.Reminder>('reminders', reminder => reminder.userId === userId).map(reminder => `reminderNotification:${reminder.id}`));
    return keys.filter(key => store.metadata(key) !== null).sort();
  }
  function cleanupFingerprint(userId: string): string {
    const snapshot: { collection: string; id: string; revision: number | null }[] = [];
    const ownedBotIds = new Set(store.list<P.Bot>('bots', bot => bot.ownerUserId === userId).map(bot => bot.id));
    for (const collection of ['bots', 'conversations', 'routines', 'reminders', 'attachments', 'memories', 'connectors', 'skills', 'templates', 'sections', 'devices', 'notifications', 'authSessions', 'memoryImportPreviews', 'preferenceChanges', 'pairings']) {
      // Session last-seen activity changes no revocation scope; new session IDs still invalidate the preview.
      for (const value of store.list<P.Resource & { ownerUserId?: string; userId?: string; botId?: string | null }>(collection, row => row.ownerUserId === userId || row.userId === userId || typeof row.botId === 'string' && ownedBotIds.has(row.botId))) snapshot.push({ collection, id: value.id, revision: collection === 'authSessions' ? null : value.revision });
    }
    snapshot.sort((a, b) => a.collection.localeCompare(b.collection) || a.id.localeCompare(b.id));
    const previews = new Set(store.list<P.MemoryImportPreview>('memoryImportPreviews', preview => preview.userId === userId).map(preview => preview.id));
    const importAttempts = store.list<{ id: string; previewId: string; candidateId: string; nonce: string; state: string; memoryId: string | null }>('memoryImportAttempts', attempt => previews.has(attempt.previewId));
    return services.mutations.digest({ snapshot, importAttempts, privateMetadata: accountMetadataKeys(userId).map(key => ({ key, value: store.metadata(key) })) });
  }
  async function cleanupPreview(actor: Principal): Promise<CleanupPlan> {
    const items: CleanupItem[] = [];
    const affected: P.ScopeEffect[] = [];
    const ownedBotIds = new Set(store.list<P.Bot>('bots', value => value.ownerUserId === actor.userId).map(value => value.id));
    for (const collection of ['attachments', 'conversations', 'bots', 'connectors', 'routines', 'memories']) {
      for (const value of store.list<P.Resource & { ownerUserId?: string; userId?: string; botId?: string | null; botIds?: string[]; kind?: string }>(collection, row => row.ownerUserId === actor.userId || row.userId === actor.userId)) {
        if (collection !== 'bots' && (value.botId !== undefined && value.botId !== null && ownedBotIds.has(value.botId) || collection === 'conversations' && value.kind !== 'group' && value.botIds?.some(botId => ownedBotIds.has(botId)))) continue;
        const path = `/v1/${collection === 'memories' ? 'memory' : collection}/${encodeURIComponent(value.id)}`;
        const confirmation = await services.invoke<P.Confirmation>(actor, 'POST', `${path}/preview`, { clientNonce: opaqueToken(), action: collection === 'connectors' ? 'disconnect' : collection === 'memories' ? 'forget' : 'delete' });
        items.push({ collection, id: value.id, revision: value.revision, path, confirmation });
        affected.push(...confirmation.affected);
        affected.push({ resourceType: collection, id: value.id, machineId: null, operation: 'delete', explanation: 'Remove the exact account-owned lifecycle root and its disclosed dependent resources.' });
      }
    }
    for (const collection of ['skills', 'templates', 'reminders']) for (const value of store.list<P.Resource & { ownerUserId?: string; userId?: string }>(collection, row => row.ownerUserId === actor.userId || row.userId === actor.userId)) {
      items.push({ collection, id: value.id, revision: value.revision, path: `/v1/${collection}/${encodeURIComponent(value.id)}`, confirmation: null });
      affected.push({ resourceType: collection, id: value.id, machineId: null, operation: 'delete', explanation: 'Remove this account-owned product resource through its owning lifecycle service.' });
    }
    for (const collection of ['sections', 'devices', 'notifications', 'authSessions', 'memoryImportPreviews', 'preferenceChanges']) {
      for (const value of store.list<P.Resource & { userId: string }>(collection, row => row.userId === actor.userId)) affected.push({ resourceType: collection, id: value.id, machineId: null, operation: collection === 'authSessions' ? 'revoke' : 'delete', explanation: 'Remove account-owned product data and installation authority.' });
    }
    for (const pairing of store.list<P.Pairing>('pairings', row => row.ownerUserId === actor.userId)) affected.push({ resourceType: 'pairing', id: pairing.id, machineId: null, operation: 'delete', explanation: 'Remove this account pairing requests, private claim proofs and staged session credential custody.' });
    for (const value of store.list<P.Machine>('machines', row => row.ownerUserId === actor.userId || row.accessUserIds.includes(actor.userId))) affected.push({ resourceType: 'machine', id: value.id, machineId: value.id, operation: 'retain', explanation: 'Host files, browser sessions, provider logins and OS credentials remain; revoke them independently with the operator.' });
    const provider = providerPreview(actor.userId);
    affected.push(...provider.affected);
    return { items, affected, fingerprint: cleanupFingerprint(actor.userId), providerBinding: provider.binding, metadataKeys: accountMetadataKeys(actor.userId) };
  }
  const routes: Route[] = [
    { method: 'GET', path: '/v1/setup', auth: 'public', status: 200, handler: () => ({ ...backendDescriptor(services), setupRequired: store.metadata<string>('workspaceId') === null } satisfies P.SetupStatus) },
    { method: 'GET', path: '/v1/identity', auth: 'member', status: 200, handler: context => {
      const actor = principal(context.user);
      if (actor.kind !== 'user' || actor.sessionId === null) fail('unauthenticated', 'A product account session is required.');
      return { ...backendDescriptor(services), workspaceId: actor.workspaceId } satisfies P.BackendIdentity;
    } },
    { method: 'POST', path: '/v1/setup', auth: 'public', status: 200, handler: async context => {
      const body = parse(setupSchema, context.body); rateLimit('setup');
      beginOwnerSetupClaim(services, body.setupCode);
      const passwordHash = await Bun.password.hash(body.password, { algorithm: 'argon2id' });
      const created = store.transaction(() => {
        consumeOwnerSetupProof(services, body.setupCode);
        const user = makeUser(body.email, body.displayName);
        const member = services.resource('member', { userId: user.id, email: user.email, displayName: user.displayName, role: 'owner' as const, enabled: true });
        const workspace = services.resource('workspace', { name: body.workspaceName, ownerUserId: user.id, enabled: true, timezone: 'UTC' });
        store.put('users', user); store.put('members', member); store.put('workspaces', workspace); store.put('credentials', { id: user.id, passwordHash });
        store.setMetadata('workspaceId', workspace.id);
        return { authResult: services.auth.session(user.id) };
      });
      return created.authResult;
    } },
    { method: 'POST', path: '/v1/auth/login', auth: 'public', status: 200, handler: async context => {
      const body = parse(loginSchema, context.body); rateLimit(body.email);
      const user = await localAccount(body.email, body.password);
      return services.auth.session(user.id, body.deviceId);
    } },
    { method: 'POST', path: '/v1/auth/invites/accept', auth: 'public', status: 200, handler: async context => {
      const body = parse(acceptSchema, context.body); rateLimit(body.email);
      const secret = store.list<{ id: string; tokenDigest: string }>('inviteSecrets', value => value.tokenDigest === services.mutations.digest(body.inviteToken))[0];
      const invite = secret && store.get<P.MemberInvite>('invites', secret.id);
      if (!invite || invite.status !== 'pending' || invite.email !== body.email) fail('unauthenticated', 'Invalid invitation.');
      if (invite.expiresAtMs <= services.now()) fail('expired', 'Invitation expired.');
      const existing = store.list<P.User>('users', value => value.email === body.email)[0];
      const existingHash = existing ? store.get<Credential>('credentials', existing.id)?.passwordHash : undefined;
      if (existing) await localAccount(body.email, body.password);
      const passwordHash = existing ? null : await Bun.password.hash(body.password, { algorithm: 'argon2id' });
      const user = store.transaction(() => {
        const latest = store.require<P.MemberInvite>('invites', invite.id);
        if (existing && store.get<Credential>('credentials', existing.id)?.passwordHash !== existingHash) fail('unauthenticated', 'Credentials changed; authenticate again.');
        if (latest.status !== 'pending' || latest.expiresAtMs <= services.now()) fail('expired', 'Invitation is no longer available.');
        const user = existing ?? makeUser(body.email, body.displayName);
        if (!existing) { uniqueEmail(user.email); store.put('users', user); store.put<Credential>('credentials', { id: user.id, passwordHash: passwordHash ?? fail('internal_error', 'Password credential was not prepared.', false) }); }
        const prior = store.list<P.Member>('members', value => value.userId === user.id)[0];
        if (prior?.enabled) fail('conflict', 'Account is already a member.');
        const member = prior ? services.update(prior, { enabled: true, role: latest.role }) : services.resource('member', { userId: user.id, email: user.email, displayName: user.displayName, role: latest.role, enabled: true });
        store.put('members', member); store.put('invites', services.update(latest, { status: 'accepted' })); store.remove('inviteSecrets', latest.id);
        services.events.emit('member.upserted', member, { public: true });
        return { authResult: services.auth.session(user.id) };
      });
      return user.authResult;
    } },
    { method: 'POST', path: '/v1/auth/reauth', auth: 'member', mutation: false, status: 200, handler: async context => {
      const body = parse(z.object({ password }).strict(), context.body); const actor = current(context); rateLimit(actor.userId);
      if (!await verify(actor.userId, body.password)) fail('unauthenticated', 'Password is incorrect.');
      if (await services.integrations.requireSSO?.(actor.userId)) fail('policy_denied', 'This account requires SSO reauthentication.');
      return services.auth.issueReauth(actor.userId);
    } },
    { method: 'GET', path: '/v1/auth/sessions', auth: 'member', status: 200, handler: context => {
      listQuery(context); const actor = current(context);
      return services.page(context, store.list<P.AuthSession>('authSessions', value => value.userId === actor.userId && (value.expiresAtMs === null || value.expiresAtMs > services.now()) && store.get<SessionSecret>('sessionSecrets', value.id)?.revoked === false).map(value => ({ ...value, current: value.id === actor.sessionId })));
    } },
    { method: 'DELETE', path: '/v1/auth/sessions/:id', auth: 'member', status: 200, handler: async context => { parse(mutation, context.body); const sessionId = parse(id, context.params.id); await revokeSession(current(context), sessionId); return { id: sessionId, deleted: true } satisfies P.Deleted; } },
    { method: 'POST', path: '/v1/auth/logout', auth: 'member', status: 200, handler: async context => { parse(mutation, context.body); const actor = current(context); if (!actor.sessionId) fail('unauthenticated', 'User session required.'); await revokeSession(actor, actor.sessionId); await hooks.onLogoutUser?.(actor.userId); return { ok: true }; } },
    { method: 'GET', path: '/v1/me', auth: 'member', status: 200, handler: context => services.auth.user(current(context).userId) },
    { method: 'PATCH', path: '/v1/me', auth: 'member', status: 200, handler: context => {
      const { revision, clientNonce, ...changes } = parse(userSchema, context.body); const actor = current(context);
      return store.transaction(() => {
        const user = services.auth.user(actor.userId); services.mutations.checkRevision(user, revision);
        if (changes.email !== undefined) uniqueEmail(changes.email, user.id);
        if (changes.avatarAttachmentId) { const attachment = services.auth.attachment(actor, changes.avatarAttachmentId); if (attachment.ownerUserId !== actor.userId || !attachment.mime.startsWith('image/')) fail('invalid_request', 'Avatar must be an owned image.'); }
        const updated = services.update(user, changes); store.put('users', updated);
        const member = services.update(services.auth.member(user.id), { email: updated.email, displayName: updated.displayName }); store.put('members', member);
        services.events.emit('user.updated', updated, { userIds: [user.id] }); services.events.emit('member.upserted', member, { public: true }); return updated;
      });
    } },
    { method: 'PUT', path: '/v1/me/password', auth: 'member', status: 200, handler: async context => {
      const body = parse(mutation.extend({ currentPassword: password, newPassword: password }), context.body); const actor = current(context); rateLimit(actor.userId);
      const originalCredential = store.get<Credential>('credentials', actor.userId);
      if (!await verify(actor.userId, body.currentPassword)) fail('unauthenticated', 'Password is incorrect.');
      if (await services.integrations.requireSSO?.(actor.userId)) fail('policy_denied', 'This account requires configured SSO.');
      const passwordHash = await Bun.password.hash(body.newPassword, { algorithm: 'argon2id' });
      store.transaction(() => {
        if (!originalCredential || store.get<Credential>('credentials', actor.userId)?.passwordHash !== originalCredential.passwordHash) fail('conflict', 'Credentials changed; authenticate again.');
        store.put('credentials', { id: actor.userId, passwordHash });
      });
      await revokeSessions(actor, actor.sessionId);
      return { ok: true };
    } },
    { method: 'POST', path: '/v1/me/preview', auth: 'member', status: 200, handler: async context => {
      parse(previewSchema, context.body); const actor = current(context); const user = services.auth.user(actor.userId); finalOwner(services.auth.member(actor.userId), 'member', false);
      const plan = await cleanupPreview(actor);
      const confirmation = services.mutations.preview(actor, user, 'delete', user.email, ['Remove the listed product-owned personal and Team resources, private notes, attachments, devices and sessions.', 'Host files, browser/provider logins, external billing and operator backups remain except the explicitly listed provider retirement effects. Backup retention follows deployment policy.'], plan.affected, { fingerprint: plan.fingerprint, providerBinding: plan.providerBinding });
      store.setMetadata(`accountCleanup:${confirmation.confirmationToken}`, plan); return confirmation;
    } },
    { method: 'DELETE', path: '/v1/me', auth: 'member', status: 200, handler: async context => {
      const body = parse(deleteSchema, context.body); const actor = current(context); const user = services.auth.user(actor.userId); finalOwner(services.auth.member(actor.userId), 'member', false);
      const plan = store.metadata<CleanupPlan>(`accountCleanup:${body.confirmationToken}`);
      if (!plan || plan.fingerprint !== cleanupFingerprint(actor.userId) || services.mutations.digest(plan.providerBinding) !== services.mutations.digest(providerPreview(actor.userId).binding)) fail('confirmation_required', 'Resources changed; preview deletion again.');
      if (store.metadata(`accountDeletion:${actor.userId}`)) fail('outcome_unknown', 'An earlier account deletion requires reconciliation.', false, { resourceIds: [user.id] });
      const capability = opaqueToken();
      const teardown: Principal = { ...actor, sessionId: null, scopes: [...(actor.scopes ?? []), `account_delete:${capability}`] };
      const targets = plan.items.map(item => ({ collection: item.collection, id: item.id }));
      for (const collection of localCleanupCollections) {
        if (collection === 'reauthTokens') continue;
        for (const value of store.list<{ id: string; userId: string }>(collection, row => row.userId === actor.userId)) targets.push({ collection, id: value.id });
      }
      let fence: AccountDeletionFence = { status: 'running', operationId: `account_delete_${services.mutations.digest({ userId: user.id, clientNonce: body.clientNonce })}`, nonce: body.clientNonce, capabilityDigest: services.mutations.digest(capability), encryptedCapability: services.encrypt(capability), phase: 'prepared', targets, completedIds: [], providerAcknowledged: false, productCleanupComplete: false, lastErrorCode: null, providerBinding: plan.providerBinding, createdAtMs: services.now(), updatedAtMs: services.now() };
      const fenceKey = `accountDeletion:${actor.userId}`;
      store.transaction(() => {
        services.mutations.confirm(actor, user, 'delete', body, { fingerprint: plan.fingerprint, providerBinding: plan.providerBinding });
        services.auth.consumeReauth(actor.userId, body.reauthToken);
        store.setMetadata(fenceKey, fence);
        const providerCleanup = parse(providerRows, prepareProviderTeardown(services, actor.userId, fence.operationId));
        const record: P.AccountTeardown = { id: fence.operationId, revision: 1, createdAtMs: fence.createdAtMs, updatedAtMs: fence.updatedAtMs, operation: 'delete_account', userId: user.id, workspaceId: actor.workspaceId, state: 'running', productCleanup: { state: 'running', updatedAtMs: services.now(), errorCode: null }, providerCleanup, requestId: context.requestId, startedAtMs: services.now(), completedAtMs: null };
        store.put('accountTeardowns', record);
        hooks.beforeRevokeUser?.(teardown);
      });
      active.add(actor.userId);
      context.nonceResourceIds.push(user.id, fence.operationId, ...plan.items.map(item => item.id));
      const productErrors: P.ErrorCode[] = [];
      let providerError: P.ErrorCode | null = null;
      try {
        try { await revokeSessions(actor); } catch (error) { productErrors.push(error instanceof ApiError ? error.code : 'internal_error'); }
        fence = { ...fence, phase: 'sessions_revoked', updatedAtMs: services.now() }; store.setMetadata(fenceKey, fence);
        const allowed = new Set(plan.affected.filter(effect => effect.operation !== 'retain').map(effect => `${effect.resourceType}:${effect.id}:${effect.operation}`));
        for (const item of plan.items) {
          if (!store.get(item.collection, item.id)) continue;
          try {
            fence = { ...fence, phase: 'resources', updatedAtMs: services.now() }; store.setMetadata(fenceKey, fence);
            let confirmation = item.confirmation;
            if (confirmation !== null) {
              confirmation = await services.invoke<P.Confirmation>(teardown, 'POST', `${item.path}/preview`, { clientNonce: opaqueToken(), action: item.collection === 'connectors' ? 'disconnect' : item.collection === 'memories' ? 'forget' : 'delete' });
              if (confirmation.affected.some(effect => effect.operation !== 'retain' && !allowed.has(`${effect.resourceType}:${effect.id}:${effect.operation}`))) fail('outcome_unknown', 'Account cleanup stopped because its exact candidate set changed.', false);
            }
            await services.invoke(teardown, 'DELETE', item.path, confirmation === null ? { clientNonce: opaqueToken(), revision: item.revision } : { clientNonce: opaqueToken(), revision: confirmation.revision, confirmationToken: confirmation.confirmationToken, confirmName: confirmation.confirmName });
            fence = { ...fence, completedIds: [...fence.completedIds, item.id], updatedAtMs: services.now() }; store.setMetadata(fenceKey, fence);
          } catch (error) { productErrors.push(error instanceof ApiError ? error.code : 'internal_error'); }
        }
        fence = { ...fence, phase: 'providers', updatedAtMs: services.now() }; store.setMetadata(fenceKey, fence);
        try { await services.integrations.deprovisionUser?.(actor.userId); } catch (error) { providerError = error instanceof ApiError ? error.code : 'upstream_unavailable'; }
        fence = { ...fence, phase: 'finalizing', providerAcknowledged: providerError === null, updatedAtMs: services.now() }; store.setMetadata(fenceKey, fence);
        try { await services.auth.revokeUser(actor.userId); } catch (error) { productErrors.push(error instanceof ApiError ? error.code : 'internal_error'); }
        store.transaction(() => {
          clearUserConversationState(services, actor.userId);
          deleteUserPairings(services, actor.userId);
          for (const key of plan.metadataKeys) store.setMetadata(key, null);
          const previews = new Set(store.list<P.MemoryImportPreview>('memoryImportPreviews', preview => preview.userId === actor.userId).map(preview => preview.id));
          for (const attempt of store.list<{ id: string; previewId: string }>('memoryImportAttempts', value => previews.has(value.previewId))) store.remove('memoryImportAttempts', attempt.id);
          for (const collection of localCleanupCollections) for (const value of store.list<{ id: string; userId: string }>(collection, row => row.userId === actor.userId)) {
            if (collection === 'devices') { store.setMetadata(`devicePush:${value.id}`, null); store.setMetadata(`devicePushRegisteredAt:${value.id}`, null); store.setMetadata(`deviceInstallation:${value.id}`, null); services.events.emit('device.deleted', { id: value.id, deleted: true }, { userIds: [actor.userId] }); }
            store.remove(collection, value.id);
          }
          const member = services.auth.member(actor.userId); finalOwner(member, 'member', false); store.remove('members', member.id); store.remove('credentials', user.id); store.remove('users', user.id);
          store.remove('managedIdentities', user.id); store.remove('scimUsers', user.id);
          store.setMetadata(`accountCleanup:${body.confirmationToken}`, null); services.events.emit('member.deleted', { id: member.id, deleted: true }, { public: true });
          fence = { ...fence, status: 'outcome_unknown', phase: 'providers', productCleanupComplete: productErrors.length === 0, lastErrorCode: productErrors[0] ?? providerError, updatedAtMs: services.now() }; store.setMetadata(fenceKey, fence);
          const record = store.require<P.AccountTeardown>('accountTeardowns', fence.operationId);
          store.put('accountTeardowns', services.update(record, { state: 'outcome_unknown', productCleanup: { state: productErrors.length === 0 ? 'completed' : 'outcome_unknown', updatedAtMs: services.now(), errorCode: productErrors[0] ?? null } }));
        });
        active.delete(actor.userId);
        const observed = await observeTeardown(services, fence.operationId);
        if (observed.state !== 'completed') fail('outcome_unknown', 'Product and provider cleanup states must be observed by a workspace Owner.', false);
        return { id: user.id, deleted: true } satisfies P.Deleted;
      } catch (error) {
        const currentFence = store.metadata<AccountDeletionFence>(fenceKey) ?? fence;
        fence = { ...currentFence, status: 'outcome_unknown', lastErrorCode: currentFence.lastErrorCode ?? (error instanceof ApiError ? error.code : 'internal_error'), updatedAtMs: services.now() }; store.setMetadata(fenceKey, fence);
        const record = store.require<P.AccountTeardown>('accountTeardowns', fence.operationId);
        if (record.state !== 'completed') store.put('accountTeardowns', services.update(record, { state: 'outcome_unknown', productCleanup: fence.productCleanupComplete ? record.productCleanup : { state: 'outcome_unknown', updatedAtMs: services.now(), errorCode: fence.lastErrorCode } }));
        fail('outcome_unknown', 'Account cleanup requires Owner receipt observation; do not replay deletion.', false, { teardownId: fence.operationId, userId: user.id, resourceIds: [user.id, fence.operationId, ...plan.items.map(item => item.id)].slice(0, 200), cause: fence.lastErrorCode });
      } finally {
        active.delete(actor.userId);
      }
    } },
    { method: 'GET', path: '/v1/workspace', auth: 'member', status: 200, handler: () => workspace() },
    { method: 'PATCH', path: '/v1/workspace', auth: 'owner', status: 200, handler: async context => {
      const { revision, clientNonce, ownerUserId, ...changes } = parse(workspaceSchema, context.body); const actor = current(context); services.auth.requireRole(actor, 'owner');
      const revokedSessionIds: string[] = [];
      const result = store.transaction(() => {
        const target = workspace(); services.mutations.checkRevision(target, revision);
        if (ownerUserId !== undefined && ownerUserId !== target.ownerUserId) {
          const next = services.auth.member(ownerUserId); if (!next.enabled || store.metadata(`accountDeletion:${ownerUserId}`)) fail('invalid_request', 'New owner must be an enabled member not undergoing deletion.');
          const previous = services.auth.member(target.ownerUserId);
          const promoted = services.update(next, { role: 'owner' }); const demoted = services.update(previous, { role: 'admin' });
          store.put('members', promoted); store.put('members', demoted); services.events.emit('member.upserted', promoted, { public: true }); services.events.emit('member.upserted', demoted, { public: true });
        }
        const updated = services.update(target, { ...changes, ...(ownerUserId === undefined ? {} : { ownerUserId }) }); store.put('workspaces', updated);
        if (!updated.enabled) {
          revokeWorkspacePairings(services, updated.id);
          const paired = store.list<P.AuthSession>('authSessions', session => session.expiresAtMs === null);
          for (const session of paired) {
            const secret = store.get<SessionSecret>('sessionSecrets', session.id);
            if (secret) store.put('sessionSecrets', { ...secret, revoked: true });
            store.remove('authSessions', session.id); revokedSessionIds.push(session.id);
          }
          for (const deviceId of new Set(paired.map(session => session.deviceId))) {
            if (deviceId === null || store.list<P.AuthSession>('authSessions', session => session.deviceId === deviceId && (session.expiresAtMs === null || session.expiresAtMs > services.now()) && store.get<SessionSecret>('sessionSecrets', session.id)?.revoked === false).length) continue;
            const device = store.get<P.Device>('devices', deviceId);
            if (device) { const disabled = services.update(device, { pushEnabled: false }); store.put('devices', disabled); services.events.emit('device.upserted', disabled, { userIds: [device.userId] }); }
          }
        }
        services.events.emit('workspace.updated', updated, { public: true }); return updated;
      });
      const revoked = await Promise.allSettled(revokedSessionIds.map(sessionId => hooks.onRevokeSession?.(sessionId)));
      const failure = revoked.find(value => value.status === 'rejected');
      if (failure?.status === 'rejected') throw failure.reason;
      return result;
    } },
    { method: 'GET', path: '/v1/members', auth: 'member', status: 200, handler: context => { listQuery(context); return services.page(context, store.list<P.Member>('members')); } },
    { method: 'PATCH', path: '/v1/members/:id', auth: 'admin', status: 200, handler: async context => {
      const { revision, clientNonce, ...changes } = parse(memberSchema, context.body); const target = managedMember(context);
      if (changes.role === 'owner') services.auth.requireRole(current(context), 'owner');
      const updated = store.transaction(() => { const latest = store.require<P.Member>('members', target.id); services.mutations.checkRevision(latest, revision); finalOwner(latest, changes.role, changes.enabled); if (changes.enabled === false) hooks.beforeRevokeUser?.(targetPrincipal(latest)); const result = services.update(latest, changes); store.put('members', result); services.events.emit('member.upserted', result, { public: true }); return result; });
      if (changes.enabled === false) await services.auth.revokeUser(target.userId);
      return updated;
    } },
    { method: 'POST', path: '/v1/members/:id/preview', auth: 'admin', status: 200, handler: context => { parse(previewSchema, context.body); const target = managedMember(context); finalOwner(target, 'member', false); return services.mutations.preview(current(context), target, 'delete', target.displayName, ['Remove workspace membership; revoke sessions/devices/sockets, cancel pending gates and stop future routines.', 'Private resources, host files, provider logins and backups are retained; membership administration does not grant private transcript access.']); } },
    { method: 'DELETE', path: '/v1/members/:id', auth: 'admin', status: 200, handler: async context => {
      const body = parse(confirm, context.body); const target = managedMember(context);
      store.transaction(() => { const latest = store.require<P.Member>('members', target.id); finalOwner(latest, 'member', false); services.mutations.confirm(current(context), latest, 'delete', body); hooks.beforeRevokeUser?.(targetPrincipal(latest)); store.put('members', services.update(latest, { enabled: false })); });
      await services.auth.revokeUser(target.userId); store.remove('members', target.id); services.events.emit('member.deleted', { id: target.id, deleted: true }, { public: true }); return { id: target.id, deleted: true };
    } },
    { method: 'GET', path: '/v1/invites', auth: 'admin', status: 200, handler: context => { listQuery(context); return services.page(context, store.list<P.MemberInvite>('invites').map(value => value.status === 'pending' && value.expiresAtMs <= services.now() ? { ...value, status: 'expired' as const } : value)); } },
    { method: 'POST', path: '/v1/invites', auth: 'admin', status: 201, handler: context => {
      const body = parse(mutation.extend({ email, role: z.enum(['admin', 'member']), expiresInMs: z.number().int().positive().max(30 * 86400000).optional() }), context.body);
      const inviteToken = opaqueToken();
      return store.transaction(() => {
        if (store.list<P.Member>('members', value => value.email === body.email && value.enabled).length || store.list<P.MemberInvite>('invites', value => value.email === body.email && value.status === 'pending' && value.expiresAtMs > services.now()).length) fail('conflict', 'Member or pending invitation already exists.');
        const invite = services.resource('invite', { email: body.email, role: body.role, expiresAtMs: services.now() + (body.expiresInMs ?? 7 * 86400000), status: 'pending' as const });
        store.put('invites', invite); store.put('inviteSecrets', { id: invite.id, tokenDigest: services.mutations.digest(inviteToken) }); services.events.emit('invite.upserted', invite, { admin: true });
        return { invite, inviteToken, inviteUrl: `${services.config.publicUrl}/invite#token=${encodeURIComponent(inviteToken)}` } satisfies P.InviteIssued;
      });
    } },
    { method: 'DELETE', path: '/v1/invites/:id', auth: 'admin', status: 200, handler: context => { parse(mutation, context.body); const target = store.require<P.MemberInvite>('invites', parse(id, context.params.id)); const revoked = services.update(target, { status: 'revoked' }); store.put('invites', revoked); store.remove('inviteSecrets', target.id); services.events.emit('invite.upserted', revoked, { admin: true }); return { id: target.id, deleted: true }; } },
    { method: 'GET', path: '/v1/devices', auth: 'member', status: 200, handler: context => { listQuery(context); return services.page(context, store.list<P.Device>('devices', value => value.userId === current(context).userId)); } },
    { method: 'POST', path: '/v1/devices', auth: 'member', status: 201, handler: async context => {
      const body = parse(registerSchema, context.body); const actor = current(context); if (body.push) await validatePushRegistration(body.push);
      if (body.push && (body.platform === 'web' ? body.push.kind !== 'web_push' : body.push.kind !== 'apns')) fail('invalid_request', 'Push registration must match the installation platform.');
      return store.transaction(() => {
        const session = actor.sessionId === null ? null : store.require<P.AuthSession>('authSessions', actor.sessionId);
        if (session?.expiresAtMs === null) {
          const bound = session.deviceId === null ? null : store.get<P.Device>('devices', session.deviceId);
          if (!bound || bound.userId !== actor.userId || bound.platform !== body.platform || store.metadata<string>(`deviceInstallation:${bound.id}`) !== body.installationId) fail('forbidden', 'A paired session cannot change its device installation.');
        }
        const prior = store.list<P.Device>('devices', value => value.userId === actor.userId && store.metadata<string>(`deviceInstallation:${value.id}`) === body.installationId)[0];
        if (prior && prior.platform !== body.platform) fail('invalid_request', 'Installation platform cannot change.');
        const fields = { userId: actor.userId, platform: body.platform, name: body.name, appVersion: body.appVersion, pushEnabled: body.push !== undefined || prior?.pushEnabled === true, lastSeenAtMs: services.now() };
        const device = prior ? services.update(prior, fields) : services.resource('device', fields); store.put('devices', device); store.setMetadata(`deviceInstallation:${device.id}`, body.installationId);
        if (body.push) { store.setMetadata(`devicePush:${device.id}`, services.encrypt(body.push)); store.setMetadata(`devicePushRegisteredAt:${device.id}`, services.now()); }
        if (session && session.expiresAtMs !== null && session.deviceId !== device.id) store.put('authSessions', services.update(session, { deviceId: device.id }));
        services.events.emit('device.upserted', device, { userIds: [actor.userId] }); return device;
      });
    } },
    { method: 'PATCH', path: '/v1/devices/:id', auth: 'member', status: 200, handler: async context => {
      const { revision, clientNonce, push, ...changes } = parse(deviceSchema, context.body); const actor = current(context); if (push) await validatePushRegistration(push);
      return store.transaction(() => {
        const device = ownedDevice(actor, parse(id, context.params.id)); services.mutations.checkRevision(device, revision);
        if (push && (device.platform === 'web' ? push.kind !== 'web_push' : push.kind !== 'apns')) fail('invalid_request', 'Push registration must match the installation platform.');
        if (push !== undefined) { store.setMetadata(`devicePush:${device.id}`, push === null ? null : services.encrypt(push)); store.setMetadata(`devicePushRegisteredAt:${device.id}`, push === null ? null : services.now()); }
        if (changes.pushEnabled === true && !store.metadata(`devicePush:${device.id}`)) fail('invalid_request', 'Register push credentials before enabling delivery.');
        const updated = services.update(device, { ...changes, ...(push === null ? { pushEnabled: false } : {}), lastSeenAtMs: services.now() }); store.put('devices', updated); services.events.emit('device.upserted', updated, { userIds: [actor.userId] }); return updated;
      });
    } },
    { method: 'DELETE', path: '/v1/devices/:id', auth: 'member', status: 200, handler: async context => {
      parse(mutation, context.body); const actor = current(context); const device = ownedDevice(actor, parse(id, context.params.id));
      const revoked = await Promise.allSettled(store.list<P.AuthSession>('authSessions', value => value.deviceId === device.id && value.userId === actor.userId).map(session => revokeSession(actor, session.id)));
      store.transaction(() => { store.remove('devices', device.id); store.setMetadata(`devicePush:${device.id}`, null); store.setMetadata(`devicePushRegisteredAt:${device.id}`, null); store.setMetadata(`deviceInstallation:${device.id}`, null); services.events.emit('device.deleted', { id: device.id, deleted: true }, { userIds: [actor.userId] }); });
      const failure = revoked.find(result => result.status === 'rejected');
      if (failure?.status === 'rejected') throw failure.reason;
      return { id: device.id, deleted: true };
    } },
    { method: 'GET', path: '/v1/account-teardowns', auth: 'owner', status: 200, handler: async context => {
      const actor = current(context); services.auth.requireRole(actor, 'owner');
      const query = parse(z.object({ cursor: z.string().min(1).optional(), limit: z.string().regex(/^\d+$/).refine(value => Number(value) >= 1 && Number(value) <= 200).optional(), userId: id.optional(), state: z.enum(['pending', 'running', 'completed', 'failed', 'outcome_unknown']).optional() }).strict(), queryObject(context.query));
      const page = services.page(context, store.list<P.AccountTeardown>('accountTeardowns', record => record.workspaceId === actor.workspaceId && (query.userId === undefined || query.userId === record.userId) && (query.state === undefined || query.state === record.state)));
      const items: P.AccountTeardown[] = [];
      for (const record of page.items) items.push(await observeTeardown(services, record.id));
      services.auth.requireRole(current(context), 'owner');
      return { items, nextCursor: page.nextCursor } satisfies P.Page<P.AccountTeardown>;
    } },
    { method: 'GET', path: '/v1/account-teardowns/:id', auth: 'owner', status: 200, handler: async context => {
      const actor = current(context); services.auth.requireRole(actor, 'owner');
      const record = store.get<P.AccountTeardown>('accountTeardowns', parse(id, context.params.id));
      if (!record || record.workspaceId !== actor.workspaceId) fail('not_found', 'Account teardown not found.');
      const observed = await observeTeardown(services, record.id);
      services.auth.requireRole(current(context), 'owner');
      return observed;
    } },
  ];
  const lists: Record<string, true> = { '/v1/auth/sessions': true, '/v1/members': true, '/v1/invites': true, '/v1/devices': true, '/v1/account-teardowns': true };
  return routes.map(route => ({ ...route, ...(route.method === 'POST' && route.auth === 'public' ? { authorizeReplay: authorizeLocalReplay } : {}), handler(context: RequestContext) {
    if (!(route.method === 'GET' && lists[route.path]) && context.query.size > 0) fail('invalid_request', 'This endpoint does not accept query parameters.');
    return route.handler(context);
  } }));
}
