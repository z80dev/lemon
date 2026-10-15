import { describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../../src/core/services';
import { ApiError } from '../../src/core/errors';
import { createBotRoutes, baseBotMcpConfig, syncBotProfile, createBotService, syncBotPolicyFloor, productBotTools, assertWorkspaceRestrictionManagement } from '../../src/core/bots';
import { createConversationRoutes } from '../../src/core/conversations';
import { createResourceRoutes } from '../../src/core/resources';
import { authFixture, routeContext } from './auth.test';

interface Call { method: string; params: Record<string, unknown>; mutation: boolean }
// Captured authenticated native mcp.execution_names DTO for lemon-bot at https://product.example/mcp.
// Keep the fixture origin bound to this capture rather than synthesizing native aliases.
const fixturePublicUrl = 'https://product.example';
const projectedProductTools = [
  { name: 'message_bot', executionName: 'mcp_lemon_bot_message_bot_e27f8366c893fc7d4ace784f51ce12a1' },
  { name: 'handoff', executionName: 'mcp_lemon_bot_handoff_9f74e5f82ed019f6a9084a1daa468386' },
  { name: 'create_draft', executionName: 'mcp_lemon_bot_create_draft_6e65809e9170b8c9b3cb0da09b714275' },
  { name: 'ask_user', executionName: 'mcp_lemon_bot_ask_user_10d4fd7a91be9332225ab7a9f47f9f2f' },
  { name: 'request_approval', executionName: 'mcp_lemon_bot_request_approval_ca54a9645adf9ba042f0e53146a13ee0' },
  { name: 'request_human_step', executionName: 'mcp_lemon_bot_request_human_ste_688cee41cf6bff126499b440c3a8624c' },
  { name: 'request_secret', executionName: 'mcp_lemon_bot_request_secret_c5d5dd62ffb1c7cd4ebdaf58ee1da740' },
  { name: 'send_voice_memo', executionName: 'mcp_lemon_bot_send_voice_memo_94b772ea7c8f891201c61ad1c1a26482' },
  { name: 'share_file', executionName: 'mcp_lemon_bot_share_file_768d74587235feb2e85ef683d4558c37' },
  { name: 'create_routine', executionName: 'mcp_lemon_bot_create_routine_480cfac22f6df0d89908d166b1e80b6f' },
  { name: 'update_routine', executionName: 'mcp_lemon_bot_update_routine_9243c6d1a2783406bed605d7ddf21a9d' },
  { name: 'save_skill', executionName: 'mcp_lemon_bot_save_skill_ce8a3dbeea117002d1ccc85b12353fb5' },
  { name: 'list_bots', executionName: 'mcp_lemon_bot_list_bots_151a36bf63151717e5c7dcf2f76752f2' },
  { name: 'post_to_group', executionName: 'mcp_lemon_bot_post_to_group_f9eeb76c647b0739da6629d63799e809' },
  { name: 'remember', executionName: 'mcp_lemon_bot_remember_88ac13cb8401ab72fbc6e5caeaedf539' },
  { name: 'create_bot', executionName: 'mcp_lemon_bot_create_bot_4a92e9bba45de6978e230abb443d9321' },
  { name: 'update_preferences', executionName: 'mcp_lemon_bot_update_preference_f55d35c688fc2ca9a6d77f7bb3c75d94' },
  { name: 'create_reminder', executionName: 'mcp_lemon_bot_create_reminder_d1a7af45016ffbce56b89af97037eae8' },
];
function fixture() {
  const f = authFixture();
  f.services.config.publicUrl = fixturePublicUrl;
  const calls: Call[] = [];
  const profileRows = new Map<string, Record<string, unknown>>();
  const hostFiles = new Map<string, { size: number; mtimeMs: number }>();
  let hostRevision = 0;
  let reject: ((method: string, params: Record<string, unknown>) => void) | null = null;
  let nativePresence: { active: number; queued: number; unknown: number; idle: boolean; complete: boolean } | null = { active: 0, queued: 0, unknown: 0, idle: true, complete: true };
  const methods = ['profiles.create', 'profiles.update', 'profiles.get', 'profiles.sync', 'profiles.sync.status', 'profiles.delete', 'mcp.execution_names', 'profile.followup.admission.set', 'runs.followup.lineage.get', 'runs.active.list', 'memory.transfer', 'memory.transfer.status', 'memory.list', 'memory.delete', 'memory.add', 'nodes.list', 'node.capabilities.get', 'node.secrets.set', 'node.secrets.receipt', 'node.secrets.delete', 'node.host.info', 'node.profile.paths', 'node.fs.stat', 'node.fs.write', 'node.fs.delete', 'cron.pause', 'cron.resume', 'cron.add', 'cron.remove', 'sessions.delete'];
  f.services.lemon = {
    connected: true, methods,
    controller: { url: 'ws://127.0.0.1:4040/ws', state: 'connected', connectedAtMs: 1, lastDisconnectedAtMs: null, lastError: null, nextRetryAtMs: null, methodCount: 0 }, reconnect() {},
    async call<T>(method: string, params: Record<string, unknown> = {}, options?: { mutation?: boolean }): Promise<T> {
      calls.push({ method, params, mutation: options?.mutation === true }); reject?.(method, params);
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
      else if (method === 'mcp.execution_names') {
        expect(params).toEqual({ server: { name: 'lemon-bot', url: `${fixturePublicUrl}/mcp` }, toolNames: [...productBotTools] });
        value = { server: { name: 'lemon-bot' }, tools: projectedProductTools, count: projectedProductTools.length };
      }
      else if (method === 'node.secrets.set') value = { name: params.name, set: true, operationId: params.operationId, status: 'applied', currentBindingMatches: true };
      else if (method === 'node.secrets.delete') value = { name: params.name, deleted: true };
      else if (method === 'runs.active.list') value = { runs: [], filters: { profileId: params.profileId, limit: params.limit }, ...(nativePresence ? { presence: nativePresence } : {}) };
      else if (method === 'node.profile.paths') value = { nodeId: params.nodeId, profileId: params.profileId, workspacePath: `/worker/profiles/${params.profileId}/workspace`, skillsPath: `/worker/profiles/${params.profileId}/workspace/.lemon/skill` };
      else if (method === 'nodes.list') value = { nodes: f.store.list<P.Machine>('machines', machine => !params.nodeId || machine.nodeId === params.nodeId).map(machine => ({ id: machine.nodeId, status: machine.status, capabilities: ['node.capabilities.get'] })), summary: { presenceAvailable: true, truncated: false } };
      else if (method === 'node.capabilities.get') value = { nodeId: params.nodeId, os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [] };
      else if (method === 'node.host.info') value = { defaultCwd: '/home/lemon' };
      else if (method === 'node.fs.stat') {
        const file = hostFiles.get(`${params.nodeId}:${params.path}`);
        if (!file) throw new ApiError('not_found', 'Managed file does not exist.');
        value = { path: params.path, type: 'regular', size: file.size, mtimeMs: file.mtimeMs };
      } else if (method === 'node.fs.write') {
        const key = `${params.nodeId}:${params.path}`, previous = hostFiles.get(key);
        if (params.expectedModifiedAtMs !== (previous?.mtimeMs ?? 0)) throw new ApiError('revision_conflict', 'Managed file changed before write.');
        const size = Buffer.from(String(params.dataBase64), 'base64').length, mtimeMs = f.services.now() + ++hostRevision;
        hostFiles.set(key, { size, mtimeMs }); value = { path: params.path, bytesWritten: size, size, mtimeMs };
      } else if (method === 'node.fs.delete') { hostFiles.delete(`${params.nodeId}:${params.path}`); value = { path: params.path, deleted: true }; }
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
  f.services.runtime = { submit: unavailable, send: unavailable, cancel: unavailable, reconcile: unavailable, revokeConnectorInvocations: unavailable, sessionKey: (_room, bot) => `agent:${bot.profileId}:main` };
  f.services.integrations.connectorConfig = async () => [];
  f.services.integrations.connectorTemplates = async () => [];
  f.services.integrations.effectivePolicy = async (actor, botId) => ({ userId: actor.userId, botId: botId ?? null, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] });
  f.services.integrations.emitProviderNotifications = async () => {};
  f.services.syncBotProfile = (actor, botId) => syncBotProfile(f.services, actor, botId);
  const routes: Route[] = [...createBotRoutes(f.services), ...createConversationRoutes(f.services), ...createResourceRoutes(f.services)];
  function context(method: string, path: string, body: unknown, actor: Principal | null) {
    const requested = new URL(path, fixturePublicUrl);
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
  function bot(): P.Bot {
    const bot = f.addBot('alice');
    const room = f.addConversation(bot, 'alice', 'dm');
    const saved = { ...bot, profileId: `lb-${f.services.mutations.digest(bot.id).slice(0, 40)}`, mainConversationId: room.id }; f.store.put('bots', saved);
    const source = f.store.require<P.Machine>('machines', 'machine'); f.store.put('machines', { ...source, botIds: [...source.botIds, bot.id] });
    f.store.setMetadata(`botMcp:${bot.id}`, { secretName: 'test_bot_ref', encryptedToken: f.services.encrypt('unit-test-bot-token'), digest: f.services.mutations.digest('unit-test-bot-token') });
    profileRows.set(saved.profileId, { id: saved.profileId, node: 'node-source', canonicalSessionKey: `agent:${saved.profileId}:main` });
    f.store.setMetadata(`profileCanonicalSession:${saved.id}`, `agent:${saved.profileId}:main`);
    f.store.setMetadata(`botControllerFloor:${saved.id}`, { profile: 'custom', allow: ['read_skill', 'webfetch', 'websearch', 'task', 'agent_message', 'wait', 'parent_question', ...projectedProductTools.map(tool => tool.executionName)], deny: ['native_prior_denied'], blocked_tools: ['native_prior_blocked'], require_approval: ['prior_requires_approval'] });
    const issuerToken = 'existing-private-native-issuer-token';
    const digest = f.services.mutations.digest(issuerToken);
    f.store.setMetadata(`nativeFollowupIssuerConfig:${saved.id}`, { botId: saved.id, profileId: saved.profileId, url: `${fixturePublicUrl}/internal/runtime/followup/admission`, digest, encryptedToken: f.services.encrypt(issuerToken), state: 'configured' });
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
  test('legacy publication and manager labels grant no live Bot access to members or workspace roles', async () => {
    const f = fixture(), source = f.bot(), bot = { ...source, visibility: 'team', published: true, managerUserIds: ['admin', 'owner'], required: true };
    f.store.put('bots', bot);
    for (const actor of [f.admin, f.owner]) {
      await expect(f.request('GET', `/v1/bots/${bot.id}`, undefined, actor)).rejects.toMatchObject({ code: 'not_found' });
      await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce(`foreign_${actor.userId}`), revision: bot.revision, job: 'Not authorized' }, actor)).rejects.toMatchObject({ code: 'not_found' });
      expect((await f.request<P.Page<P.Bot>>('GET', '/v1/bots', undefined, actor)).items).toEqual([]);
    }
    const own = await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined);
    for (const key of ['visibility', 'published', 'managerUserIds', 'required']) expect(Object.hasOwn(own, key)).toBe(false);
    expect(f.calls).toHaveLength(0);
  });
  test('removed live sharing inputs are rejected even when empty or false, before any runtime effects', async () => {
    const f = fixture(), bot = f.bot();
    for (const [key, value] of [['published', false], ['required', false], ['managerUserIds', []]] as const) {
      await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce(`removed_${key}`), revision: bot.revision, [key]: value })).rejects.toMatchObject({ code: 'invalid_request' });
    }
    await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('removed_visibility'), name: 'Not shared', machineId: 'machine', visibility: 'team' })).rejects.toMatchObject({ code: 'invalid_request' });
    for (const query of ['visibility=team', 'published=true']) await expect(f.request('GET', `/v1/bots?${query}`, undefined)).rejects.toMatchObject({ code: 'invalid_request' });
    expect(f.calls).toHaveLength(0);
  });
  test('owner sidebar revisions remain private and reject concurrent stale updates', async () => {
    const f = fixture(), bot = f.bot();
    const changed = await f.request<P.Bot>('PATCH', `/v1/bots/${bot.id}/sidebar`, { clientNonce: nonce('owner_hide'), revision: bot.revision, hidden: true });
    expect(changed.sidebar.hidden).toBe(true);
    await expect(f.request('PATCH', `/v1/bots/${bot.id}/sidebar`, { clientNonce: nonce('foreign_sidebar'), revision: changed.revision, hidden: false }, f.admin)).rejects.toMatchObject({ code: 'not_found' });
    await expect(f.request('PATCH', `/v1/bots/${bot.id}/sidebar`, { clientNonce: nonce('stale_sidebar'), revision: bot.revision, pinned: true })).rejects.toMatchObject({ code: 'revision_conflict' });
    expect((await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).sidebar.hidden).toBe(true);
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
    expect(baseBotMcpConfig(f.services, bot).allowedOrigins).toEqual([fixturePublicUrl]);
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
    const mutationCount = f.calls.filter(call => call.mutation).length;
    await expect(f.request('POST', `/v1/bots/${bot.id}/move`, confirmed(plan, { machineId: 'destination' }))).rejects.toMatchObject({ code: 'confirmation_required' });
    expect(f.calls.filter(call => call.mutation)).toHaveLength(mutationCount); expect(f.store.require<P.Bot>('bots', bot.id).machineId).toBe('machine');
  });
});

