import { describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { Principal, Route } from '../../src/core/services';
import { ApiError } from '../../src/core/errors';
import { createBotRoutes, baseBotMcpConfig, syncBotProfile, createBotService, syncBotPolicyFloor } from '../../src/core/bots';
import { createConversationRoutes } from '../../src/core/conversations';
import { createResourceRoutes } from '../../src/core/resources';
import { authFixture, routeContext } from './auth.test';

interface Call { method: string; params: Record<string, unknown> }
function fixture() {
  const f = authFixture();
  f.services.config.publicUrl = 'https://lemon.example';
  const calls: Call[] = [];
  const profileRows = new Map<string, Record<string, unknown>>();
  let reject: ((method: string, params: Record<string, unknown>) => void) | null = null;
  let nativePresence: { active: number; queued: number; unknown: number; idle: boolean; complete: boolean } | null = { active: 0, queued: 0, unknown: 0, idle: true, complete: true };
  const methods = ['profiles.create', 'profiles.update', 'profiles.get', 'profiles.sync', 'profiles.sync.status', 'profiles.delete', 'profile.followup.admission.set', 'runs.followup.lineage.get', 'runs.active.list', 'memory.transfer', 'memory.transfer.status', 'memory.list', 'memory.delete', 'memory.add', 'nodes.list', 'node.capabilities.get', 'node.secrets.set', 'node.secrets.receipt', 'node.secrets.delete', 'node.host.info', 'node.profile.paths', 'node.fs.write', 'node.fs.delete', 'cron.pause', 'cron.resume', 'cron.add', 'cron.remove', 'sessions.delete'];
  f.services.lemon = {
    connected: true, methods,
    async call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
      calls.push({ method, params }); reject?.(method, params);
      let value: unknown;
      if (method === 'profiles.create' || method === 'profiles.update') {
        const profileId = String(params.id);
        const profile: Record<string, unknown> = { canonicalSessionKey: `agent:${profileId}:main`, ...profileRows.get(profileId), ...params };
        const definitions = profile.mcpServers as { name: string; url: string; headers: Record<string, string>; enabledTools?: string[]; allowedOrigins?: string[]; approvedPrivateOrigins?: string[] }[] | undefined;
        const canonical = (definitions ?? []).map(server => [server.name, server.url, Object.entries(server.headers).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0), server.enabledTools ?? null, server.allowedOrigins ?? null, server.approvedPrivateOrigins ?? null]);
        const acknowledged = { ...profile, mcpConfigFingerprint: createHash('sha256').update(JSON.stringify(canonical)).digest('hex') };
        profileRows.set(profileId, acknowledged); value = { profile: acknowledged };
      } else if (method === 'profiles.get') {
        const profile = profileRows.get(String(params.id));
        if (!profile) throw new ApiError('not_found', 'Profile absent.');
        const definitions = profile.mcpServers as { name: string; url: string; headers: Record<string, string>; enabledTools?: string[]; allowedOrigins?: string[]; approvedPrivateOrigins?: string[] }[] | undefined;
        const canonical = (definitions ?? []).map(server => [server.name, server.url, Object.entries(server.headers).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0), server.enabledTools ?? null, server.allowedOrigins ?? null, server.approvedPrivateOrigins ?? null]);
        value = { profile: { ...profile, mcpConfigFingerprint: createHash('sha256').update(JSON.stringify(canonical)).digest('hex') } };
      }
      else if (method === 'profiles.sync') value = { profileId: params.id, nodeId: params.nodeId, mutationId: params.mutationId, acknowledged: true, revisionDigest: 'a'.repeat(64) };
      else if (method === 'profiles.sync.status') value = { profileId: params.id, nodeId: params.nodeId, mutationId: params.mutationId, status: 'acknowledged', acknowledged: true, revisionDigest: 'a'.repeat(64) };
      else if (method === 'profile.followup.admission.set') value = { profileId: params.profileId, configured: true };
      else if (method === 'node.secrets.set') value = { name: params.name, set: true, operationId: params.operationId, status: 'applied', currentBindingMatches: true };
      else if (method === 'node.secrets.delete') value = { name: params.name, deleted: true };
      else if (method === 'runs.active.list') value = { runs: [], filters: { profileId: params.profileId, limit: params.limit }, ...(nativePresence ? { presence: nativePresence } : {}) };
      else if (method === 'node.profile.paths') value = { nodeId: params.nodeId, profileId: params.profileId, workspacePath: `/worker/profiles/${params.profileId}/workspace`, skillsPath: `/worker/profiles/${params.profileId}/workspace/.lemon/skill` };
      else if (method === 'nodes.list') value = { nodes: f.store.list<P.Machine>('machines').map(machine => ({ id: machine.nodeId, status: machine.status, capabilities: [] })), summary: { presenceAvailable: true } };
      else if (method === 'node.capabilities.get') value = { nodeId: params.nodeId, os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [] };
      else if (method === 'node.host.info') value = { defaultCwd: '/home/lemon' };
      else if (method === 'node.fs.write') { const size = Buffer.from(String(params.dataBase64), 'base64').length; value = { path: params.path, bytesWritten: size, size }; }
      else if (method === 'node.fs.delete') value = { path: params.path, deleted: true };
      else if (method === 'memory.transfer') {
        const identity = { profileId: params.profileId, nodeId: params.nodeId, mutationId: params.mutationId, sourceNodeId: 'node-source', snapshotDigest: 'b'.repeat(64) };
        value = params.action === 'preview' ? { ...identity, destinationDigest: 'c'.repeat(64), confirmationToken: 'memory-confirmation-test', sourceCounts: { documents: 2, preferences: 2 }, destinationCounts: { documents: 3, preferences: 1 }, overwrite: true } : { ...identity, copied: true };
      } else if (method === 'memory.list') value = { items: [], nextCursor: null };
      else if (method === 'memory.delete') value = { id: params.id, deleted: true };
      else if (method === 'cron.pause') value = { id: params.id, paused: true, enabled: false, nextRunAtMs: null };
      else if (method === 'cron.resume') value = { id: params.id, resumed: true, enabled: true, nextRunAtMs: f.services.now() + 3600000 };
      else if (method === 'cron.remove') value = { id: params.id, removed: true };
      else if (method === 'sessions.delete') value = { sessionKey: params.sessionKey, deleted: true, summary: { verified: true } };
      else if (method === 'profiles.delete') { profileRows.delete(String(params.id)); value = { deleted: { id: params.id } }; }
      else throw new Error(`Unexpected external method in bot lifecycle test: ${method}`);
      return value as T;
    },
    onEvent: () => () => {}, onConnected: () => () => {}, start() {}, close() {},
  };
  const unavailable = (): never => { throw new Error('This test did not supply the requested external operation.'); };
  f.services.runtime = { submit: unavailable, send: unavailable, cancel: unavailable, reconcile: unavailable, revokeConnectorInvocations: unavailable, sessionKey: (room, bot) => room.kind === 'team_dm' ? `agent:${bot.profileId}:dm-${room.ownerUserId}` : `agent:${bot.profileId}:main` };
  f.services.integrations.connectorConfig = async () => [];
  f.services.integrations.connectorTemplates = async () => [];
  f.services.integrations.effectivePolicy = async (actor, botId) => ({ userId: actor.userId, botId: botId ?? null, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] });
  f.services.integrations.sharedProfilePolicy = botId => f.services.integrations.effectivePolicy(f.alice, botId);
  f.services.integrations.emitProviderNotifications = async () => {};
  f.services.syncBotProfile = (actor, botId) => syncBotProfile(f.services, actor, botId);
  const routes: Route[] = [...createBotRoutes(f.services), ...createConversationRoutes(f.services), ...createResourceRoutes(f.services)];
  function context(method: string, path: string, body: unknown, actor: Principal | null) {
    const requested = new URL(path, 'https://lemon.example');
    const route = routes.find(route => route.method === method && new RegExp(`^${route.path.replace(/:[A-Za-z]+/g, '[^/]+')}$`).test(requested.pathname));
    if (!route) throw new Error('The requested resource operation is not registered.');
    const params: Record<string, string> = {};
    const parts = requested.pathname.split('/');
    route.path.split('/').forEach((part, index) => { if (part.startsWith(':')) params[part.slice(1)] = decodeURIComponent(parts[index]!); });
    const c = routeContext(f.services, route, body, actor, params, requested.searchParams);
    c.request = new Request(requested, { method });
    return c;
  }
  f.services.invoke = async <T>(actor: Principal, method: string, path: string, body?: unknown, options?: { botLifecycle: { botId: string; userId: string; action: string } }): Promise<T> => {
    const c = context(method, path, body, actor);
    if (options) c.internalBotLifecycle = options.botLifecycle;
    const result = method === 'GET' || c.route.mutation === false ? await c.route.handler(c) : await f.services.mutations.execute(c, () => c.route.handler(c));
    return result as T;
  };
  async function request<T>(method: string, path: string, body: unknown, actor: Principal | null = f.alice): Promise<T> {
    const c = context(method, path, body, actor);
    const result = method === 'GET' || c.route.mutation === false ? await c.route.handler(c) : await f.services.mutations.execute(c, () => c.route.handler(c));
    return result as T;
  }
  function machine(machineId: string, nodeId: string, shared = false): P.Machine {
    const labels: Record<string, string> = shared ? { 'lemon_bot.shared_context': 'true' } : {};
    const row: P.Machine = { ...f.services.resource('machine', { nodeId, nodeName: nodeId, name: machineId, ownerUserId: 'alice', accessUserIds: ['admin'], status: 'online' as const, lastSeenAtMs: f.services.now(), labels, botIds: [] }), id: machineId };
    return f.store.put('machines', row);
  }
  machine('machine', 'node-source'); machine('destination', 'node-destination', true);
  function bot(visibility: P.Bot['visibility'] = 'personal', published = false): P.Bot {
    const bot = f.addBot('alice', visibility, published);
    const room = f.addConversation(bot, 'alice', visibility === 'team' ? 'team_dm' : 'dm');
    const saved = { ...bot, profileId: `lb-${f.services.mutations.digest(bot.id).slice(0, 40)}`, mainConversationId: room.id }; f.store.put('bots', saved);
    const source = f.store.require<P.Machine>('machines', 'machine'); f.store.put('machines', { ...source, botIds: [...source.botIds, bot.id] });
    f.store.setMetadata(`botMcp:${bot.id}`, { secretName: 'test_bot_ref', encryptedToken: f.services.encrypt('unit-test-bot-token'), digest: f.services.mutations.digest('unit-test-bot-token') });
    profileRows.set(saved.profileId, { id: saved.profileId, node: 'node-source', canonicalSessionKey: `agent:${saved.profileId}:main` });
    f.store.setMetadata(`profileCanonicalSession:${saved.id}`, `agent:${saved.profileId}:main`);
    f.store.setMetadata(`botControllerFloor:${saved.id}`, { profile: 'custom', allow: 'all', deny: [], require_approval: [] });
    const issuerToken = 'existing-private-native-issuer-token';
    const digest = f.services.mutations.digest(issuerToken);
    f.store.setMetadata(`nativeFollowupIssuerConfig:${saved.id}`, { botId: saved.id, profileId: saved.profileId, url: 'https://lemon.example/internal/runtime/followup/admission', digest, encryptedToken: f.services.encrypt(issuerToken), state: 'configured' });
    f.store.setMetadata(`nativeFollowupIssuer:${digest}`, saved.id);
    return saved;
  }
  return { ...f, calls, request, machine, bot, fail: (value: typeof reject) => { reject = value; }, presence: (value: typeof nativePresence) => { nativePresence = value; } };
}
const nonce = (suffix: string) => `bot_test_nonce_${suffix}`;
function confirmed(confirmation: P.Confirmation, extra: Record<string, unknown> = {}) { return { clientNonce: nonce('confirm'), revision: confirmation.revision, confirmationToken: confirmation.confirmationToken, confirmName: confirmation.confirmName, ...extra }; }

