import { afterEach, describe, expect, test } from 'bun:test';
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { installHelpers } from '../../src/core/helpers';
import { createEventService } from '../../src/core/events';
import { createMutationService } from '../../src/core/mutations';
import { createAccessService, opaqueToken, tokenSha256, type RevocationHooks } from '../../src/core/auth';
import { ApiError } from '../../src/core/errors';
import { defaultGovernance } from '../../src/enterprise/policy';

const open: Store[] = [];
afterEach(() => { for (const store of open.splice(0)) store.close(); });

/** Real SQLite, durable confirmations/nonces and authenticated encryption; external calls fail closed. */
export function authFixture(hooks: RevocationHooks = {}) {
  const store = new Store(':memory:'); open.push(store);
  const key = randomBytes(32);
  let now = 1791940000000;
  const cancelled: string[] = [];
  const unavailable = (): never => { throw new Error('External dependency must be explicitly supplied for this boundary test.'); };
  const services = {
    store,
    config: { publicUrl: 'https://lemon.example', controlUrl: 'ws://127.0.0.1:4040/ws', operatorToken: 'test-only', dataDir: '', host: '127.0.0.1', port: 4080, trustedOverlay: false, operator: { version: 1, trustedFrontendOrigins: [], oauthRedirectUris: [], serverSecrets: {}, channelProviders: [], emailProviders: [], eventProviders: [], hostDrivers: [], xProvider: null, exportAllowedOrigins: [], requiredRuntimeDestinations: [], breakGlassOwnerUserId: null } },
    encrypt(value: unknown) { const nonce = randomBytes(12); const cipher = createCipheriv('aes-256-gcm', key, nonce); const encrypted = Buffer.concat([cipher.update(JSON.stringify(value), 'utf8'), cipher.final()]); return Buffer.concat([nonce, cipher.getAuthTag(), encrypted]).toString('base64url'); },
    decrypt<T>(value: string): T { const bytes = Buffer.from(value, 'base64url'); const cipher = createDecipheriv('aes-256-gcm', key, bytes.subarray(0, 12)); cipher.setAuthTag(bytes.subarray(12, 28)); return JSON.parse(Buffer.concat([cipher.update(bytes.subarray(28)), cipher.final()]).toString('utf8')) as T; },
    gates: { create: unavailable, resolve: unavailable, wait: unavailable, cancelUser: (userId: string) => { cancelled.push(userId); } },
    integrations: { admission: unavailable, effectivePolicy: unavailable, connectorConfig: unavailable, sendApprovedDraft: unavailable, emitProviderNotifications: unavailable, channelIngress: unavailable, providerCapabilities: unavailable },
    invoke: unavailable,
  } as BackendServices;
  installHelpers(services); services.now = () => now;
  services.mutations = createMutationService(services, key);
  services.auth = createAccessService(services, hooks);
  services.events = createEventService(services);
  const workspace = services.resource('workspace', { name: 'Workspace', ownerUserId: 'owner', enabled: true, timezone: 'UTC' });
  store.put('workspaces', workspace); store.setMetadata('workspaceId', workspace.id);
  function addUser(userId: string, role: P.Role = 'member') {
    const user: P.User = { ...services.resource('user', { email: `${userId}@example.com`, displayName: userId, avatarAttachmentId: null, preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false }, notifications: { enabled: true, sound: true, previews: true, completed: true, needsInput: true } }), id: userId };
    store.put('users', user); store.put('members', services.resource('member', { userId, email: user.email, displayName: user.displayName, role, enabled: true }));
    const principal: Principal = { kind: 'user', id: userId, userId, workspaceId: workspace.id, role, sessionId: null, deviceId: null, botId: null };
    return principal;
  }
  function addBot(ownerUserId: string, visibility: P.Bot['visibility'] = 'personal', published = false): P.Bot {
    const bot: P.Bot = services.resource('bot', { ownerUserId, managerUserIds: [], machineId: 'machine', profileId: `lb-${opaqueToken()}`, name: 'Bot', title: '', job: '', instructions: '', avatar: { kind: 'character', shape: 'circle', color: '#112233', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, visibility, published, required: false, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'main', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] });
    return store.put('bots', bot);
  }
  function addConversation(bot: P.Bot, ownerUserId: string, kind: P.ConversationKind = 'dm'): P.Conversation {
    return store.put('conversations', services.resource('conversation', { kind, name: 'Private', botIds: [bot.id], humanUserIds: [ownerUserId], ownerUserId, parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 99, lastReadSeq: 99, activity: [] }));
  }
  const owner = addUser('owner', 'owner'); const alice = addUser('alice'); const admin = addUser('admin', 'admin');
  return { services, store, owner, alice, admin, workspace, cancelled, addUser, addBot, addConversation, advance: (amount: number) => { now += amount; } };
}
export function routeContext(services: BackendServices, route: Route, body: unknown, user: Principal | null, params: Record<string, string> = {}, query = new URLSearchParams()): RequestContext {
  return { services, route, body, user, params, query, request: new Request(`https://lemon.example${route.path.replace(/:id/g, params.id ?? 'target')}`, { method: route.method }), requestId: services.id('request'), nonceResourceIds: [] };
}
const bearer = (token: string) => new Request('https://lemon.example/v1/me', { headers: { authorization: `Bearer ${token}` } });