describe('reviewed declarative copies and exact deletion scope', () => {
  test('exports omit private memory/history/reference avatars and connector credentials', async () => {
    const f = fixture(), bot = f.bot();
    f.store.put('memories', f.services.resource('memory', { botId: bot.id, text: 'PRIVATE_LEARNED_DATA', kind: 'fact', sourceEntryId: null }));
    f.store.put('connectors', f.services.resource('connector', { botId: bot.id, ownerUserId: 'alice', name: 'Mail', url: 'https://private.example', accountLabel: 'private account', authKind: 'oauth', state: 'connected', tools: [], secretHeaderNames: ['Authorization'], lastError: null }));
    const value = await f.request<P.TemplateContent>('GET', `/v1/bots/${bot.id}/export`, undefined);
    expect(value.connectorNames).toEqual(['Mail']); expect(value.avatar.attachmentId).toBeNull();
    for (const secret of ['PRIVATE_LEARNED_DATA', 'private.example', 'private account', 'Authorization']) expect(JSON.stringify(value)).not.toContain(secret);
  });
  test('public policy immediately blocks existing anonymous links and imports require third-party terms', async () => {
    const f = fixture(), bot = f.bot();
    const content = await f.request<P.TemplateContent>('GET', `/v1/bots/${bot.id}/export`, undefined);
    const template: P.BotTemplate = f.services.resource('template', { ownerUserId: 'alice', audience: 'public', sourceBotId: bot.id, content, provenance: { publisher: 'External publisher', sourceUrl: 'https://publisher.example', termsUrl: 'https://publisher.example/terms', thirdParty: true }, shareUrl: `${fixturePublicUrl}/template` }); f.store.put('templates', template);
    f.store.setMetadata('policies', { publicTemplates: false });
    await expect(f.request('GET', `/v1/templates/${template.id}`, undefined, null)).rejects.toMatchObject({ code: 'policy_denied' });
    expect((await f.request<P.Page<P.BotTemplate>>('GET', '/v1/templates', undefined)).items).toEqual([]);
    f.store.setMetadata('policies', { publicTemplates: true });
    await expect(f.request('POST', `/v1/templates/${template.id}/import`, { clientNonce: nonce('declined_terms'), name: 'Copy', machineId: 'destination', acceptedTerms: false })).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.calls).toHaveLength(0);
  });
  test('duplicate creates a separate identity with no learned memory, conversations or tokens copied', async () => {
    const f = fixture(), original = f.bot();
    f.store.put('memories', f.services.resource('memory', { botId: original.id, text: 'Do not copy learned history', kind: 'fact', sourceEntryId: null }));
    const copy = await f.request<P.Bot>('POST', `/v1/bots/${original.id}/duplicate`, { clientNonce: nonce('duplicate'), name: 'Separate', machineId: 'destination', includeSkills: false, includeRoutines: false });
    expect(copy.id).not.toBe(original.id); expect(copy.profileId).not.toBe(original.profileId); expect(copy.mainConversationId).not.toBe(original.mainConversationId);
    expect(copy.referenceAttachmentIds).toEqual([]); expect(f.store.list<P.Memory>('memories', memory => memory.botId === copy.id)).toEqual([]);
    expect(f.store.metadata<{ digest: string }>(`botMcp:${copy.id}`)?.digest).not.toBe(f.store.metadata<{ digest: string }>(`botMcp:${original.id}`)?.digest);
  });
  test('workspace administrators cannot preview another owner’s private lifecycle or metadata', async () => {
    const f = fixture(), bot = f.bot();
    f.store.put('entries', f.services.resource('entry', { conversationId: bot.mainConversationId, seq: 1, timestampMs: f.services.now(), actor: { kind: 'user', id: 'alice', displayName: 'Alice' }, clientNonce: null, batchId: null, replyToEntryId: null, runId: null, targetedUserId: null, reactions: [], kind: 'message', role: 'user', text: 'PRIVATE_TRANSCRIPT', streaming: false, attachmentIds: [] }));
    await expect(f.request('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('foreign_delete_preview'), action: 'delete' }, f.admin)).rejects.toMatchObject({ code: 'not_found' });
    expect(f.calls).toHaveLength(0);
    expect(f.store.list<P.TranscriptEntry>('entries', entry => entry.conversationId === bot.mainConversationId)[0]!.kind).toBe('message');
    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('owner_delete_preview'), action: 'delete' });
    expect(preview.affected.some(effect => effect.id === bot.mainConversationId && effect.operation === 'delete')).toBe(true);
    expect(JSON.stringify(preview)).not.toContain('PRIVATE_TRANSCRIPT');
  });
  test('selected Job reset preserves identity, host and unselected data', async () => {
    const f = fixture(), original = f.bot(), bot = { ...original, job: 'Old job', instructions: 'Old instructions' }; f.store.put('bots', bot);
    const note: P.Memory = f.services.resource('memory', { botId: bot.id, text: 'Keep owned profile fact', kind: 'fact', sourceEntryId: null }); f.store.put('memories', note);
    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('job_reset_preview'), action: 'reset', resetScopes: ['job'] });
    const result = await f.request<P.BotResetResult>('POST', `/v1/bots/${bot.id}/reset`, confirmed(preview, { resetScopes: ['job'] }));
    expect(result.bot).toMatchObject({ id: bot.id, machineId: bot.machineId, name: bot.name, job: '', instructions: '' }); expect(result.retainedScopes).toContain('memory'); expect(f.store.require<P.Memory>('memories', note.id).text).toBe('Keep owned profile fact');
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
  test('section removal only mutates its owner’s Bot and preserves foreign legacy sidebar state', async () => {
    const f = fixture(), bot = f.bot();
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
    const skill: P.Skill = f.services.resource('skill', { ownerUserId: 'alice', botId: bot.id, name: 'Checklist', description: 'Plan work', markdown: '# Checklist\n- Review the plan', enabled: true, machineIds: ['machine'], provenance: { sourceUrl: null, publisher: 'alice', trusted: false } });
    f.store.put('skills', skill); f.store.put('bots', { ...bot, skillIds: [skill.id] });
    const routine: P.Routine = f.services.resource('routine', { botId: bot.id, ownerUserId: 'alice', name: 'On request', instruction: 'Make a plan', trigger: { kind: 'webhook' }, enabled: true, nextRunAtMs: null, scheduleDescription: 'Webhook', lastRunId: null, webhookUrl: `${fixturePublicUrl}/hooks/source`, cronJobId: null }); f.store.put('routines', routine); f.store.setMetadata(`routineKey:${routine.id}`, { id: 'source-key', digest: 'source-only-digest' });
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
  test('member owner policy refresh installs actual durable policy, never an administrator’s or stale shared floor', async () => {
    const f = fixture(), bot = f.bot();
    const capabilities: P.MachineCapabilities = { machineId: 'machine', os: 'linux', measuredAtMs: f.services.now(), stale: false, items: [] };
    f.store.put('machineCapabilities', { ...capabilities, id: 'machine' });
    const effective = f.services.integrations.effectivePolicy.bind(f.services.integrations);
    f.services.integrations.effectivePolicy = async (actor, botId) => {
      expect(actor.userId).toBe('alice'); expect(botId).toBe(bot.id);
      return { ...await effective(actor, botId), localExecutionCeiling: 'deny', directoryGroupIds: ['owner-policy-group'] };
    };
    await syncBotProfile(f.services, f.alice, bot.id);
    const changed = f.calls.find(call => call.method === 'profiles.update')!;
    expect(Object.keys(changed.params).sort()).toEqual(['description', 'id', 'mcpServers', 'name', 'systemPrompt', 'toolPolicy']);
    expect(changed.params.mcpServers).toEqual([{ ...baseBotMcpConfig(f.services, bot), headers: {} }]);
    const floor = changed.params.toolPolicy as P.JSONObject;
    expect(floor.allow).not.toBe('all');
    expect(floor.allow).toEqual(expect.arrayContaining(['task', 'read_skill', ...projectedProductTools.map(tool => tool.executionName)]));
    expect(floor.deny).toEqual(expect.arrayContaining(['agent', 'cron', 'remember', 'recall']));
    expect(floor.blocked_tools).toEqual(expect.arrayContaining(['agent', 'cron', 'remember', 'recall']));
    expect(floor.deny).not.toContain('native_prior_denied');
    expect(f.store.require<P.Bot>('bots', bot.id)).toEqual(bot);
    expect(f.store.metadata(`botProfileSync:${bot.id}`)).toMatchObject({ acknowledged: true });
    const count = f.calls.length;
    await expect(syncBotProfile(f.services, f.owner, bot.id)).rejects.toMatchObject({ code: 'not_found' });
    expect(f.calls).toHaveLength(count);
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
    expect(call.params.url).toBe(`${fixturePublicUrl}/internal/runtime/followup/admission`);
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
    const f = fixture(), bot = f.bot();
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

describe('strict owning capability and execution-name lifecycle boundaries', () => {
  test('incomplete presence cannot create a ready profile or native floor', async () => {
    const f = fixture();
    const call = f.services.lemon.call.bind(f.services.lemon);
    f.services.lemon.call = async <T>(method: string, params: Record<string, unknown> = {}, options?: { mutation?: boolean }): Promise<T> => {
      if (method === 'nodes.list') return { nodes: [], summary: { presenceAvailable: true, truncated: true } } as T;
      return call<T>(method, params, options);
    };
    await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('truncated_presence'), name: 'Incomplete', machineId: 'machine' })).rejects.toMatchObject({ code: 'upstream_unavailable' });
    expect(f.calls.some(call => call.method === 'profiles.create')).toBe(false);
    expect(f.store.list<P.Bot>('bots')[0]!.activity).toBe('offline');
  });
  test('an ambiguous MCP execution projection fails before any profile or admission is installed', async () => {
    const f = fixture();
    const call = f.services.lemon.call.bind(f.services.lemon);
    f.services.lemon.call = async <T>(method: string, params: Record<string, unknown> = {}, options?: { mutation?: boolean }): Promise<T> => {
      if (method === 'mcp.execution_names') return { server: { name: 'lemon-bot' }, count: projectedProductTools.length, tools: projectedProductTools.map(tool => ({ ...tool, executionName: 'mcp_duplicate_alias' })) } as T;
      return call<T>(method, params, options);
    };
    await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('ambiguous_projection'), name: 'Ambiguous', machineId: 'machine' })).rejects.toMatchObject({ code: 'upstream_unavailable' });
    expect(f.calls.some(call => call.method === 'profiles.create' || call.method === 'profile.followup.admission.set')).toBe(false);
    expect(f.store.list<P.Bot>('bots')[0]!.activity).toBe('offline');
  });
});