describe('bot authority and viewer state', () => {
  test('workspace roles never read another member personal bot', async () => {
    const f = fixture(), bot = f.bot();
    for (const actor of [f.owner, f.admin]) await expect(f.request('GET', `/v1/bots/${bot.id}`, undefined, actor)).rejects.toMatchObject({ code: 'not_found' });
    const own = await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined);
    expect(own.mainConversationId).toBe(bot.mainConversationId); expect(f.calls).toHaveLength(0);
  });
  test('managers cannot publish, assign managers or change required status', async () => {
    const f = fixture(), source = f.bot('team'); const bot = { ...source, managerUserIds: ['admin'] }; f.store.put('bots', bot);
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('manager_publish'), revision: bot.revision, published: true }, f.admin)).rejects.toMatchObject({ code: 'forbidden' });
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('manager_assign'), revision: bot.revision, managerUserIds: [] }, f.admin)).rejects.toMatchObject({ code: 'forbidden' });
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('member_required'), revision: bot.revision, required: true })).rejects.toMatchObject({ code: 'forbidden' });
    expect(f.calls).toHaveLength(0);
  });
  test('publishing requires deliberate intended shared host, not owner ambient credentials', async () => {
    const f = fixture(), bot = f.bot('team');
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('unreviewed_host'), revision: bot.revision, published: true })).rejects.toMatchObject({ code: 'policy_denied' });
    f.machine('machine', 'node-source', true); f.bot('personal');
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('private_colocated'), revision: bot.revision, published: true })).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.calls).toHaveLength(0);
  });
  test('Team sidebar is per viewer, revisions conflict and required defaults cannot hide', async () => {
    const f = fixture(), bot = f.bot('team', true);
    const changed = await f.request<P.Bot>('PATCH', `/v1/bots/${bot.id}/sidebar`, { clientNonce: nonce('viewer_hide'), revision: bot.revision, hidden: true }, f.admin);
    expect(changed.sidebar.hidden).toBe(true); expect((await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).sidebar.hidden).toBe(false);
    await expect(f.request('PATCH', `/v1/bots/${bot.id}/sidebar`, { clientNonce: nonce('stale_sidebar'), revision: bot.revision, pinned: true })).rejects.toMatchObject({ code: 'revision_conflict' });
    f.services.integrations.defaultBotIds = async () => [bot.id];
    await expect(f.request('PATCH', `/v1/bots/${bot.id}/sidebar`, { clientNonce: nonce('required_sidebar'), revision: changed.revision, hidden: true }, f.admin)).rejects.toMatchObject({ code: 'policy_denied' });
  });
  test('stale updates and unknown fields fail before runtime effects', async () => {
    const f = fixture(), bot = f.bot();
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('stale_update'), revision: 99, name: 'Changed' })).rejects.toMatchObject({ code: 'revision_conflict' });
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('raw_credential'), revision: bot.revision, headers: { Authorization: 'not-permitted' } })).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.calls).toHaveLength(0); expect(f.store.require<P.Bot>('bots', bot.id).name).toBe(bot.name);
  });
});