describe('access authority boundaries', () => {
  test('opaque session digest, thirty-day expiry and token-kind separation', async () => {
    const f = authFixture(); const auth = await f.services.auth.session(f.alice.userId);
    expect(auth.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(f.store.get('sessionSecrets', auth.session.id)).toEqual({ id: auth.session.id, tokenDigest: f.services.mutations.digest(auth.token), revoked: false });
    expect(auth.session.expiresAtMs - f.services.now()).toBe(30 * 86400000);
    expect((await f.services.auth.authenticate(bearer(auth.token), 'member'))?.kind).toBe('user');
    for (const policy of ['bot', 'hook', 'integration'] as const) await expect(f.services.auth.authenticate(bearer(auth.token), policy)).rejects.toMatchObject({ code: 'unauthenticated' });
    const bot = f.addBot('alice'); const botToken = opaqueToken(); f.store.put('botTokens', { id: bot.id, botId: bot.id, tokenDigest: f.services.mutations.digest(botToken), revoked: false });
    expect((await f.services.auth.authenticate(bearer(botToken), 'bot'))?.botId).toBe(bot.id);
    await expect(f.services.auth.authenticate(bearer(botToken), 'member')).rejects.toMatchObject({ code: 'unauthenticated' });
    f.advance(30 * 86400000);
    await expect(f.services.auth.authenticate(bearer(auth.token), 'member')).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('hook and integration credentials cannot become product sessions', async () => {
    const f = authFixture(); const bot = f.addBot('alice'); const key = opaqueToken();
    const routine: P.Routine = f.services.resource('routine', { botId: bot.id, ownerUserId: 'alice', name: 'Hook', instruction: 'Work', trigger: { kind: 'webhook' }, enabled: true, nextRunAtMs: null, scheduleDescription: 'Webhook', lastRunId: null, webhookUrl: null, cronJobId: null });
    f.store.put('routines', routine); f.store.setMetadata(`routineKey:${routine.id}`, { id: 'key', digest: tokenSha256(key) });
    expect((await f.services.auth.authenticate(bearer(key), 'hook'))?.kind).toBe('hook');
    await expect(f.services.auth.authenticate(bearer(key), 'member')).rejects.toMatchObject({ code: 'unauthenticated' });
    const token = opaqueToken(); const integration: P.IntegrationToken = f.services.resource('integration', { name: 'SCIM', kind: 'scim', scopes: ['scim.users'], expiresAtMs: null }); f.store.put('integrationTokens', integration);
    f.store.put('integrationCredentials', { id: integration.id, digest: tokenSha256(token), workspaceId: f.workspace.id, issuerUserId: 'owner' });
    expect((await f.services.auth.authenticate(bearer(token), 'integration'))?.scopes).toEqual(['scim.users']);
    await expect(f.services.auth.authenticate(bearer(token), 'member')).rejects.toMatchObject({ code: 'unauthenticated' });
    f.store.setMetadata(`routineKey:${routine.id}`, null);
    await expect(f.services.auth.authenticate(bearer(key), 'hook')).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('roles are reloaded rather than trusted from a stale principal', async () => {
    const f = authFixture(); const auth = await f.services.auth.session('admin'); const member = f.services.auth.member('admin');
    f.store.put('members', f.services.update(member, { role: 'member' }));
    expect(() => f.services.auth.requireRole(f.admin, 'admin')).toThrow(ApiError);
    await expect(f.services.auth.authenticate(bearer(auth.token), 'admin')).rejects.toMatchObject({ code: 'forbidden' });
    f.store.put('members', f.services.update(member, { enabled: false }));
    await expect(f.services.auth.authenticate(bearer(auth.token), 'member')).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('owner and admin do not acquire private bot, Team DM, note or entry content', () => {
    const f = authFixture(); const personal = f.addBot('alice'); const team = f.addBot('alice', 'team', true); const privateRoom = f.addConversation(team, 'alice', 'team_dm');
    for (const viewer of [f.owner, f.admin]) {
      expect(() => f.services.auth.bot(viewer, personal.id)).toThrow(ApiError);
      expect(() => f.services.auth.conversation(viewer, privateRoom.id)).toThrow(ApiError);
      expect(f.services.auth.canRead(viewer, 'memories', { id: 'note', botId: team.id, scope: 'private_note', userId: 'alice' })).toBe(false);
      expect(f.services.auth.canRead(viewer, 'entries', { id: 'entry', conversationId: privateRoom.id, targetedUserId: null })).toBe(false);
      expect(f.services.auth.bot(viewer, team.id).id).toBe(team.id);
    }
    expect(f.services.auth.canRead(f.alice, 'memories', { id: 'note', botId: team.id, scope: 'private_note', userId: 'alice' })).toBe(true);
    f.store.put('bots', f.services.update(team, { published: false, managerUserIds: ['admin'] }));
    expect(() => f.services.auth.bot(f.owner, team.id)).toThrow(ApiError);
    expect(f.services.auth.bot(f.admin, team.id, true).id).toBe(team.id);
    expect(() => f.services.auth.conversation(f.admin, privateRoom.id)).toThrow(ApiError);
  });
  test('sidebar and read projections are viewer-private and replay filters agree', () => {
    const f = authFixture(); const team = f.addBot('alice', 'team', true); const group = f.addConversation(team, 'alice', 'group'); f.store.put('conversations', { ...group, humanUserIds: ['alice', 'admin'] });
    f.store.setMetadata(`botSidebar:alice:${team.id}`, { ...team.sidebar, hidden: true });
    f.store.setMetadata(`conversationRead:alice:${group.id}`, { throughSeq: 12, unread: true });
    expect(f.services.auth.bot(f.alice, team.id).sidebar.hidden).toBe(true); expect(f.services.auth.bot(f.admin, team.id).sidebar.hidden).toBe(false);
    expect(f.services.auth.conversation(f.alice, group.id).lastReadSeq).toBe(12); expect(f.services.auth.conversation(f.admin, group.id).lastReadSeq).toBe(0);
    const note: P.Memory = f.services.resource('memory', { botId: team.id, scope: 'private_note', userId: 'alice', text: 'private', kind: 'fact', sourceEntryId: null });
    f.store.put('memories', note); f.services.events.emit('memory.upserted', note, { botId: team.id, userIds: ['alice'] });
    expect(f.services.events.replay(f.alice, '0').filter(event => event.event === 'memory.upserted')).toHaveLength(1); expect(f.services.events.replay(f.admin, '0').filter(event => event.event === 'memory.upserted')).toHaveLength(0);
    const aliceDM = f.services.auth.bot(f.alice, team.id).mainConversationId;
    const adminDM = f.services.auth.bot(f.admin, team.id).mainConversationId;
    expect(adminDM).not.toBe(aliceDM); expect(() => f.services.auth.conversation(f.admin, aliceDM)).toThrow(ApiError);
  });
  test('machine read does not imply management and admin authority must be configured', () => {
    const f = authFixture(); const machine: P.Machine = f.services.resource('machine', { nodeId: 'node', nodeName: 'node', name: 'Host', ownerUserId: 'alice', accessUserIds: ['admin'], status: 'online', lastSeenAtMs: f.services.now(), labels: {}, botIds: [] }); f.store.put('machines', machine);
    expect(f.services.auth.machine(f.admin, machine.id).id).toBe(machine.id);
    expect(() => f.services.auth.machine(f.admin, machine.id, true)).toThrow(ApiError);
    f.services.config.operator.machineManagementUserIds = ['admin'];
    expect(f.services.auth.machine(f.admin, machine.id, true).id).toBe(machine.id);
    expect(f.services.auth.machine(f.owner, machine.id, true).id).toBe(machine.id);
  });
  test('revocation removes session authority, disables delivery and notifies lifecycle hooks', async () => {
    const revoked: string[] = []; const f = authFixture({ onRevokeUser: userId => { revoked.push(userId); } });
    const device: P.Device = f.services.resource('device', { userId: 'alice', platform: 'ios', name: 'Phone', appVersion: '1', pushEnabled: true, lastSeenAtMs: f.services.now() }); f.store.put('devices', device); f.store.setMetadata(`devicePush:${device.id}`, f.services.encrypt({ token: 'not-real-push' }));
    f.store.setMetadata(`devicePushRegisteredAt:${device.id}`, f.services.now());
    const auth = await f.services.auth.session('alice', device.id); await f.services.auth.revokeUser('alice');
    expect(f.store.get('authSessions', auth.session.id)).toBeNull(); expect(f.store.get('sessionSecrets', auth.session.id)).toMatchObject({ revoked: true });
    expect(f.store.get('devices', device.id)).toMatchObject({ pushEnabled: false }); expect(f.store.metadata(`devicePush:${device.id}`)).toBeNull();
    expect(f.store.metadata(`devicePushRegisteredAt:${device.id}`)).toBeNull();
    expect(f.cancelled).toEqual(['alice']); expect(revoked).toEqual(['alice']); await expect(f.services.auth.authenticate(bearer(auth.token))).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('reauth is user-bound, single-use, digest-only and expires in five minutes', () => {
    const f = authFixture(); const result = f.services.auth.issueReauth('alice');
    expect(result.expiresAtMs - f.services.now()).toBe(300000); expect(f.store.get('reauthTokens', result.reauthToken)).toBeNull();
    expect(() => f.services.auth.consumeReauth('admin', result.reauthToken)).toThrow(ApiError);
    f.services.auth.consumeReauth('alice', result.reauthToken); expect(() => f.services.auth.consumeReauth('alice', result.reauthToken)).toThrow(ApiError);
    const expired = f.services.auth.issueReauth('alice'); f.advance(300000); expect(() => f.services.auth.consumeReauth('alice', expired.reauthToken)).toThrow(ApiError);
  });
  test('audit export bearer has exactly the metadata audit exception and is revocable', async () => {
    const f = authFixture(); const token = opaqueToken();
    const integration: P.IntegrationToken = f.services.resource('integration', { name: 'Export', kind: 'audit_export', scopes: ['audit_export'], expiresAtMs: null });
    f.store.put('integrationTokens', integration); f.store.put('integrationCredentials', { id: integration.id, digest: tokenSha256(token), workspaceId: f.workspace.id, issuerUserId: 'owner' });
    const request = new Request('https://lemon.example/v1/audit', { headers: { authorization: `Bearer ${token}` } });
    expect((await f.services.auth.authenticate(request, 'optional'))?.kind).toBe('integration');
    await expect(f.services.auth.authenticate(bearer(token), 'optional')).rejects.toMatchObject({ code: 'unauthenticated' });
    await expect(f.services.auth.authenticate(request, 'admin')).rejects.toMatchObject({ code: 'unauthenticated' });
    f.store.remove('integrationCredentials', integration.id);
    await expect(f.services.auth.authenticate(request, 'optional')).rejects.toMatchObject({ code: 'unauthenticated' });
  });
  test('live directory access denial blocks existing sessions and resources without denying Owner repair', async () => {
    const f = authFixture(); const auth = await f.services.auth.session('alice'); const bot = f.addBot('alice');
    const ownerBot = f.addBot('owner');
    f.store.setMetadata('governance', { ...defaultGovernance, groupAccess: 'selected', allowedDirectoryGroupIds: [] });
    await expect(f.services.auth.authenticate(bearer(auth.token))).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.services.auth.canRead(f.alice, 'bots', bot)).toBe(false);
    expect(() => f.services.auth.requireRole(f.owner, 'owner')).not.toThrow();
    expect(() => f.services.auth.bot(f.owner, ownerBot.id)).toThrow(ApiError);
  });
  test('trusted hook snapshots inherit own ACL but never acquire Owner administrative or host shortcuts', () => {
    const f = authFixture(); const bot = f.addBot('owner');
    const hook: Principal = { ...f.owner, kind: 'hook', id: 'verified-key', botId: bot.id };
    expect(f.services.auth.bot(hook, bot.id).id).toBe(bot.id);
    expect(() => f.services.auth.requireRole(hook, 'owner')).toThrow(ApiError);
    const machine: P.Machine = f.services.resource('machine', { nodeId: 'node', nodeName: 'node', name: 'Host', ownerUserId: 'alice', accessUserIds: [], status: 'online', lastSeenAtMs: f.services.now(), labels: {}, botIds: [] }); f.store.put('machines', machine);
    expect(() => f.services.auth.machine(hook, machine.id)).toThrow(ApiError);
  });
  test('explicit attachment room shares require current participation and do not grant private bot access', () => {
    const f = authFixture(); const team = f.addBot('alice', 'team', true); const room = f.addConversation(team, 'alice', 'group'); f.store.put('conversations', { ...room, humanUserIds: ['alice', 'admin'] });
    const attachment: P.Attachment = f.services.resource('attachment', { ownerUserId: 'alice', conversationId: null, botId: null, filename: 'shared.txt', mime: 'text/plain', size: 1, sha256: 'a'.repeat(64), width: null, height: null, durationMs: null, source: 'upload', state: 'ready', preview: 'text', provenance: { botId: null, runId: null, machineId: null, sourceEntryId: null, generatedAtMs: null } }); f.store.put('attachments', attachment);
    expect(f.services.auth.canRead(f.admin, 'attachments', attachment)).toBe(false);
    f.store.put('attachmentShares', f.services.resource('share', { attachmentId: attachment.id, conversationId: room.id, userId: 'alice' }));
    expect(f.services.auth.canRead(f.admin, 'attachments', attachment)).toBe(true);
    f.store.put('conversations', { ...room, humanUserIds: ['alice'] });
    expect(f.services.auth.canRead(f.admin, 'attachments', attachment)).toBe(false);
  });
});