describe('same-owner live lifecycle boundaries', () => {
  test('explicit machine delegation and shared-host labels never substitute for raw ownership', async () => {
    const f = fixture(), bot = f.bot(), destination = f.store.require<P.Machine>('machines', 'destination');
    f.store.put('machines', { ...destination, ownerUserId: 'admin', accessUserIds: ['alice'], labels: { 'lemon_bot.shared_context': 'true' } });
    await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('foreign_host_create'), name: 'Denied', machineId: 'destination' })).rejects.toMatchObject({ code: 'not_found' });
    await expect(f.request('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('foreign_host_preview'), action: 'move', targetMachineId: 'destination' })).rejects.toMatchObject({ code: 'not_found' });
    expect(f.calls).toHaveLength(0); expect(f.store.list<P.Bot>('bots')).toHaveLength(1);
    expect(f.store.require<P.Bot>('bots', bot.id).machineId).toBe('machine');
  });
  test('foreign owner cannot duplicate, export, reset, delete or generate a helper avatar', async () => {
    const f = fixture(), bot = f.bot();
    for (const actor of [f.admin, f.owner]) {
      await expect(f.request('GET', `/v1/bots/${bot.id}/export`, undefined, actor)).rejects.toMatchObject({ code: 'not_found' });
      await expect(f.request('POST', `/v1/bots/${bot.id}/duplicate`, { clientNonce: nonce(`foreign_duplicate_${actor.userId}`), name: 'Denied', machineId: 'destination', includeSkills: true, includeRoutines: true }, actor)).rejects.toMatchObject({ code: 'not_found' });
      await expect(f.request('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`foreign_reset_${actor.userId}`), action: 'reset', resetScopes: ['job'] }, actor)).rejects.toMatchObject({ code: 'not_found' });
      await expect(f.request('POST', `/v1/bots/${bot.id}/avatar/generate`, { clientNonce: nonce(`foreign_avatar_${actor.userId}`), prompt: 'Denied' }, actor)).rejects.toMatchObject({ code: 'not_found' });
      const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`owner_delete_${actor.userId}`), action: 'delete' });
      const before = f.calls.filter(call => call.mutation).length;
      await expect(f.request('DELETE', `/v1/bots/${bot.id}`, { ...confirmed(preview), clientNonce: nonce(`foreign_delete_${actor.userId}`) }, actor)).rejects.toMatchObject({ code: 'not_found' });
      expect(f.calls.filter(call => call.mutation)).toHaveLength(before);
    }
    expect(f.store.list<P.Bot>('bots')).toHaveLength(1);
  });
  test('legacy placement onto a foreign machine cannot run profile mutation under either owner’s credentials', async () => {
    const f = fixture(), bot = f.bot(), machine = f.store.require<P.Machine>('machines', bot.machineId);
    f.store.put('machines', { ...machine, ownerUserId: 'admin', accessUserIds: ['alice'] });
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('foreign_source_profile'), revision: bot.revision, job: 'Denied' })).rejects.toMatchObject({ code: 'not_found' });
    expect(f.calls).toHaveLength(0); expect(f.store.require<P.Bot>('bots', bot.id).job).toBe(bot.job);
  });
  test('another user’s formerly shared skill cannot enter an owner profile', async () => {
    const f = fixture();
    const foreign = f.services.resource('skill', { ownerUserId: 'admin', botId: null, name: 'Foreign skill', description: 'Not owned', markdown: 'Private instructions', enabled: true, machineIds: ['machine'], provenance: { sourceUrl: null, publisher: 'admin', trusted: false } });
    f.store.put('skills', foreign);
    await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('foreign_skill'), name: 'Denied', machineId: 'machine', skillIds: [foreign.id] })).rejects.toMatchObject({ code: 'forbidden' });
    expect(f.calls).toHaveLength(0); expect(f.store.list<P.Bot>('bots')).toHaveLength(0);
  });
});