describe('acknowledged bot provisioning and placement', () => {
  test('creation binds a per-bot host secret, stores digest/encrypted custody, and uses canonical conversation', async () => {
    const f = fixture();
    const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('new_bot'), name: 'Planner', machineId: 'machine', job: 'Plan work' });
    const secretCall = f.calls.find(call => call.method === 'node.secrets.set')!;
    const token = String(secretCall.params.value);
    expect(f.store.require<{ tokenDigest: string }>('botTokens', bot.id).tokenDigest).toBe(f.services.mutations.digest(token));
    const metadata = f.store.metadata<{ encryptedToken: string; digest: string }>(`botMcp:${bot.id}`)!;
    expect(metadata.encryptedToken).not.toContain(token); expect(f.services.decrypt(metadata.encryptedToken)).toBe(token);
    const profileCall = f.calls.find(call => call.method === 'profiles.create')!;
    expect(JSON.stringify(profileCall.params)).not.toContain(token);
    expect(profileCall.params.mcpServers).toEqual([{ ...baseBotMcpConfig(f.services, bot), headers: {} }]);
    expect(baseBotMcpConfig(f.services, bot).headers.Authorization).toBe(`Bearer \${LEMON_SECRET:${secretCall.params.name}}`);
    expect(baseBotMcpConfig(f.services, bot).allowedOrigins).toEqual(['https://lemon.example']);
    expect(baseBotMcpConfig(f.services, bot).approvedPrivateOrigins).toEqual([]);
    expect(f.store.require<P.Conversation>('conversations', bot.mainConversationId)).toMatchObject({ kind: 'dm', botIds: [bot.id], ownerUserId: 'alice' });
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).toBeNull();
  });
  test('unknown work is not idle and move preview dispatches nothing', async () => {
    const f = fixture(), bot = f.bot();
    const run: P.Run = f.services.resource('run', { conversationId: bot.mainConversationId, botId: bot.id, initiatorUserId: 'alice', clientNonce: nonce('run'), status: 'outcome_unknown', error: null, startedAtMs: null, completedAtMs: null, routineRunId: null }); f.store.put('runs', run);
    await expect(f.request('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('busy_preview'), action: 'move', targetMachineId: 'destination' })).rejects.toMatchObject({ code: 'conflict' });
    expect(f.calls).toHaveLength(0);
  });
  test('uncertain memory provisioning keeps old placement, pauses schedules and fences a new nonce', async () => {
    const f = fixture(), bot = f.bot();
    const routine: P.Routine = f.services.resource('routine', { botId: bot.id, ownerUserId: 'alice', name: 'Daily', instruction: 'Plan', trigger: { kind: 'schedule', cron: '0 9 * * *', timezone: 'UTC' }, enabled: true, nextRunAtMs: 1791943600000, scheduleDescription: 'Daily', lastRunId: null, webhookUrl: null, cronJobId: 'cron-daily' }); f.store.put('routines', routine);
    const plan = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('move_preview'), action: 'move', targetMachineId: 'destination' });
    f.fail((method, params) => { if (method === 'memory.transfer' && params.action === 'apply') throw new ApiError('outcome_unknown', 'Acknowledgment lost.', false); });
    await expect(f.request('POST', `/v1/bots/${bot.id}/move`, confirmed(plan, { machineId: 'destination' }))).rejects.toMatchObject({ code: 'outcome_unknown', retrySafe: false });
    expect(f.store.require<P.Bot>('bots', bot.id).machineId).toBe('machine'); expect(f.store.require<P.Routine>('routines', routine.id).enabled).toBe(false);
    expect(f.calls.some(call => call.method === 'profiles.update' && call.params.node === 'node-destination')).toBe(false);
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).toMatchObject({ status: 'outcome_unknown' });
    const count = f.calls.length;
    await expect(f.request('POST', `/v1/bots/${bot.id}/move`, { ...confirmed(plan, { machineId: 'destination' }), clientNonce: nonce('another_move') })).rejects.toMatchObject({ code: 'outcome_unknown' });
    expect(f.calls).toHaveLength(count);
  });
  test('confirmed overwrite is disclosed and transfer/persona acknowledgment precede cutover', async () => {
    const f = fixture(), bot = f.bot();
    const plan = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('successful_move_preview'), action: 'move', targetMachineId: 'destination' });
    expect(plan.affected.some(effect => effect.resourceType === 'runtime_memory' && effect.operation === 'reset' && effect.machineId === 'destination')).toBe(true);
    const moved = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/move`, confirmed(plan, { machineId: 'destination' }));
    expect(moved.machineId).toBe('destination'); expect(f.store.metadata(`botPlacementEpoch:${bot.id}`)).toBe(1);
    const cutover = f.calls.findIndex(call => call.method === 'profiles.update' && call.params.node === 'node-destination');
    expect(f.calls.findIndex(call => call.method === 'memory.transfer' && call.params.action === 'apply')).toBeLessThan(cutover);
    expect(f.calls.findIndex(call => call.method === 'profiles.sync' && call.params.nodeId === 'node-destination')).toBeLessThan(cutover);
    expect(f.calls.some(call => call.method === 'node.fs.read')).toBe(false);
  });
  test('destination revision invalidates the exact preview before cutover', async () => {
    const f = fixture(), bot = f.bot();
    const plan = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('revision_preview'), action: 'move', targetMachineId: 'destination' });
    const destination = f.store.require<P.Machine>('machines', 'destination'); f.store.put('machines', f.services.update(destination, { name: 'Renamed' }));
    const count = f.calls.length;
    await expect(f.request('POST', `/v1/bots/${bot.id}/move`, confirmed(plan, { machineId: 'destination' }))).rejects.toMatchObject({ code: 'confirmation_required' });
    expect(f.calls).toHaveLength(count); expect(f.store.require<P.Bot>('bots', bot.id).machineId).toBe('machine');
  });
});

describe('reviewed declarative copies and exact deletion scope', () => {
  test('exports omit private memory/history/reference avatars and connector credentials', async () => {
    const f = fixture(), bot = f.bot();
    f.store.put('memories', f.services.resource('memory', { botId: bot.id, scope: 'personal', userId: 'alice', text: 'PRIVATE_LEARNED_DATA', kind: 'fact', sourceEntryId: null }));
    f.store.put('connectors', f.services.resource('connector', { botId: bot.id, ownerUserId: 'alice', name: 'Mail', url: 'https://private.example', accountLabel: 'private account', authKind: 'oauth', state: 'connected', tools: [], secretHeaderNames: ['Authorization'], shared: false, lastError: null }));
    const value = await f.request<P.TemplateContent>('GET', `/v1/bots/${bot.id}/export`, undefined);
    expect(value.connectorNames).toEqual(['Mail']); expect(value.avatar.attachmentId).toBeNull();
    for (const secret of ['PRIVATE_LEARNED_DATA', 'private.example', 'private account', 'Authorization']) expect(JSON.stringify(value)).not.toContain(secret);
  });
  test('public policy immediately blocks existing anonymous links and imports require third-party terms', async () => {
    const f = fixture(), bot = f.bot();
    const content = await f.request<P.TemplateContent>('GET', `/v1/bots/${bot.id}/export`, undefined);
    const template: P.BotTemplate = f.services.resource('template', { ownerUserId: 'alice', audience: 'public', sourceBotId: bot.id, content, provenance: { publisher: 'External publisher', sourceUrl: 'https://publisher.example', termsUrl: 'https://publisher.example/terms', thirdParty: true }, shareUrl: 'https://lemon.example/template' }); f.store.put('templates', template);
    f.store.setMetadata('policies', { publicTemplates: false });
    await expect(f.request('GET', `/v1/templates/${template.id}`, undefined, null)).rejects.toMatchObject({ code: 'policy_denied' });
    expect((await f.request<P.Page<P.BotTemplate>>('GET', '/v1/templates', undefined)).items).toEqual([]);
    f.store.setMetadata('policies', { publicTemplates: true });
    await expect(f.request('POST', `/v1/templates/${template.id}/import`, { clientNonce: nonce('declined_terms'), name: 'Copy', machineId: 'destination', acceptedTerms: false })).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.calls).toHaveLength(0);
  });
  test('Team-copy refuses private notes before creating any resource', async () => {
    const f = fixture(), bot = f.bot();
    const note: P.Memory = f.services.resource('memory', { botId: bot.id, scope: 'private_note', userId: 'alice', text: 'Private note', kind: 'fact', sourceEntryId: null }); f.store.put('memories', note);
    await expect(f.request('POST', `/v1/bots/${bot.id}/team-copy`, { clientNonce: nonce('private_copy'), name: 'Team copy', machineId: 'destination', memoryIds: [note.id], skillIds: [], referenceAttachmentIds: [], routineIds: [], connectorIds: [] })).rejects.toMatchObject({ code: 'forbidden' });
    expect(f.store.list<P.Bot>('bots')).toHaveLength(1); expect(f.calls).toHaveLength(0);
  });
  test('duplicate creates a separate identity with no learned memory, conversations or tokens copied', async () => {
    const f = fixture(), original = f.bot();
    f.store.put('memories', f.services.resource('memory', { botId: original.id, scope: 'personal', userId: 'alice', text: 'Do not copy learned history', kind: 'fact', sourceEntryId: null }));
    const copy = await f.request<P.Bot>('POST', `/v1/bots/${original.id}/duplicate`, { clientNonce: nonce('duplicate'), name: 'Separate', machineId: 'destination', includeSkills: false, includeRoutines: false });
    expect(copy.id).not.toBe(original.id); expect(copy.profileId).not.toBe(original.profileId); expect(copy.mainConversationId).not.toBe(original.mainConversationId);
    expect(copy.referenceAttachmentIds).toEqual([]); expect(f.store.list<P.Memory>('memories', memory => memory.botId === copy.id)).toEqual([]);
    expect(f.store.metadata<{ digest: string }>(`botMcp:${copy.id}`)?.digest).not.toBe(f.store.metadata<{ digest: string }>(`botMcp:${original.id}`)?.digest);
  });
  test('Team deletion preview discloses exact private resource IDs but never content', async () => {
    const f = fixture(), bot = f.bot('team', false), other = f.addUser('teammate');
    const room = f.addConversation(bot, other.userId, 'team_dm'); f.store.put('entries', f.services.resource('entry', { conversationId: room.id, seq: 1, timestampMs: f.services.now(), actor: { kind: 'user', id: other.userId, displayName: 'Teammate' }, clientNonce: null, batchId: null, replyToEntryId: null, runId: null, targetedUserId: null, reactions: [], kind: 'message', role: 'user', text: 'PRIVATE_TRANSCRIPT', streaming: false, attachmentIds: [] }));
    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('admin_delete_preview'), action: 'delete' }, f.admin);
    expect(preview.affected.some(effect => effect.id === room.id && effect.operation === 'delete')).toBe(true); expect(JSON.stringify(preview)).not.toContain('PRIVATE_TRANSCRIPT');
    expect(preview.affected.some(effect => effect.id === 'machine' && effect.operation === 'retain')).toBe(true);
  });
  test('selected Job reset preserves identity, host and unselected data', async () => {
    const f = fixture(), original = f.bot(), bot = { ...original, job: 'Old job', instructions: 'Old instructions' }; f.store.put('bots', bot);
    const note: P.Memory = f.services.resource('memory', { botId: bot.id, scope: 'private_note', userId: 'alice', text: 'Keep note', kind: 'fact', sourceEntryId: null }); f.store.put('memories', note);
    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('job_reset_preview'), action: 'reset', resetScopes: ['job'] });
    const result = await f.request<P.BotResetResult>('POST', `/v1/bots/${bot.id}/reset`, confirmed(preview, { resetScopes: ['job'] }));
    expect(result.bot).toMatchObject({ id: bot.id, machineId: bot.machineId, name: bot.name, job: '', instructions: '' }); expect(result.retainedScopes).toContain('memory'); expect(f.store.require<P.Memory>('memories', note.id).text).toBe('Keep note');
    expect(f.calls.some(call => call.method === 'memory.delete' || call.method === 'node.fs.delete')).toBe(false);
  });
});

describe('section rank and provider prerequisites', () => {
  test('section keysets order negative, fractional and multi-digit ranks numerically', async () => {
    const f = fixture();
    for (const rank of [10, -2, 2, 0.5]) await f.request('POST', '/v1/sections', { clientNonce: nonce(`section_${String(rank).replace('.', '_').replace('-', 'minus')}`), name: String(rank), rank });
    const first = await f.request<P.Page<P.Section>>('GET', '/v1/sections?limit=2', undefined);
    expect(first.items.map(section => section.rank)).toEqual([-2, 0.5]); expect(first.nextCursor).not.toBeNull();
    const rest = await f.request<P.Page<P.Section>>('GET', `/v1/sections?limit=2&cursor=${first.nextCursor}`, undefined);
    expect(rest.items.map(section => section.rank)).toEqual([2, 10]);
  });
  test('section removal moves only the viewer sidebar state and preserves another viewer section', async () => {
    const f = fixture(), bot = f.bot('team', true);
    const section = await f.request<P.Section>('POST', '/v1/sections', { clientNonce: nonce('section_create'), name: 'Mine' });
    await f.request('PATCH', `/v1/bots/${bot.id}/sidebar`, { clientNonce: nonce('section_set'), revision: bot.revision, sectionId: section.id });
    f.store.setMetadata(`botSidebar:admin:${bot.id}`, { ...bot.sidebar, sectionId: 'another-section' });
    await f.request('DELETE', `/v1/sections/${section.id}`, { clientNonce: nonce('section_delete'), revision: section.revision });
    expect(f.store.metadata<P.SidebarState>(`botSidebar:alice:${bot.id}`)?.sectionId).toBeNull();
    expect(f.store.metadata<P.SidebarState>(`botSidebar:admin:${bot.id}`)?.sectionId).toBe('another-section');
  });
  test('missing avatar provider reports the exact prerequisite and creates no artifact', async () => {
    const f = fixture(), bot = f.bot(), previous = process.env.LEMON_BOT_IMAGE_PROVIDER;
    delete process.env.LEMON_BOT_IMAGE_PROVIDER;
    try {
      await expect(f.request('POST', `/v1/bots/${bot.id}/avatar/generate`, { clientNonce: nonce('avatar_prerequisite'), prompt: 'A friendly character' })).rejects.toMatchObject({ code: 'capability_unavailable', retrySafe: true });
      expect(f.store.list<P.Attachment>('attachments')).toEqual([]);
    } finally { if (previous === undefined) delete process.env.LEMON_BOT_IMAGE_PROVIDER; else process.env.LEMON_BOT_IMAGE_PROVIDER = previous; }
  });
  test('selected skills and webhook routines copy as new identities without source keys', async () => {
    const f = fixture(), bot = f.bot();
    const skill: P.Skill = f.services.resource('skill', { ownerUserId: 'alice', scope: 'personal', botId: bot.id, name: 'Checklist', description: 'Plan work', markdown: '# Checklist\n- Review the plan', enabled: true, machineIds: ['machine'], provenance: { sourceUrl: null, publisher: 'alice', trusted: false } });
    f.store.put('skills', skill); f.store.put('bots', { ...bot, skillIds: [skill.id] });
    const routine: P.Routine = f.services.resource('routine', { botId: bot.id, ownerUserId: 'alice', name: 'On request', instruction: 'Make a plan', trigger: { kind: 'webhook' }, enabled: true, nextRunAtMs: null, scheduleDescription: 'Webhook', lastRunId: null, webhookUrl: 'https://lemon.example/hooks/source', cronJobId: null }); f.store.put('routines', routine); f.store.setMetadata(`routineKey:${routine.id}`, { id: 'source-key', digest: 'source-only-digest' });
    const copy = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/duplicate`, { clientNonce: nonce('selected_duplicate'), name: 'Separate', machineId: 'destination', includeSkills: true, includeRoutines: true });
    expect(copy.skillIds).toHaveLength(1); expect(copy.skillIds[0]).not.toBe(skill.id);
    expect(f.store.require<P.Skill>('skills', copy.skillIds[0]!).markdown).toBe(skill.markdown);
    const routines = f.store.list<P.Routine>('routines', value => value.botId === copy.id);
    expect(routines).toHaveLength(1); expect(routines[0]?.enabled).toBe(false); expect(f.store.metadata(`routineKey:${routines[0]!.id}`)).toBeNull();
    expect(f.store.require<P.Routine>('routines', routine.id).enabled).toBe(true);
  });
});

