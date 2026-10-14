import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { installHelpers } from '../../src/core/helpers';
import { createAccessService } from '../../src/core/auth';
import { createEventService } from '../../src/core/events';
import { createMutationService } from '../../src/core/mutations';

/** Actual SQLite, access, confirmation, resource, transcript and event services; no runtime/provider invocation. */
export async function mediaFixture() {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-media-'));
  const store = new Store(join(directory, 'test.sqlite'));
  const services = { store, config: { publicUrl: 'https://product.example', dataDir: directory }, integrations: {} } as unknown as BackendServices;
  installHelpers(services);
  let clock = Date.now();
  services.now = () => clock;
  services.encrypt = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  services.decrypt = <T>(value: string) => JSON.parse(Buffer.from(value, 'base64url').toString()) as T;
  services.mutations = createMutationService(services, new Uint8Array(32).fill(7));
  services.auth = createAccessService(services);
  services.events = createEventService(services);
  const workspace = services.resource('workspace', { name: 'Workspace', ownerUserId: 'user_1', enabled: true, timezone: 'UTC' });
  store.put('workspaces', workspace); store.setMetadata('workspaceId', workspace.id);
  const voice = { voiceId: 'default', speed: 1, language: null };
  const preferences: P.Preferences = { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice, celebrationsEnabled: false };
  for (const userId of ['user_1', 'user_2']) {
    store.put('users', { ...services.resource('user', { email: `${userId}@example.org`, displayName: userId, avatarAttachmentId: null, preferences, notifications: { enabled: true, sound: false, previews: false, completed: true, needsInput: true } }), id: userId });
    store.put('members', services.resource('member', { userId, displayName: userId, email: `${userId}@example.org`, role: 'member', enabled: true }));
  }
  const user: Principal = { kind: 'user', id: 'user_1', userId: 'user_1', workspaceId: workspace.id, role: 'member', sessionId: 'auth_1', botId: null, deviceId: 'device_1' };
  const other: Principal = { ...user, id: 'user_2', userId: 'user_2', sessionId: 'auth_2', deviceId: 'device_2' };
  for (const actor of [user, other]) {
    store.put('authSessions', { id: actor.sessionId!, userId: actor.userId, expiresAtMs: clock + 86400000 });
    store.put('sessionSecrets', { id: actor.sessionId!, revoked: false, tokenDigest: 'test-only' });
    store.put('devices', { ...services.resource('device', { userId: actor.userId, platform: 'web', name: 'Browser', appVersion: '1', pushEnabled: false, lastSeenAtMs: clock }), id: actor.deviceId! });
  }
  const bot: P.Bot = services.resource('bot', { ownerUserId: user.userId, machineId: 'machine_1', profileId: 'lb-test', name: 'Bot', title: '', job: '', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice, language: null, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'conversation_1', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'idle', activeRunIds: [] });
  store.put('bots', bot);
  const conversation: P.Conversation = { ...services.resource('conversation', { kind: 'dm', name: 'Main', botIds: [bot.id], ownerUserId: user.userId, parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] }), id: 'conversation_1' };
  store.put('conversations', conversation);
  const context = (route: Route, body: unknown, actor: Principal | null = user, params: Record<string, string> = {}): RequestContext => ({ request: new Request(`https://product.example${route.path.replace(':id', params.id ?? '').replace(':ticket', params.ticket ?? '')}`, { method: route.method }), params, query: new URLSearchParams(), body, user: actor, services, requestId: 'request_test', route, nonceResourceIds: [] });
  return { services, store, user, other, bot, conversation, directory, context, advance(ms: number) { clock += ms; }, async close() { store.close(); await rm(directory, { recursive: true, force: true }); } };
}