describe('trusted restriction-only management without live Bot authority', () => {
  test('workspace restriction narrows an acknowledged owner floor without private issuer or owner policy lookup', async () => {
    const f = fixture(), bot = f.bot();
    await syncBotProfile(f.services, f.alice, bot.id);
    const acknowledged = f.store.metadata<P.JSONObject>(`botControllerFloor:${bot.id}`)!;
    const allow = acknowledged.allow as string[];
    f.store.setMetadata(`botControllerFloor:${bot.id}`, { ...acknowledged, deny: [...(acknowledged.deny as string[]), 'previous_denial'], blocked_tools: [...(acknowledged.blocked_tools as string[]), 'previous_sealed_block'], require_approval: ['previous_approval'] });
    f.store.setMetadata(`nativeFollowupIssuerConfig:${bot.id}`, { state: 'outcome_unknown', encryptedToken: 'must-not-be-read-by-management' });
    f.services.integrations.workspaceRestrictions = target => {
      expect(target).toEqual({ botId: bot.id, machineId: bot.machineId });
      return { localExecutionCeiling: 'deny', rules: [], allowedMcpOrigins: [fixturePublicUrl], requireReview: true };
    };
    f.services.integrations.effectivePolicy = async () => { throw new Error('Management cannot query owner or administrator effective-user policy.'); };
    f.services.integrations.connectorTemplates = async () => { throw new Error('Management cannot rebuild private owner connector configuration.'); };
    f.services.decrypt = () => { throw new Error('Management cannot decrypt owner credentials.'); };
    const start = f.calls.length;
    await syncBotPolicyFloor(f.services, f.admin, bot.id);
    const calls = f.calls.slice(start), update = calls.find(call => call.method === 'profiles.update')!;
    expect(Object.keys(update.params).sort()).toEqual(['id', 'toolPolicy']);
    const narrowed = update.params.toolPolicy as P.JSONObject;
    expect((narrowed.allow as string[]).every(tool => allow.includes(tool))).toBe(true);
    expect(narrowed.deny).toContain('previous_denial');
    expect(narrowed.blocked_tools).toContain('previous_sealed_block');
    expect(narrowed.require_approval).toContain('previous_approval');
    expect(calls.some(call => call.method === 'node.secrets.set' || call.method === 'profile.followup.admission.set' || call.method === 'profiles.get')).toBe(false);
    expect(f.store.metadata(`botPolicyFloor:${bot.id}`)).toMatchObject({ state: 'acknowledged', actorUserId: 'admin' });
    await expect(f.request('GET', `/v1/bots/${bot.id}`, undefined, f.admin)).rejects.toMatchObject({ code: 'not_found' });
    expect(f.store.require<P.Bot>('bots', bot.id)).toEqual(bot);
  });
});