describe('acknowledged recovery and shared floor ownership', () => {
  test('a lost persona reply reconciles by exact read-only receipt, never by another update/sync', async () => {
    const f = fixture(), bot = f.bot();
    f.fail((method) => { if (method === 'profiles.sync') throw new ApiError('outcome_unknown', 'Persona receipt lost.', false); });
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('lost_persona'), revision: bot.revision, job: 'Approved new job' })).rejects.toMatchObject({ code: 'outcome_unknown' });
    f.fail(null);
    const writes = f.calls.filter(call => call.method === 'profiles.update' || call.method === 'profiles.sync').length;
    await createBotService(f.services).reconcile();
    expect(f.calls.filter(call => call.method === 'profiles.update' || call.method === 'profiles.sync')).toHaveLength(writes);
    expect(f.calls.some(call => call.method === 'profiles.sync.status')).toBe(true);
    expect(f.store.require<P.Bot>('bots', bot.id).job).toBe('Approved new job');
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).toBeNull();
  });
  test('trusted administrator-only hardening changes native floor, never persona or connector credentials', async () => {
    const f = fixture(), bot = f.bot();
    const capabilities: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [] };
    f.store.put('machineCapabilities', { ...capabilities, id: 'machine' });
    await syncBotPolicyFloor(f.services, f.owner, bot.id);
    const changed = f.calls.find(call => call.method === 'profiles.update')!;
    expect(Object.keys(changed.params).sort()).toEqual(['id', 'mcpServers', 'toolPolicy']);
    expect(changed.params.mcpServers).toEqual([{ ...baseBotMcpConfig(f.services, bot), headers: {} }]);
    expect(f.store.require<P.Bot>('bots', bot.id)).toEqual(bot);
    expect(f.store.metadata(`botPolicyFloor:${bot.id}`)).toMatchObject({ state: 'acknowledged' });
    await expect(syncBotPolicyFloor(f.services, f.alice, bot.id)).rejects.toMatchObject({ code: 'forbidden' });
  });
});

