import { afterEach, describe, expect, test } from 'bun:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type * as P from '../../../contracts/protocol';
import { createBackend } from '../../src/index';
import { loadConfiguration } from '../../src/core/config';
import { nativeFollowupAdmissionPath } from '../../src/core/bot-lifecycle';

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => { for (const close of cleanups.splice(0)) await close(); });

/** Real backend, SQLite, routes, authentication and runtime reconciliation; only the controller is supplied. */
async function fixture() {
  const directory = await mkdtemp(join(tmpdir(), 'lemon-bot-lifecycle-projection-'));
  const configuration = await loadConfiguration({
    LEMON_BOT_DATA_DIR: directory,
    LEMON_BOT_PUBLIC_URL: 'https://lemon.example',
    LEMON_BOT_OPERATOR_TOKEN: 'test-controller-operator',
    LEMON_BOT_CONTROL_URL: 'ws://127.0.0.1:1/ws',
  });
  const backend = await createBackend(configuration.config, configuration.key);
  cleanups.push(async () => { await backend.stop(); await rm(directory, { recursive: true, force: true }); });
  const { services, router } = backend, { store } = services;
  const controllerCalls: string[] = [];
  services.lemon = {
    ...services.lemon, connected: true, methods: [],
    async call<T>(method: string): Promise<T> {
      controllerCalls.push(method);
      if (method !== 'nodes.list') throw new Error(`Unexpected controller call: ${method}`);
      return { nodes: [], summary: { presenceAvailable: true, truncated: false } } as T;
    },
  };
  const workspace = store.put('workspaces', services.resource('workspace', { name: 'Workspace', ownerUserId: 'alice', enabled: true, timezone: 'UTC' }));
  store.setMetadata('workspaceId', workspace.id);
  for (const [userId, role] of [['alice', 'owner'], ['admin', 'admin']] as const) {
    const user: P.User = { ...services.resource('user', { email: `${userId}@example.com`, displayName: userId, avatarAttachmentId: null, preferences: { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false }, notifications: { enabled: true, sound: true, previews: true, completed: true, needsInput: true } }), id: userId };
    store.put('users', user);
    store.put('members', services.resource('member', { userId, email: user.email, displayName: user.displayName, role, enabled: true }));
  }
  const machine: P.Machine = { ...services.resource('machine', { nodeId: 'node', nodeName: 'worker', name: 'Offline worker', ownerUserId: 'alice', accessUserIds: [], status: 'offline', lastSeenAtMs: null, labels: {}, botIds: [] }), credential: 'unknown' };
  store.put('machines', machine);
  store.put('machineCapabilities', { id: machine.id, machineId: machine.id, os: 'darwin', measuredAtMs: services.now(), stale: true, items: [] } satisfies P.MachineCapabilities & { id: string });
  const ownerSession = await services.auth.session('alice'), adminSession = await services.auth.session('admin');
  function addBot() {
    const bot: P.Bot = services.resource('bot', { ownerUserId: 'alice', machineId: machine.id, profileId: services.id('profile'), name: 'Private Bot', title: '', job: '', instructions: 'Private instructions', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, language: null, skillIds: [], referenceAttachmentIds: [], mainConversationId: services.id('conversation'), sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: true }, activity: 'offline', activeRunIds: ['private-run'] });
    // Legacy sharing labels, raw secrets and an old projection must never cross the explicit auth DTO.
    store.put('bots', { ...bot, visibility: 'team', published: true, managerUserIds: ['admin'], encryptedToken: 'private-token', lifecycle: { action: 'obsolete', status: 'running' } });
    return bot;
  }
  const get = (path: string, token = ownerSession.token) => router.fetch(new Request(`${services.config.publicUrl}${path}`, { headers: { Authorization: `Bearer ${token}` } }));
  async function views(botId: string) {
    const syncResponse = await get('/v1/sync');
    expect(syncResponse.status).toBe(200);
    const snapshot = await syncResponse.json() as P.Snapshot;
    const overviewResponse = await get(`/v1/bots/${botId}/overview`);
    expect(overviewResponse.status).toBe(200);
    const overview = await overviewResponse.json() as P.BotOverview;
    const synced = snapshot.bots.find(bot => bot.id === botId);
    if (!synced) throw new Error('Owner sync omitted the Bot.');
    return [synced, overview.bot];
  }
  return { services, store, addBot, get, views, adminToken: adminSession.token, controllerCalls };
}

function expectPrivateProjection(bot: P.Bot) {
  expect(bot.activeRunIds).toEqual([]);
  for (const field of ['visibility', 'published', 'managerUserIds', 'encryptedToken']) expect(Object.hasOwn(bot, field)).toBe(false);
}