describe('authenticated SCIM restriction management', () => {
  async function scimAuthority(services: BackendServices, issuer: Principal, kind: P.IntegrationToken['kind'] = 'scim', scopes = ['scim.groups']) {
    const raw = Buffer.alloc(32, 7).toString('base64url');
    const token: P.IntegrationToken = services.resource('integration_token', { name: 'Directory management fixture', kind, scopes, expiresAtMs: services.now() + 60000 });
    services.store.put('integrationTokens', token);
    services.store.put('integrationCredentials', { id: token.id, digest: createHash('sha256').update(raw).digest('hex'), workspaceId: issuer.workspaceId, issuerUserId: issuer.userId });
    const actor = await services.auth.authenticate(new Request(`${fixturePublicUrl}/scim/v2/Groups`, { headers: { Authorization: `Bearer ${raw}` } }), 'integration');
    if (!actor) throw new Error('The real authentication boundary did not accept the issued fixture integration.');
    return { actor, token };
  }
  test('a real scoped integration keeps its identity while applying only native restrictions', async () => {
    const f = fixture(), bot = f.bot();
    await syncBotProfile(f.services, f.alice, bot.id);
    const { actor } = await scimAuthority(f.services, f.admin);
    expect(actor.kind).toBe('integration'); expect(actor.role).toBe('member'); expect(actor.userId).toBe(f.admin.userId);
    f.services.integrations.workspaceRestrictions = () => ({ localExecutionCeiling: 'deny', rules: [], allowedMcpOrigins: [fixturePublicUrl], requireReview: true });
    const start = f.calls.length;
    assertWorkspaceRestrictionManagement(f.services, actor);
    await syncBotPolicyFloor(f.services, actor, bot.id);
    const writes = f.calls.slice(start).filter(call => call.mutation);
    expect(Object.keys(writes.find(call => call.method === 'profiles.update')!.params).sort()).toEqual(['id', 'toolPolicy']);
    expect(writes.some(call => call.method === 'node.secrets.set' || call.method === 'profile.followup.admission.set')).toBe(false);
    await expect(f.request('GET', `/v1/bots/${bot.id}`, undefined, actor)).rejects.toMatchObject({ code: 'not_found' });
    expect(actor.kind).toBe('integration'); expect(actor.role).toBe('member');
  });
  test('revocation, token kind, expiry, issuer binding and current membership prevent management before RPC', async () => {
    for (const invalid of ['revoked', 'expired', 'audit', 'event', 'scope', 'issuer', 'workspace', 'disabled', 'demoted'] as const) {
      const f = fixture(), bot = f.bot(), { actor, token } = await scimAuthority(f.services, f.admin);
      if (invalid === 'revoked') f.store.remove('integrationCredentials', token.id);
      if (invalid === 'expired') f.store.put('integrationTokens', { ...token, expiresAtMs: f.services.now() });
      if (invalid === 'audit') f.store.put('integrationTokens', { ...token, kind: 'audit_export', scopes: ['audit_export'] });
      if (invalid === 'event') f.store.put('integrationTokens', { ...token, kind: 'event_ingress', scopes: ['event_ingress:slack'] });
      if (invalid === 'scope') f.store.put('integrationTokens', { ...token, scopes: [] });
      if (invalid === 'issuer') f.store.put('integrationCredentials', { id: token.id, workspaceId: actor.workspaceId, issuerUserId: f.alice.userId });
      if (invalid === 'workspace') f.store.put('integrationCredentials', { id: token.id, workspaceId: 'other-workspace', issuerUserId: actor.userId });
      if (invalid === 'disabled' || invalid === 'demoted') {
        const member = f.services.auth.member(actor.userId);
        f.store.put('members', { ...member, ...(invalid === 'disabled' ? { enabled: false } : { role: 'member' as const }) });
      }
      await expect(syncBotPolicyFloor(f.services, actor, bot.id)).rejects.toMatchObject({ code: 'forbidden' });
      expect(f.calls).toHaveLength(0);
    }
  });
});