describe('authoritative native idle lifecycle boundary', () => {
  test('empty legacy active-list replies never authorize memory preview or deletion', async () => {
    const f = fixture(), bot = f.bot(); f.presence(null);
    await expect(f.request('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('legacy_empty'), action: 'delete' })).rejects.toMatchObject({ code: 'capability_unavailable' });
    expect(f.store.require<P.Bot>('bots', bot.id)).toEqual(bot);
    expect(f.calls.some(call => call.method === 'memory.list' || call.method === 'profiles.delete')).toBe(false);
  });
  test('queued and unattributed uncertain native work block even when active-page is empty', async () => {
    for (const [queued, unknown, code] of [[1, 0, 'conflict'], [0, 1, 'outcome_unknown']] as const) {
      const f = fixture(), bot = f.bot(); f.presence({ active: 0, queued, unknown, idle: false, complete: true });
      await expect(f.request('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`presence_${code}`), action: 'move', targetMachineId: 'destination' })).rejects.toMatchObject({ code });
      expect(f.calls.some(call => call.method === 'memory.transfer')).toBe(false);
      expect(f.store.require<P.Bot>('bots', bot.id).machineId).toBe('machine');
    }
  });
  test('presence is checked again after schedules pause, before transfer starts', async () => {
    const f = fixture(), bot = f.bot();
    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('presence_race'), action: 'move', targetMachineId: 'destination' });
    let reads = 0;
    f.fail(method => { if (method === 'runs.active.list' && ++reads === 2) throw new ApiError('upstream_unavailable', 'Presence changed during snapshot.'); });
    await expect(f.request('POST', `/v1/bots/${bot.id}/move`, confirmed(preview, { machineId: 'destination' }))).rejects.toMatchObject({ code: 'upstream_unavailable' });
    expect(f.calls.some(call => call.method === 'memory.transfer' && call.params.action === 'apply')).toBe(false);
    expect(f.store.require<P.Bot>('bots', bot.id).machineId).toBe('machine');
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).not.toBeNull();
  });
});

describe('fresh native follow-up readiness fence', () => {
  test('issuer setup follows persona receipt and uses separate encrypted custody before bot readiness', async () => {
    const f = fixture();
    const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('native_issuer'), name: 'Issuer', machineId: 'machine' });
    const index = f.calls.findIndex(call => call.method === 'profile.followup.admission.set');
    expect(index).toBeGreaterThan(f.calls.findIndex(call => call.method === 'profiles.sync'));
    const call = f.calls[index]!;
    expect(call.params.profileId).toBe(bot.profileId);
    expect(call.params.url).toBe('https://lemon.example/internal/runtime/followup/admission');
    const token = String(call.params.token);
    const issuer = f.store.metadata<{ state: string; digest: string; encryptedToken: string }>(`nativeFollowupIssuerConfig:${bot.id}`)!;
    expect(issuer.state).toBe('configured'); expect(issuer.digest).toBe(f.services.mutations.digest(token));
    expect(issuer.encryptedToken).not.toContain(token);
    expect(JSON.stringify(bot)).not.toContain(token);
    expect(bot.activity).toBe('idle');
  });
  test('lost issuer receipt cannot be replayed or mistaken for persona-only readiness', async () => {
    const f = fixture();
    f.fail(method => { if (method === 'profile.followup.admission.set') throw new ApiError('outcome_unknown', 'Issuer receipt lost.', false); });
    await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('lost_issuer'), name: 'Pending issuer', machineId: 'machine' })).rejects.toMatchObject({ code: 'outcome_unknown' });
    const bot = f.store.list<P.Bot>('bots')[0]!;
    expect(bot.activity).toBe('offline');
    expect(f.store.metadata(`nativeFollowupIssuerConfig:${bot.id}`)).toMatchObject({ state: 'outcome_unknown' });
    f.fail(null); await createBotService(f.services).reconcile();
    expect(f.calls.filter(call => call.method === 'profile.followup.admission.set')).toHaveLength(1);
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).not.toBeNull();
  });
});