describe('production Bot lifecycle projections', () => {
  for (const action of ['create', 'import'] as const) test(`sync and overview expose persisted failed ${action} recovery only to its owner`, async () => {
    const f = await fixture(), bot = f.addBot();
    const fence = { id: 'lifecycle', action, userId: 'alice', revision: bot.revision, status: 'failed', resourceIds: [bot.id], step: 'Configure admission', message: 'The controller rejected callback configuration.' };
    f.store.setMetadata(`botLifecycle:${bot.id}`, fence);
    for (const projected of await f.views(bot.id)) {
      expect(projected.lifecycle).toEqual({ action, status: 'failed', step: fence.step, message: fence.message, canFinishSetup: true, canReaddress: false, canDelete: true });
      expectPrivateProjection(projected);
    }
    const adminSync = await f.get('/v1/sync', f.adminToken);
    expect(adminSync.status).toBe(200);
    expect((await adminSync.json() as P.Snapshot).bots).toEqual([]);
    const adminOverview = await f.get(`/v1/bots/${bot.id}/overview`, f.adminToken);
    expect(adminOverview.status).toBe(404);
    expect(await adminOverview.text()).not.toContain(fence.message);
    const unauthenticated = await f.get('/v1/sync', 'not-a-session');
    expect(unauthenticated.status).toBe(401);
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).toEqual(fence);
    expect(f.controllerCalls.every(method => method === 'nodes.list')).toBe(true);
  });

  test('sync and overview derive stale callback recovery from private persisted address metadata', async () => {
    const f = await fixture(), bot = f.addBot();
    const issuer = { botId: bot.id, profileId: bot.profileId, url: `https://old.example${nativeFollowupAdmissionPath}`, digest: 'private-digest', encryptedToken: 'private-issuer-token', state: 'configured' };
    f.store.setMetadata(`nativeFollowupIssuerConfig:${bot.id}`, issuer);
    for (const projected of await f.views(bot.id)) {
      expect(projected.lifecycle).toMatchObject({ action: 'readdress', status: 'failed', step: 'Update callback address', canFinishSetup: false, canReaddress: true, canDelete: true });
      expect(projected.lifecycle?.message).toContain('from https://old.example to https://lemon.example');
      expect(projected.lifecycle?.message).toContain('LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS');
      expect(JSON.stringify(projected)).not.toContain(issuer.digest);
      expect(JSON.stringify(projected)).not.toContain(issuer.encryptedToken);
      expectPrivateProjection(projected);
    }
    const adminSync = await f.get('/v1/sync', f.adminToken);
    expect(adminSync.status).toBe(200);
    expect((await adminSync.json() as P.Snapshot).bots).toEqual([]);
    const adminOverview = await f.get(`/v1/bots/${bot.id}/overview`, f.adminToken);
    expect(adminOverview.status).toBe(404);
    expect(await adminOverview.text()).not.toContain('old.example');
    expect(f.store.metadata(`nativeFollowupIssuerConfig:${bot.id}`)).toEqual(issuer);
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).toBeNull();
    f.store.setMetadata(`nativeFollowupIssuerConfig:${bot.id}`, { ...issuer, url: `https://lemon.example${nativeFollowupAdmissionPath}` });
    for (const projected of await f.views(bot.id)) expect(Object.hasOwn(projected, 'lifecycle')).toBe(false);
  });

  test('recovery permissions follow retained fence status without reclassifying persisted running work', async () => {
    const f = await fixture(), bot = f.addBot();
    const cases = [
      ['create', 'running', false, false, false], ['import', 'running', false, false, false],
      ['create', 'outcome_unknown', true, false, true], ['import', 'outcome_unknown', true, false, true],
      ['delete', 'failed', false, false, true], ['delete', 'outcome_unknown', false, false, false],
      ['readdress', 'running', false, false, false], ['readdress', 'failed', false, true, true],
      ['readdress', 'outcome_unknown', false, true, true], ['update', 'failed', false, false, false],
      ['move', 'failed', false, false, false],
    ] as const;
    for (const [action, status, canFinishSetup, canReaddress, canDelete] of cases) {
      const fence = { id: 'lifecycle', action, userId: 'alice', revision: bot.revision, status, resourceIds: [bot.id] };
      f.store.setMetadata(`botLifecycle:${bot.id}`, fence);
      for (const projected of await f.views(bot.id)) expect(projected.lifecycle).toMatchObject({ action, status, canFinishSetup, canReaddress, canDelete });
      expect(f.store.metadata(`botLifecycle:${bot.id}`)).toEqual(fence);
    }
    f.store.setMetadata(`botLifecycle:${bot.id}`, { id: 'lifecycle', action: 'create', status: 'failed', resourceIds: [bot.id] });
    f.store.setMetadata(`botReaddressTarget:${bot.id}`, 'https://lemon.example');
    f.store.setMetadata(`botReaddressNotice:${bot.id}`, 'Callback updated; finish the profile cutover.');
    f.store.setMetadata(`botSetup:${bot.id}`, { steps: { 'Update callback address': 'acknowledged', 'Update Bot address': 'pending', 'Sync updated address': 'pending' } });
    for (const projected of await f.views(bot.id)) {
      expect(projected.lifecycle).toMatchObject({ action: 'create', status: 'failed', canFinishSetup: true, canReaddress: true, canDelete: true });
      expect(projected.lifecycle?.message).toContain('Callback updated; finish the profile cutover.');
    }
  });
});