describe('credential-free public native MCP ceiling', () => {
  test('profile rebuild consumes every declared template without querying owner/account credential configuration', async () => {
    const f = fixture(), bot = f.bot('team', true);
    f.services.integrations.connectorConfig = async () => { throw new Error('Owner credential configuration must not be queried by public profile rebuild.'); };
    const templates = [
      { name: 'connector-account-a', url: 'https://a.example/mcp', headers: {}, enabledTools: ['lookup'], allowedOrigins: ['https://a.example'], approvedPrivateOrigins: [] },
      { name: 'connector-account-b', url: 'https://b.example/mcp', headers: {}, enabledTools: ['read'], allowedOrigins: ['https://b.example'], approvedPrivateOrigins: [] },
    ];
    f.services.integrations.connectorTemplates = async botId => { expect(botId).toBe(bot.id); return templates; };
    const changed = await f.request<P.Bot>('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('public_ceiling'), revision: bot.revision, job: 'Public declarative job' });
    const update = f.calls.find(call => call.method === 'profiles.update')!;
    expect(update.params.mcpServers).toEqual([{ ...baseBotMcpConfig(f.services, bot), headers: {} }, ...templates]);
    expect(JSON.stringify(update.params)).not.toContain('LEMON_SECRET');
    expect(changed.job).toBe('Public declarative job');
  });
  test('a getter returning any credential header cannot become a persisted or acknowledged profile', async () => {
    const f = fixture(), bot = f.bot();
    f.services.integrations.connectorTemplates = async () => [{ name: 'connector-private', url: 'https://provider.example/mcp', headers: { Authorization: '${LEMON_SECRET:private_account}' }, enabledTools: ['read'], allowedOrigins: ['https://provider.example'], approvedPrivateOrigins: [] }];
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('forbidden_header'), revision: bot.revision, job: 'Rejected configuration' })).rejects.toMatchObject({ code: 'capability_unavailable' });
    expect(f.calls.some(call => call.method === 'profiles.update')).toBe(false);
    expect(f.store.require<P.Bot>('bots', bot.id).job).toBe(bot.job);
  });
});
