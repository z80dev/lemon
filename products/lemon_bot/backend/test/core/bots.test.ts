import { describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../../src/core/services';
import { ApiError } from '../../src/core/errors';
import { createBotRoutes, baseBotMcpConfig, baseBotMcpTemplate, syncBotProfile, createBotService, syncBotPolicyFloor, productBotTools, assertWorkspaceRestrictionManagement, markBotProfilesForRefresh } from '../../src/core/bots';
import { createConversationRoutes } from '../../src/core/conversations';
import { effectiveBotGrants } from '../../src/core/experiences';
import { createResourceRoutes } from '../../src/core/resources';
import { createGateService } from '../../src/core/gates';
import { authFixture } from './auth.test';
import { Router } from '../../src/core/router';

interface Call { method: string; params: Record<string, unknown>; mutation: boolean }
const fixturePublicUrl = 'https://product.example';
// Fake discovery preserves the production invariant: endpoint changes change every execution alias.
function productAliases(url: string) {
  return productBotTools.map(name => ({ name, executionName: `${`mcp_lemon_bot_${name}`.slice(0, 31)}_${createHash('sha256').update(JSON.stringify(['lemon-bot', new URL(url).href, name])).digest('hex').slice(0, 32)}` }));
}
const projectedProductTools = productAliases(`${fixturePublicUrl}/mcp`);
function fixture(items: P.MachineCapabilities['items'] = [], acknowledgedWorkingDirectory?: 'node_default') {
  const f = authFixture();
  f.services.config.publicUrl = fixturePublicUrl;
  const calls: Call[] = [];
  const profileRows = new Map<string, Record<string, unknown>>();
  const secretReceipts = new Map<string, Record<string, unknown>>();
  const secretNames = new Map<string, Set<string>>();
  const issuerRows = new Map<string, { profileId: string; configured: boolean; url?: string; tokenSha256?: string }>();
  let after: ((method: string, params: Record<string, unknown>) => void) | null = null;
  let before: ((method: string, params: Record<string, unknown>) => Promise<void>) | null = null;
  let syncStatus = 'acknowledged';
  const hostFiles = new Map<string, { size: number; mtimeMs: number; dataBase64: string }>();
  let hostRevision = 0;
  let reject: ((method: string, params: Record<string, unknown>) => void) | null = null;
  let nativePresence: { active: number; queued: number; unknown: number; idle: boolean; complete: boolean } | null = { active: 0, queued: 0, unknown: 0, idle: true, complete: true };
  // Workspace preference entries: like the real store, ids end in the file revision that every deletion bumps.
  const preferences = { entries: [] as string[], revision: 1 };
  const preferenceId = (entry: string) => `pref_user_${entry}.${preferences.revision}`;
  const methods = ['profiles.create', 'profiles.update', 'profiles.get', 'profiles.sync', 'profiles.sync.status', 'profiles.delete', 'mcp.execution_names', 'profile.followup.admission.set', 'profile.followup.admission.get', 'runs.followup.lineage.get', 'runs.active.list', 'memory.transfer', 'memory.transfer.status', 'memory.list', 'memory.get', 'memory.delete', 'memory.add', 'nodes.list', 'node.capabilities.get', 'node.secrets.set', 'node.secrets.receipt', 'node.secrets.list', 'node.secrets.delete', 'node.host.info', 'node.profile.paths', 'node.fs.stat', 'node.fs.write', 'node.fs.delete', 'cron.pause', 'cron.resume', 'cron.add', 'cron.remove', 'cron.list', 'sessions.delete', 'sessions.get'];
  methods.push('node.fs.read', 'node.fs.delete.preview');
  f.services.lemon = {
    connected: true, methods,
    controller: { url: 'ws://127.0.0.1:4040/ws', state: 'connected', connectedAtMs: 1, lastDisconnectedAtMs: null, lastError: null, nextRetryAtMs: null, methodCount: 0 }, reconnect() {},
    async call<T>(method: string, params: Record<string, unknown> = {}, options?: { mutation?: boolean }): Promise<T> {
      calls.push({ method, params, mutation: options?.mutation === true }); reject?.(method, params);
      await before?.(method, params);
      let value: unknown;
      if (method === 'profiles.create' || method === 'profiles.update') {
        const profileId = String(params.id);
        const profile: Record<string, unknown> = { canonicalSessionKey: `agent:${profileId}:main`, ...profileRows.get(profileId), ...params };
        const definitions = profile.mcpServers as { name: string; url: string; headers: Record<string, string>; enabledTools?: string[]; allowedOrigins?: string[]; approvedPrivateOrigins?: string[] }[] | undefined;
        const canonical = (definitions ?? []).map(server => [server.name, server.url, Object.entries(server.headers).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0), server.enabledTools ?? null, server.allowedOrigins ?? null, server.approvedPrivateOrigins ?? null]);
        const acknowledged = { ...profile, ...(acknowledgedWorkingDirectory ? { workingDirectory: acknowledgedWorkingDirectory } : {}), mcpConfigFingerprint: createHash('sha256').update(JSON.stringify(canonical)).digest('hex') };
        profileRows.set(profileId, acknowledged); value = { profile: acknowledged };
      } else if (method === 'profiles.get') {
        const profile = profileRows.get(String(params.id));
        if (!profile) throw new ApiError('not_found', 'Profile absent.');
        const definitions = profile.mcpServers as { name: string; url: string; headers: Record<string, string>; enabledTools?: string[]; allowedOrigins?: string[]; approvedPrivateOrigins?: string[] }[] | undefined;
        const canonical = (definitions ?? []).map(server => [server.name, server.url, Object.entries(server.headers).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0), server.enabledTools ?? null, server.allowedOrigins ?? null, server.approvedPrivateOrigins ?? null]);
        value = { profile: { ...profile, mcpConfigFingerprint: createHash('sha256').update(JSON.stringify(canonical)).digest('hex') } };
      }
      else if (method === 'profiles.sync') value = { profileId: params.id, nodeId: params.nodeId, mutationId: params.mutationId, acknowledged: true, revisionDigest: 'a'.repeat(64) };
      else if (method === 'profiles.sync.status') value = { profileId: params.id, nodeId: params.nodeId, mutationId: params.mutationId, status: syncStatus, acknowledged: syncStatus === 'acknowledged', revisionDigest: syncStatus === 'unknown' ? null : 'a'.repeat(64) };
      else if (method === 'profile.followup.admission.set') {
        issuerRows.set(String(params.profileId), { profileId: String(params.profileId), configured: true, url: String(params.url), tokenSha256: createHash('sha256').update(String(params.token), 'utf8').digest('hex') });
        value = { profileId: params.profileId, configured: true };
      }
      else if (method === 'profile.followup.admission.get') value = issuerRows.get(String(params.profileId)) ?? { profileId: params.profileId, configured: false };
      else if (method === 'mcp.execution_names') {
        expect(params).toEqual({ server: { name: 'lemon-bot', url: new URL('/mcp', f.services.config.publicUrl).toString() }, toolNames: [...productBotTools] });
        value = { server: { name: 'lemon-bot' }, tools: productAliases(new URL('/mcp', f.services.config.publicUrl).toString()), count: productBotTools.length };
      }
      else if (method === 'node.secrets.set') {
        value = { name: params.name, set: true, operationId: params.operationId, status: 'applied', currentBindingMatches: true };
        secretReceipts.set(`${params.nodeId}:${params.operationId}`, { nodeId: params.nodeId, ...value as object });
        const names = secretNames.get(String(params.nodeId)) ?? new Set<string>(); names.add(String(params.name)); secretNames.set(String(params.nodeId), names);
      }
      else if (method === 'node.secrets.receipt') value = secretReceipts.get(`${params.nodeId}:${params.operationId}`) ?? { nodeId: params.nodeId, operationId: params.operationId, status: 'not_found', name: null, currentBindingMatches: false };
      else if (method === 'node.secrets.list') value = { names: [...secretNames.get(String(params.nodeId)) ?? []], limit: 1000, truncated: false };
      else if (method === 'node.secrets.delete') { secretNames.get(String(params.nodeId))?.delete(String(params.name)); value = { name: params.name, deleted: true }; }
      else if (method === 'runs.active.list') value = { runs: [], filters: { profileId: params.profileId, limit: params.limit }, ...(nativePresence ? { presence: nativePresence } : {}) };
      else if (method === 'node.profile.paths') value = { nodeId: params.nodeId, profileId: params.profileId, workspacePath: `/worker/profiles/${params.profileId}/workspace`, skillsPath: `/worker/profiles/${params.profileId}/workspace/.lemon/skill` };
      else if (method === 'nodes.list') value = { nodes: f.store.list<P.Machine>('machines', machine => !params.nodeId || machine.nodeId === params.nodeId).map(machine => ({ id: machine.nodeId, status: machine.status, capabilities: ['node.capabilities.get'] })), summary: { presenceAvailable: true, truncated: false } };
      else if (method === 'node.capabilities.get') value = { nodeId: params.nodeId, os: 'linux', measuredAtMs: f.services.now(), stale: false, items };
      else if (method === 'node.host.info') value = { defaultCwd: '/home/lemon' };
      else if (method === 'node.fs.stat') {
        const file = hostFiles.get(`${params.nodeId}:${params.path}`);
        if (!file) throw new ApiError('not_found', 'Managed file does not exist.');
        value = { path: params.path, type: 'regular', size: file.size, mtimeMs: file.mtimeMs };
      } else if (method === 'node.fs.read') {
        const file = hostFiles.get(`${params.nodeId}:${params.path}`);
        if (!file) throw new ApiError('not_found', 'Managed file does not exist.');
        const offset = Number(params.offset ?? 0), bytes = Buffer.from(file.dataBase64, 'base64').subarray(offset, offset + Number(params.length ?? file.size));
        value = { path: params.path, dataBase64: bytes.toString('base64'), offset, length: bytes.length, size: file.size, mime: 'text/markdown', eof: offset + bytes.length === file.size };
      } else if (method === 'node.fs.write') {
        const key = `${params.nodeId}:${params.path}`, previous = hostFiles.get(key);
        if (params.expectedModifiedAtMs !== (previous?.mtimeMs ?? 0)) throw new ApiError('revision_conflict', 'Managed file changed before write.');
        const size = Buffer.from(String(params.dataBase64), 'base64').length, mtimeMs = f.services.now() + ++hostRevision;
        hostFiles.set(key, { size, mtimeMs, dataBase64: String(params.dataBase64) }); value = { path: params.path, bytesWritten: size, size, mtimeMs };
      } else if (method === 'node.fs.delete.preview') {
        const file = hostFiles.get(`${params.nodeId}:${params.path}`);
        if (!file) throw new ApiError('not_found', 'Managed file does not exist.');
        value = { path: params.path, stat: { mtimeMs: file.mtimeMs }, confirmationToken: 'skill_delete_confirmation_token', expiresAtMs: f.services.now() + 60000 };
      } else if (method === 'node.fs.delete') { hostFiles.delete(`${params.nodeId}:${params.path}`); value = { path: params.path, deleted: true }; }
      else if (method === 'memory.transfer') {
        const identity = { profileId: params.profileId, nodeId: params.nodeId, mutationId: params.mutationId, sourceNodeId: 'node-source', snapshotDigest: 'b'.repeat(64) };
        value = params.action === 'preview' ? { ...identity, destinationDigest: 'c'.repeat(64), confirmationToken: 'memory-confirmation-test', sourceCounts: { documents: 2, preferences: 2 }, destinationCounts: { documents: 3, preferences: 1 }, overwrite: true } : { ...identity, copied: true };
      } else if (method === 'memory.list') value = { items: preferences.entries.map(entry => ({ id: preferenceId(entry), updatedAtMs: 1 })), nextCursor: null };
      else if (method === 'memory.get') { if (!preferences.entries.some(entry => preferenceId(entry) === params.id)) throw new ApiError('not_found', 'Memory absent.'); value = { item: { id: params.id } }; }
      else if (method === 'memory.delete') {
        const index = preferences.entries.findIndex(entry => preferenceId(entry) === params.id);
        if (index < 0) throw new ApiError('not_found', 'Memory item changed; read it again before deleting.');
        preferences.entries.splice(index, 1); preferences.revision++; value = { id: params.id, deleted: true };
      }
      else if (method === 'cron.pause') value = { id: params.id, paused: true, enabled: false, nextRunAtMs: null };
      else if (method === 'cron.resume') value = { id: params.id, resumed: true, enabled: true, nextRunAtMs: f.services.now() + 3600000 };
      else if (method === 'cron.remove') value = { id: params.id, removed: true };
      else if (method === 'cron.list') value = { jobs: [] };
      else if (method === 'sessions.delete') value = { sessionKey: params.sessionKey, deleted: true, summary: { verified: true } };
      else if (method === 'sessions.get') { throw new ApiError('not_found', 'Session absent.'); }
      else if (method === 'profiles.delete') { profileRows.delete(String(params.id)); value = { deleted: { id: params.id } }; }
      else throw new Error(`Unexpected external method in bot lifecycle test: ${method}`);
      after?.(method, params);
      return value as T;
    },
    onEvent: () => () => {}, onConnected: () => () => {}, start() {}, close() {},
  };
  const unavailable = (): never => { throw new Error('This test did not supply the requested external operation.'); };
  f.services.runtime = { submit: unavailable, send: unavailable, cancel: unavailable, reconcile: unavailable, revokeConnectorInvocations: unavailable, sessionKey: (_room, bot) => `agent:${bot.profileId}:main` };
  f.services.integrations.connectorConfig = async () => [];
  f.services.integrations.connectorTemplates = async () => [];
  f.services.integrations.effectivePolicy = async (actor, botId) => ({ userId: actor.userId, botId: botId ?? null, directoryGroupIds: [], productAccess: true, localExecutionCeiling: 'ask', workspaceReads: 'allow', allowSudo: false, allowEgress: false, rules: [], networkPolicies: [], explanations: [] });
  f.services.integrations.emitProviderNotifications = async () => {};
  f.services.syncBotProfile = (actor, botId) => syncBotProfile(f.services, actor, botId);
  const routes: Route[] = [...createBotRoutes(f.services), ...createConversationRoutes(f.services), ...createResourceRoutes(f.services)];
  const router = new Router(f.services);
  router.register(routes);
  const sessions = new Map<string, string>();
  async function request<T>(method: string, path: string, body: unknown, actor: Principal | null = f.alice): Promise<T> {
    let token = actor ? sessions.get(actor.userId) : undefined;
    if (actor && !token) { token = (await f.services.auth.session(actor.userId)).token; sessions.set(actor.userId, token); }
    const response = await router.fetch(new Request(new URL(path, f.services.config.publicUrl), { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
    const payload = await response.json();
    if (!response.ok) {
      const { error } = payload as P.ErrorEnvelope;
      throw new ApiError(error.code, error.message, error.retrySafe, error.details);
    }
    return payload as T;
  }
  function machine(machineId: string, nodeId: string, shared = false): P.Machine {
    const labels: Record<string, string> = shared ? { 'lemon_bot.shared_context': 'true' } : {};
    const row: P.Machine = { ...f.services.resource('machine', { nodeId, nodeName: nodeId, name: machineId, ownerUserId: 'alice', accessUserIds: ['admin'], status: 'online' as const, lastSeenAtMs: f.services.now(), labels, botIds: [], link: { kind: 'direct' as const } }), id: machineId };
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
  return { ...f, calls, request, router, machine, bot, preferences, issuerRows, secretReceipts, before: (value: typeof before) => { before = value; }, failAfter: (value: typeof after) => { after = value; }, syncStatus: (value: string) => { syncStatus = value; }, fail: (value: typeof reject) => { reject = value; }, presence: (value: typeof nativePresence) => { nativePresence = value; } };
}
const nonce = (suffix: string) => `bot_test_nonce_${suffix}`;
function confirmed(confirmation: P.Confirmation, extra: Record<string, unknown> = {}) { return { clientNonce: nonce('confirm'), revision: confirmation.revision, confirmationToken: confirmation.confirmationToken, confirmName: confirmation.confirmName, ...extra }; }

describe('bot authority and viewer state', () => {
  test('loopback MCP accepts only proven same-host workers or an exact SSH product port',()=>{
    const f=fixture();f.services.config.publicUrl='http://127.0.0.1:4100';
    const direct=f.store.require<P.Machine>('machines','machine');
    const tunnel:P.Machine={...direct,link:{kind:'ssh_tunnel',sshDestination:'me@worker',nodePort:4044,productPort:4100,tunnel:{state:'online',detail:null,checkedAtMs:1}}};
    try {
      expect(()=>baseBotMcpTemplate(f.services,direct)).toThrow();
      const accepted=baseBotMcpTemplate(f.services,tunnel);
      expect(accepted).toMatchObject({url:'http://127.0.0.1:4100/mcp',headers:{},allowedOrigins:['http://127.0.0.1:4100'],approvedPrivateOrigins:['http://127.0.0.1:4100']});
      if(tunnel.link?.kind!=='ssh_tunnel')throw new Error('Expected SSH tunnel fixture.');
      const link=tunnel.link;
      for(const productPort of [null,4101]){
        expect(()=>baseBotMcpTemplate(f.services,{...tunnel,link:{...link,productPort}})).toThrow();
      }
      f.store.setMetadata(`machineSameHost:${direct.id}`,direct.nodeId);
      expect(baseBotMcpTemplate(f.services,direct).url).toBe(accepted.url);
      f.services.config.publicUrl='http://localhost:4100';
      expect(()=>baseBotMcpTemplate(f.services,tunnel)).toThrow();
      f.services.config.publicUrl='https://product.example';
      expect(baseBotMcpTemplate(f.services,direct)).toMatchObject({url:'https://product.example/mcp',approvedPrivateOrigins:[]});
    } finally {f.store.close();}
  });
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

function standardCapabilities(): P.MachineCapabilities['items'] {
  return [
    { id: 'terminal', name: 'Terminal', category: 'shell', tools: ['bash', 'bash_output', 'kill_process'] },
    { id: 'files', name: 'Files', category: 'files', tools: ['read', 'write', 'edit'] },
    { id: 'browser', name: 'Browser', category: 'browser', tools: ['browser_snapshot', 'browser_click'] },
  ].map(item => ({ ...item, supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', reason: 'measured', measuredAtMs: 1700000000000, stale: false })) as P.MachineCapabilities['items'];
}
const standardRequested: Record<string, P.AccessLevel> = { terminal: 'read_interact', files: 'read_interact', browser: 'read_only' };
function requestedLevels(f: Pick<BackendServices, 'store'>, botId?: string) {
  return Object.fromEntries(f.store.list<P.BotGrant>('botGrants', grant => !botId || grant.botId === botId).map(grant => [grant.capabilityId, grant.requestedLevel]));
}
describe('creation access consent and first-run policy', () => {
  test('Standard persists requested grants before the first policy projection and profile synchronization', async () => {
    const f = fixture(standardCapabilities());
    let policyProjected = false;
    f.fail(method => {
      if (method === 'mcp.execution_names' || method === 'profiles.create' || method === 'profiles.sync') {
        expect(requestedLevels(f)).toEqual(standardRequested);
        policyProjected = true;
      }
    });
    const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('standard'), name: 'Lemon', machineId: 'machine', access: 'standard' });
    expect(policyProjected).toBe(true);
    const policy = f.calls.find(call => call.method === 'profiles.create')!.params.toolPolicy as { allow: string[]; deny: string[]; require_approval: string[] };
    expect(policy.allow).toContain('bash'); expect(policy.require_approval).toContain('bash');
    expect(policy.allow).toContain('write'); expect(policy.allow).toContain('browser_snapshot'); expect(policy.deny).toContain('browser_click');
    for (const grant of f.store.list<P.BotGrant>('botGrants', grant => grant.botId === bot.id)) {
      expect(grant.id).toBe(`grant_${f.services.mutations.digest({ botId: bot.id, machineId: bot.machineId, capabilityId: grant.capabilityId }).slice(0, 48)}`);
      expect(grant.effectiveLevel).toBe('off');
    }
  });
  test('Standard keeps machine and workspace ceilings without reducing requested consent', async () => {
    for (const denied of [false, true]) {
      const items = standardCapabilities();
      items[1]!.configuredLevel = 'read_only'; items[2]!.osGrant = 'denied';
      const f = fixture(items), effective = f.services.integrations.effectivePolicy;
      if (denied) f.services.integrations.effectivePolicy = async (actor, botId) => ({ ...await effective(actor, botId), localExecutionCeiling: 'deny' });
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce(`capped_${denied}`), name: 'Capped', machineId: 'machine', access: 'standard' });
      const grants = await effectiveBotGrants(f.services, f.alice, bot);
      expect(requestedLevels(f, bot.id)).toEqual(standardRequested);
      expect(Object.fromEntries(grants.map(grant => [grant.capabilityId, grant.effectiveLevel]))).toEqual({ terminal: denied ? 'off' : 'read_interact', files: denied ? 'off' : 'read_only', browser: 'off' });
      const policy = f.calls.find(call => call.method === 'profiles.create')!.params.toolPolicy as { allow: string[]; deny: string[] };
      expect(policy.deny).toContain('write'); expect(policy.deny).toContain('browser_snapshot');
      expect(policy.allow.includes('bash')).toBe(!denied);
    }
  });
  test('unknown and unsupported capabilities are skipped without failing creation', async () => {
    const items = standardCapabilities();
    items[0]!.supported = false; items.push({ ...items[1]!, id: 'unrecognized-files' });
    const f = fixture(items);
    const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('unsupported'), name: 'Portable', machineId: 'machine', access: 'standard' });
    expect(requestedLevels(f, bot.id)).toEqual({ terminal: 'off', files: 'read_interact', browser: 'read_only', 'unrecognized-files': 'off' });
  });
  for (const access of [undefined, 'none'] as const) {
    test(`${access ?? 'omitted'} access keeps all grants off`, async () => {
      const f = fixture(standardCapabilities());
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce(`off_${access}`), name: 'Chat only', machineId: 'machine', ...(access ? { access } : {}) });
      expect(requestedLevels(f, bot.id)).toEqual({ terminal: 'off', files: 'off', browser: 'off' });
      const policy = f.calls.find(call => call.method === 'profiles.create')!.params.toolPolicy as { deny: string[] };
      expect(policy.deny).toContain('bash');
    });
  }
  for (const mode of ['json', 'duplicate', 'template', 'templateId'] as const) {
    for (const access of ['standard', 'none', undefined] as const) {
      test(`${mode} creation honors ${access ?? 'omitted'} access rather than template suggestions`, async () => {
        const f = fixture(standardCapabilities()), source = f.bot();
        const content = await f.request<P.TemplateContent>('GET', `/v1/bots/${source.id}/export`, undefined);
        content.suggestedAccess = access === 'standard' ? 'none' : 'standard';
        const template: P.BotTemplate = f.services.resource('template', { ownerUserId: 'alice', audience: 'workspace', sourceBotId: source.id, content, provenance: { publisher: 'Alice', sourceUrl: null, termsUrl: null, thirdParty: false }, shareUrl: `${fixturePublicUrl}/template` });
        f.store.put('templates', template);
        const input = { clientNonce: nonce(`copy_${mode}_${access}`), name: 'Copy', machineId: 'destination', ...(access ? { access } : {}) };
        const bot = mode === 'json'
          ? await f.request<P.Bot>('POST', '/v1/bots/import', { ...input, content, acceptedTerms: true })
          : mode === 'duplicate'
            ? await f.request<P.Bot>('POST', `/v1/bots/${source.id}/duplicate`, { ...input, includeSkills: false, includeRoutines: false })
            : mode === 'template'
              ? await f.request<P.Bot>('POST', `/v1/templates/${template.id}/import`, { ...input, acceptedTerms: true })
              : await f.request<P.Bot>('POST', '/v1/bots', { ...input, templateId: template.id });
        expect(requestedLevels(f, bot.id)).toEqual(access === 'standard' ? standardRequested : { terminal: 'off', files: 'off', browser: 'off' });
        const policy = f.calls.find(call => call.method === 'profiles.create')!.params.toolPolicy as { allow: string[] };
        expect(policy.allow.includes('bash')).toBe(access === 'standard');
      });
    }
  }
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
  test('missing avatar provider gives owner guidance and creates no artifact', async () => {
    const f = fixture(), bot = f.bot(), previous = process.env.LEMON_BOT_IMAGE_PROVIDER;
    delete process.env.LEMON_BOT_IMAGE_PROVIDER;
    try {
      await expect(f.request('POST', `/v1/bots/${bot.id}/avatar/generate`, { clientNonce: nonce('avatar_prerequisite'), prompt: 'A friendly character' })).rejects.toMatchObject({ code: 'capability_unavailable', retrySafe: true, message: 'Image generation is not enabled on this Lemon Bot server. Ask the operator to configure an image provider.' });
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
    f.store.setMetadata('nodeRuntimeFeatures:machine', { nodeId: 'node-source', features: { botFolder: true } });
    f.fail((method) => { if (method === 'profiles.sync') throw new ApiError('outcome_unknown', 'Persona receipt lost.', false); });
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('lost_persona'), revision: bot.revision, job: 'Approved new job' })).rejects.toMatchObject({ code: 'outcome_unknown' });
    f.fail(null);
    for (const key of ['botPublicMcpCeiling', 'botControllerFloor', 'botWorkingDirectory', 'profileCanonicalSession']) f.store.setMetadata(`${key}:${bot.id}`, null);
    const writes = f.calls.filter(call => call.method === 'profiles.update' || call.method === 'profiles.sync').length;
    await createBotService(f.services).reconcile();
    expect(f.calls.filter(call => call.method === 'profiles.update' || call.method === 'profiles.sync')).toHaveLength(writes);
    expect(f.calls.some(call => call.method === 'profiles.sync.status')).toBe(true);
    expect(f.store.require<P.Bot>('bots', bot.id).job).toBe('Approved new job');
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).toBeNull();
    expect(f.store.metadata(`botPublicMcpCeiling:${bot.id}`)).toMatchObject({ servers: [{ name: 'lemon-bot', enabledTools: [...productBotTools] }] });
    expect(f.store.metadata(`botControllerFloor:${bot.id}`)).toEqual((f.store.metadata<{ toolPolicy: P.JSONObject }>(`botDesiredProfile:${bot.id}`))!.toolPolicy);
    expect(f.store.metadata(`botWorkingDirectory:${bot.id}`)).toEqual({ mode: 'profile_files', machineId: bot.machineId, profileId: bot.profileId });
    expect(f.store.metadata(`profileCanonicalSession:${bot.id}`)).toBe(`agent:${bot.profileId}:main`);
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
  test('forgetting memory removes every previewed preference even though each deletion renames the rest', async () => {
    const f = fixture(), bot = f.bot();
    f.preferences.entries.push('name', 'timezone', 'pronouns');
    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('preferences_preview'), action: 'reset', resetScopes: ['memory'] });
    await f.request('POST', `/v1/bots/${bot.id}/reset`, confirmed(preview, { clientNonce: nonce('preferences_reset'), resetScopes: ['memory'] }));
    expect(f.preferences.entries).toEqual([]);
    expect(f.calls.filter(call => call.method === 'memory.delete')).toHaveLength(3);
  });
  test('a preference added after the preview stops memory deletion and is kept', async () => {
    const f = fixture(), bot = f.bot();
    f.preferences.entries.push('name');
    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('late_preview'), action: 'reset', resetScopes: ['memory'] });
    f.preferences.entries.push('added-later');
    await expect(f.request('POST', `/v1/bots/${bot.id}/reset`, confirmed(preview, { clientNonce: nonce('late_reset'), resetScopes: ['memory'] }))).rejects.toThrow(ApiError);
    expect(f.preferences.entries).toEqual(['name', 'added-later']);
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

describe('unfinished Bot creation recovery', () => {
  test('a create stopped by a definite refusal stays fenced, explains itself, and deletes through the product path', async () => {
    const f = fixture(); const gates = createGateService(f.services); f.services.gates = gates;
    try {
      f.fail(method => { if (method === 'profile.followup.admission.set') throw new ApiError('invalid_request', 'Admission callback origin refused.'); });
      await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('refused_issuer'), name: 'Probe', machineId: 'machine' })).rejects.toMatchObject({ code: 'invalid_request' });
      f.fail(null);
      const bot = f.store.list<P.Bot>('bots')[0]!;
      await createBotService(f.services).reconcile();
      expect(f.store.metadata(`botLifecycle:${bot.id}`)).toMatchObject({ action: 'create', status: 'failed' });
      expect(f.calls.filter(call => call.method === 'profile.followup.admission.set')).toHaveLength(1);
      await expect(f.request('POST', `/v1/conversations/${bot.mainConversationId}/messages`, { clientNonce: nonce('setup_message'), text: 'hello' })).rejects.toMatchObject({ code: 'conflict', retrySafe: true, message: expect.stringContaining('setup didn’t finish') });
      const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('unfinished_preview'), action: 'delete' });
      await f.request('DELETE', `/v1/bots/${bot.id}`, confirmed(preview, { clientNonce: nonce('unfinished_delete') }));
      expect(f.store.get('bots', bot.id)).toBeNull();
      expect(f.store.metadata(`botLifecycle:${bot.id}`)).toBeNull();
      expect(f.calls.some(call => call.method === 'profiles.delete' && call.params.id === bot.profileId)).toBe(true);
    } finally { gates.close(); }
  });
  test('a create that never reached profiles.create deletes once the controller proves the profile absent', async () => {
    const f = fixture(); const gates = createGateService(f.services); f.services.gates = gates;
    try {
      f.fail(method => { if (method === 'profiles.create') throw new ApiError('invalid_request', 'Profile refused.'); });
      await expect(f.request('POST', '/v1/bots', { clientNonce: nonce('refused_profile'), name: 'Pip', machineId: 'machine' })).rejects.toMatchObject({ code: 'invalid_request' });
      const bot = f.store.list<P.Bot>('bots')[0]!;
      f.fail(method => { if (method === 'memory.list' || method === 'profiles.delete') throw new ApiError('not_found', 'Profile absent.'); });
      const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('absent_preview'), action: 'delete' });
      await f.request('DELETE', `/v1/bots/${bot.id}`, confirmed(preview, { clientNonce: nonce('absent_delete') }));
      expect(f.store.get('bots', bot.id)).toBeNull();
    } finally { gates.close(); }
  });
  test('an interrupted create whose every effect the controller acknowledges becomes ready without replay', async () => {
    const f = fixture();
    const created = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('interrupted_create'), name: 'Kiwi', machineId: 'machine' });
    // The process died after the last acknowledged effect, before it marked the Bot ready.
    const desired = f.store.metadata<{ lifecycleId: string }>(`botDesiredProfile:${created.id}`)!;
    f.store.put('bots', { ...f.store.require<P.Bot>('bots', created.id), activity: 'offline' });
    f.store.setMetadata(`botLifecycle:${created.id}`, { id: desired.lifecycleId, action: 'create', userId: 'alice', revision: 1, status: 'running', resourceIds: [created.id] });
    const mutations = f.calls.filter(call => call.mutation).length;
    await createBotService(f.services).reconcile();
    expect(f.store.metadata(`botLifecycle:${created.id}`)).toBeNull();
    expect(f.store.require<P.Bot>('bots', created.id).activity).toBe('idle');
    expect(f.store.require<P.Machine>('machines', 'machine').botIds).toContain(created.id);
    expect(f.calls.filter(call => call.mutation)).toHaveLength(mutations);
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
      return { localExecutionCeiling: 'deny', rules: [], allowedMcpOrigins: [fixturePublicUrl], requireReview: true, folderReadsNeedReview: false };
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
    f.services.integrations.workspaceRestrictions = () => ({ localExecutionCeiling: 'deny', rules: [], allowedMcpOrigins: [fixturePublicUrl], requireReview: true, folderReadsNeedReview: false });
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
describe('approval review projection and lifecycle invalidation', () => {
  test('botDto projects approvalReview derived from active bot allowance else metadata default per_chat', async () => {
    const f = fixture(), bot = f.bot();
    const fetchedDefault = await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined);
    expect(fetchedDefault.approvalReview).toBe('per_chat');

    f.store.setMetadata(`botApprovalReview:${bot.id}`, 'every_time');
    const fetchedEveryTime = await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined);
    expect(fetchedEveryTime.approvalReview).toBe('every_time');

    const botAllowance: P.ApprovalAllowance = f.services.resource<Omit<P.ApprovalAllowance, keyof P.Resource>>('allowance', {
      scope: 'bot',
      botId: bot.id,
      conversationId: null,
      ownerUserId: bot.ownerUserId,
      toolGroups: ['terminal', 'file_changes', 'file_reading'],
      label: 'Standing approval for Terminal and files',
      state: 'active',
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: null,
      createdByUserId: bot.ownerUserId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    f.store.put('approvalAllowances', botAllowance);
    const fetchedBotWide = await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined);
    expect(fetchedBotWide.approvalReview).toBe('bot_wide');
  });

  test('bot move eagerly ends active approval allowances with bot_moved', async () => {
    const f = fixture(), bot = f.bot();
    const allowance: P.ApprovalAllowance = f.services.resource<Omit<P.ApprovalAllowance, keyof P.Resource>>('allowance', {
      scope: 'chat',
      botId: bot.id,
      conversationId: bot.mainConversationId,
      ownerUserId: bot.ownerUserId,
      toolGroups: ['terminal'],
      label: 'Terminal allowed in this chat',
      state: 'active',
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: 'appr_1',
      createdByUserId: bot.ownerUserId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    f.store.put('approvalAllowances', allowance);
    const plan = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('move_allowance_preview'), action: 'move', targetMachineId: 'destination' });
    await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/move`, confirmed(plan, { machineId: 'destination' }));
    const ended = f.store.require<P.ApprovalAllowance>('approvalAllowances', allowance.id);
    expect(ended.state).toBe('ended');
    expect(ended.endedReason).toBe('bot_moved');
  });

  test('bot reset removes bot allowances and clears review metadata', async () => {
    const f = fixture(), bot = f.bot();
    const allowance: P.ApprovalAllowance = f.services.resource<Omit<P.ApprovalAllowance, keyof P.Resource>>('allowance', {
      scope: 'chat',
      botId: bot.id,
      conversationId: bot.mainConversationId,
      ownerUserId: bot.ownerUserId,
      toolGroups: ['terminal'],
      label: 'Terminal allowed in this chat',
      state: 'active',
      endedReason: null,
      endedAtMs: null,
      endedByUserId: null,
      sourceApprovalId: 'appr_1',
      createdByUserId: bot.ownerUserId,
      useCount: 0,
      lastUsedAtMs: null,
    });
    f.store.put('approvalAllowances', allowance);
    f.store.setMetadata(`approvalAllowanceBinding:${allowance.id}`, { contextKey: 'ctx_key' });
    f.store.setMetadata(`botApprovalReview:${bot.id}`, 'every_time');

    const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('reset_allowance_preview'), action: 'reset', resetScopes: ['job'] });
    await f.request('POST', `/v1/bots/${bot.id}/reset`, confirmed(preview, { resetScopes: ['job'] }));

    expect(f.store.get('approvalAllowances', allowance.id)).toBeNull();
    expect(f.store.metadata(`approvalAllowanceBinding:${allowance.id}`)).toBeNull();
    expect(f.store.metadata(`botApprovalReview:${bot.id}`)).toBeNull();
  });

  test('bot delete removes bot allowances and clears review metadata', async () => {
    const f = fixture(), bot = f.bot();
    const gates = createGateService(f.services); f.services.gates = gates;
    try {
      const allowance: P.ApprovalAllowance = f.services.resource<Omit<P.ApprovalAllowance, keyof P.Resource>>('allowance', {
        scope: 'chat',
        botId: bot.id,
        conversationId: bot.mainConversationId,
        ownerUserId: bot.ownerUserId,
        toolGroups: ['terminal'],
        label: 'Terminal allowed in this chat',
        state: 'active',
        endedReason: null,
        endedAtMs: null,
        endedByUserId: null,
        sourceApprovalId: 'appr_1',
        createdByUserId: bot.ownerUserId,
        useCount: 0,
        lastUsedAtMs: null,
      });
      f.store.put('approvalAllowances', allowance);
      f.store.setMetadata(`approvalAllowanceBinding:${allowance.id}`, { contextKey: 'ctx_key' });
      f.store.setMetadata(`botApprovalReview:${bot.id}`, 'every_time');
      const access = f.services.resource('access', { botId: bot.id, state: 'queued' });
      f.store.put('accessRequests', access);
      f.store.setMetadata(`profileRefresh:${bot.id}`, true);
      f.store.setMetadata(`botWorkingDirectory:${bot.id}`, { mode: 'profile_files', machineId: bot.machineId, profileId: bot.profileId });

      const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('delete_allowance_preview'), action: 'delete' });
      await f.request('DELETE', `/v1/bots/${bot.id}`, confirmed(preview));

      expect(f.store.get('approvalAllowances', allowance.id)).toBeNull();
      expect(f.store.metadata(`approvalAllowanceBinding:${allowance.id}`)).toBeNull();
      expect(f.store.metadata(`botApprovalReview:${bot.id}`)).toBeNull();
      expect(f.store.get('accessRequests', access.id)).toBeNull();
      expect(f.store.metadata(`profileRefresh:${bot.id}`)).toBeNull();
      expect(f.store.metadata(`botWorkingDirectory:${bot.id}`)).toBeNull();
    } finally { gates.close(); }
  });
});

describe('feature-gated Bot working folders and startup refresh', () => {
  for (const botFolder of [undefined, false, true]) {
    test(`create and sync gate workingDirectory on botFolder=${botFolder}`, async () => {
      const f = fixture();
      if (botFolder !== undefined) f.store.setMetadata('nodeRuntimeFeatures:machine', { nodeId: 'node-source', features: { botFolder } });
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce(`folder_${botFolder}`), name: 'Folder', machineId: 'machine' });
      await syncBotProfile(f.services, f.alice, bot.id);
      for (const call of f.calls.filter(call => call.method === 'profiles.create' || call.method === 'profiles.update')) {
        if (botFolder === true) expect(call.params.workingDirectory).toBe('profile_files');
        else expect(Object.hasOwn(call.params, 'workingDirectory')).toBe(false);
        expect(String(call.params.systemPrompt)).toContain('call request_access once');
      }
      expect(f.store.metadata(`botWorkingDirectory:${bot.id}`)).toEqual(botFolder === true ? { mode: 'profile_files', machineId: bot.machineId, profileId: bot.profileId } : null);
      markBotProfilesForRefresh(f.services);
      expect(f.store.metadata(`profileRefresh:${bot.id}`)).toBeNull();
    });
  }
  test('an incorrect folder acknowledgement remains outcome unknown and never syncs', async () => {
    const f = fixture([], 'node_default'), bot = f.bot();
    f.store.setMetadata('nodeRuntimeFeatures:machine', { nodeId: 'node-source', features: { botFolder: true } });
    await expect(syncBotProfile(f.services, f.alice, bot.id)).rejects.toMatchObject({ code: 'outcome_unknown' });
    expect(f.calls.some(call => call.method === 'profiles.sync')).toBe(false);
    expect(f.store.metadata(`botWorkingDirectory:${bot.id}`)).toBeNull();
  });
  test('startup marks missing, stale and extra tool ceilings without issuing mutations', async () => {
    for (const tools of [[], productBotTools.filter(tool => tool !== 'request_access'), [...productBotTools, 'unexpected']]) {
      const f = fixture(), bot = f.bot();
      f.store.setMetadata(`botPublicMcpCeiling:${bot.id}`, { servers: [{ name: 'lemon-bot', enabledTools: tools }] });
      markBotProfilesForRefresh(f.services);
      expect(f.store.metadata(`profileRefresh:${bot.id}`)).toBe(true);
      expect(f.calls).toHaveLength(0);
    }
  });
  test('startup marks a newly supported or stale placement folder, not a current folder', async () => {
    const f = fixture(), bot = f.bot();
    f.store.setMetadata(`botPublicMcpCeiling:${bot.id}`, { servers: [{ name: 'lemon-bot', enabledTools: [...productBotTools].reverse() }] });
    markBotProfilesForRefresh(f.services);
    expect(f.store.metadata(`profileRefresh:${bot.id}`)).toBeNull();
    f.store.setMetadata('nodeRuntimeFeatures:machine', { nodeId: 'node-source', features: { botFolder: true } });
    for (const directory of [null, { mode: 'profile_files', machineId: 'old-machine', profileId: bot.profileId }, { mode: 'profile_files', machineId: bot.machineId, profileId: 'old-profile' }]) {
      f.store.setMetadata(`botWorkingDirectory:${bot.id}`, directory);
      markBotProfilesForRefresh(f.services);
      expect(f.store.metadata(`profileRefresh:${bot.id}`)).toBe(true);
      f.store.setMetadata(`profileRefresh:${bot.id}`, null);
    }
    await syncBotProfile(f.services, f.alice, bot.id);
    markBotProfilesForRefresh(f.services);
    expect(f.store.metadata(`profileRefresh:${bot.id}`)).toBeNull();
  });
  for (const lostReceipt of [false, true]) {
    test(`moving a folder-enabled Bot to an older worker requires a default-directory receipt (lost=${lostReceipt})`, async () => {
      const f = fixture(standardCapabilities());
      f.store.setMetadata('nodeRuntimeFeatures:machine', { nodeId: 'node-source', features: { botFolder: true } });
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce(`downgrade_create_${lostReceipt}`), name: 'Portable', machineId: 'machine', access: 'standard' });
      const plan = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`downgrade_preview_${lostReceipt}`), action: 'move', targetMachineId: 'destination' });
      const start = f.calls.length;
      if (lostReceipt) f.fail((method, params) => { if (method === 'profiles.update' && params.workingDirectory === 'node_default') throw new ApiError('outcome_unknown', 'Directory reset receipt lost.', false); });
      const move = f.request<P.Bot>('POST', `/v1/bots/${bot.id}/move`, confirmed(plan, { machineId: 'destination' }));
      if (lostReceipt) {
        await expect(move).rejects.toMatchObject({ code: 'outcome_unknown' });
        expect(f.store.require<P.Bot>('bots', bot.id).machineId).toBe('machine');
        expect(f.store.metadata(`botLifecycle:${bot.id}`)).toMatchObject({ status: 'outcome_unknown' });
        expect(f.calls.slice(start).some(call => call.method === 'profiles.sync' && call.params.nodeId === 'node-destination')).toBe(false);
      } else {
        expect((await move).machineId).toBe('destination');
        const calls = f.calls.slice(start);
        const reset = calls.findIndex(call => call.method === 'profiles.update' && call.params.workingDirectory === 'node_default');
        const sync = calls.findIndex(call => call.method === 'profiles.sync' && call.params.nodeId === 'node-destination');
        expect(reset).toBeGreaterThanOrEqual(0); expect(reset).toBeLessThan(sync);
        expect(Object.hasOwn(calls[reset]!.params.toolPolicy as object, 'workspace_read_exempt')).toBe(false);
        const lastUpdate = calls.filter(call => call.method === 'profiles.update').at(-1)!;
        expect(Object.hasOwn(lastUpdate.params, 'workingDirectory')).toBe(false);
        expect(Object.hasOwn(lastUpdate.params.toolPolicy as object, 'workspace_read_exempt')).toBe(false);
      }
    });
  }
  test('a folder advertisement from another durable node never enables profile folders', async () => {
    const f = fixture(), bot = f.bot();
    f.store.setMetadata('nodeRuntimeFeatures:machine', { nodeId: 'another-node', features: { botFolder: true } });
    await syncBotProfile(f.services, f.alice, bot.id);
    expect(Object.hasOwn(f.calls.find(call => call.method === 'profiles.update')!.params, 'workingDirectory')).toBe(false);
  });
  for (const action of ['reset', 'move'] as const) {
    test(`${action} discards queued access and pending grants only for that Bot`, async () => {
      const f = fixture(), bot = f.bot();
      const access = f.services.resource('access', { botId: bot.id, state: 'queued' });
      const other = f.services.resource('access', { botId: 'another-bot', state: 'queued' });
      const grant: P.BotGrant = f.services.resource('grant', { botId: bot.id, machineId: bot.machineId, capabilityId: 'files', requestedLevel: 'off', pendingLevel: 'read_only', effectiveLevel: 'off', reasons: [] });
      f.store.put('accessRequests', access); f.store.put('accessRequests', other); f.store.put('botGrants', grant);
      const scopes = action === 'reset' ? { resetScopes: ['job'] } : { targetMachineId: 'destination' };
      const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`queued_${action}`), action, ...scopes });
      expect(preview.affected.some(effect => effect.resourceType === 'accessRequests' && effect.id === access.id)).toBe(true);
      await f.request('POST', `/v1/bots/${bot.id}/${action}`, confirmed(preview, action === 'reset' ? { resetScopes: ['job'] } : { machineId: 'destination' }));
      expect(f.store.get('accessRequests', access.id)).toBeNull();
      expect(f.store.get('accessRequests', other.id)).toEqual(other);
      expect(f.store.require<P.BotGrant>('botGrants', grant.id)).toMatchObject({ requestedLevel: 'off', pendingLevel: null });
    });
  }
  for (const prior of [undefined, true, false]) {
    for (const review of [false, true]) {
      test(`management preserves tri-state folder exemption ${prior} with review=${review}`, async () => {
        const f = fixture(), bot = f.bot();
        if (review) f.store.setMetadata(`nodeRuntimeFeatures:${bot.machineId}`, { nodeId: f.store.require<P.Machine>('machines', bot.machineId).nodeId, features: { botFolder: true } });
        await syncBotProfile(f.services, f.alice, bot.id);
        const floor = f.store.metadata<P.JSONObject>(`botControllerFloor:${bot.id}`)!;
        f.store.setMetadata(`botControllerFloor:${bot.id}`, { ...floor, ...(prior === undefined ? {} : { workspace_read_exempt: prior }) });
        f.services.integrations.workspaceRestrictions = () => ({ localExecutionCeiling: 'ask', rules: [], allowedMcpOrigins: null, requireReview: false, folderReadsNeedReview: review });
        await syncBotPolicyFloor(f.services, f.admin, bot.id);
        const hardened = f.store.metadata<P.JSONObject>(`botControllerFloor:${bot.id}`)!;
        if (review) expect(hardened.workspace_read_exempt).toBe(false);
        else if (prior === undefined) {
          expect(hardened.workspace_read_exempt).toBeUndefined();
          expect(Object.hasOwn(hardened, 'workspace_read_exempt')).toBe(false);
        } else expect(hardened.workspace_read_exempt).toBe(prior);
      });
    }
  }
});

test('a current profile clears a refresh marker only after policy synchronization is acknowledged', async () => {
  const f = fixture(), bot = f.bot();
  await syncBotProfile(f.services, f.alice, bot.id);
  for (const state of ['pending', 'outcome_unknown', 'acknowledged', null]) {
    f.store.setMetadata(`profileRefresh:${bot.id}`, true);
    f.store.setMetadata(`botPolicySync:${bot.id}`, state === null ? null : { state });
    const calls = f.calls.length;
    markBotProfilesForRefresh(f.services);
    expect(f.store.metadata(`profileRefresh:${bot.id}`)).toBe(state === null || state === 'acknowledged' ? null : true);
    expect(f.calls).toHaveLength(calls);
  }
});

interface SetupFixture {
  store: BackendServices['store'];
  request<T>(method: string, path: string, body: unknown): Promise<T>;
}
describe('resumable Bot setup and address migration', () => {
  async function failedCreate(f: SetupFixture, suffix: string) {
    await expect(f.request('POST', '/v1/bots', { clientNonce: nonce(suffix), name: 'Resume me', machineId: 'machine' })).rejects.toBeInstanceOf(ApiError);
    return f.store.list<P.Bot>('bots')[0]!;
  }
  async function finish(f: SetupFixture, bot: P.Bot, suffix: string) {
    return f.request<P.Bot>('POST', `/v1/bots/${bot.id}/finish-setup`, { clientNonce: nonce(suffix), revision: f.store.require<P.Bot>('bots', bot.id).revision });
  }
  test('allowlisting a rejected origin finishes the same Bot and conversation, skipping acknowledged steps', async () => {
    const f = fixture();
    try {
      f.fail(method => { if (method === 'profile.followup.admission.set') throw new ApiError('callback_origin_not_allowed', 'Remote diagnostic must not escape.'); });
      const bot = await failedCreate(f, 'rejected_origin');
      const view = await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined);
      expect(view.lifecycle).toMatchObject({ step: 'Allow native follow-ups', canFinishSetup: true, canDelete: true, status: 'failed' });
      expect(view.lifecycle?.message).toContain(fixturePublicUrl); expect(view.lifecycle?.message).toContain('LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS');
      const issuer = f.calls.find(call => call.method === 'profile.followup.admission.set')!;
      const priorWrites = f.calls.filter(call => call.mutation && call.method !== 'profile.followup.admission.set');
      f.fail(null);
      const completed = await finish(f, bot, 'allowlisted_finish');
      expect(completed).toMatchObject({ id: bot.id, mainConversationId: bot.mainConversationId, activity: 'idle' });
      expect(completed.lifecycle).toBeUndefined();
      expect(f.store.list<P.Bot>('bots')).toHaveLength(1);
      expect(f.calls.filter(call => call.mutation && call.method !== 'profile.followup.admission.set')).toEqual(priorWrites);
      expect(f.calls.filter(call => call.method === 'profile.followup.admission.set').at(-1)?.params).toEqual(issuer.params);
    } finally { f.store.close(); }
  });
  test('worker rejects sync while offline: explicit resume uses its original mutation ID', async () => {
    const f = fixture();
    try {
      f.fail(method => { if (method === 'profiles.sync') throw new ApiError('machine_offline', 'Reconnect the machine.'); });
      const bot = await failedCreate(f, 'offline_sync'), original = f.calls.find(call => call.method === 'profiles.sync')!;
      f.fail(null);
      const completed = await finish(f, bot, 'online_sync');
      expect(completed.activity).toBe('idle');
      const syncs = f.calls.filter(call => call.method === 'profiles.sync');
      expect(syncs).toHaveLength(2); expect(syncs[1]?.params).toEqual(original.params);
      expect(f.calls.filter(call => call.method === 'profiles.create')).toHaveLength(1);
    } finally { f.store.close(); }
  });
  for (const method of ['node.secrets.set', 'profiles.create', 'profiles.sync', 'profile.followup.admission.set']) {
    test(`lost ${method} acknowledgement queries owning receipt without redispatch`, async () => {
      const f = fixture();
      try {
        f.failAfter(actual => { if (actual === method) throw new ApiError('outcome_unknown', 'Acknowledgement lost.', false); });
        const bot = await failedCreate(f, `lost_${method.replaceAll('.', '_')}`);
        const fence = f.store.metadata<Record<string, unknown>>(`botLifecycle:${bot.id}`)!;
        f.store.setMetadata(`botLifecycle:${bot.id}`, { ...fence, status: 'running' }); // backend stopped before catch persisted
        f.failAfter(null);
        const before = f.calls.length;
        expect((await finish(f, bot, `resume_${method.replaceAll('.', '_')}`)).activity).toBe('idle');
        expect(f.calls.filter(call => call.method === method && call.mutation)).toHaveLength(1);
        const query = method === 'node.secrets.set' ? 'node.secrets.receipt' : method === 'profiles.create' ? 'profiles.get' : method === 'profiles.sync' ? 'profiles.sync.status' : 'profile.followup.admission.get';
        expect(f.calls.slice(before).some(call => call.method === query && !call.mutation)).toBe(true);
      } finally { f.store.close(); }
    });
  }
  test('a missing MCP receipt proves not applied and permits the same reserved operation only', async () => {
    const f = fixture();
    try {
      f.fail(method => { if (method === 'node.secrets.set') throw new ApiError('outcome_unknown', 'Disconnected before worker reply.', false); });
      const bot = await failedCreate(f, 'unapplied_mcp');
      const first = f.calls.find(call => call.method === 'node.secrets.set')!;
      f.fail(null); await finish(f, bot, 'unapplied_mcp_finish');
      expect(f.calls.filter(call => call.method === 'node.secrets.set').map(call => call.params)).toEqual([first.params, first.params]);
      expect(f.calls.findIndex(call => call.method === 'node.secrets.receipt')).toBeLessThan(f.calls.findLastIndex(call => call.method === 'node.secrets.set'));
    } finally { f.store.close(); }
  });
  test('an unresolvable sync receipt stays blocked and sends no mutation', async () => {
    const f = fixture();
    try {
      f.failAfter(method => { if (method === 'profiles.sync') throw new ApiError('outcome_unknown', 'Reply lost.', false); });
      const bot = await failedCreate(f, 'unknown_sync');
      f.failAfter(null); f.syncStatus('unknown');
      const writes = f.calls.filter(call => call.mutation).length;
      await expect(finish(f, bot, 'unknown_sync_finish')).rejects.toMatchObject({ code: 'outcome_unknown', retrySafe: false });
      expect(f.calls.filter(call => call.mutation)).toHaveLength(writes);
      expect((await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).lifecycle?.message).toContain('nothing was retried');
    } finally { f.store.close(); }
  });
  test('an interrupted import retains its copied content and resumes without duplicate skills/routines', async () => {
    const f = fixture();
    try {
      f.fail(method => { if (method === 'profile.followup.admission.set') throw new ApiError('callback_origin_not_allowed', 'Rejected.'); });
      const content: P.TemplateContent = { name: 'Imported', title: '', job: 'Keep imported job', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, skills: [{ name: 'Review', description: 'Review changes', markdown: '# Review\nCheck changes.' }], routines: [{ name: 'Later', instruction: 'Review work', trigger: { kind: 'webhook' }, enabled: false }], connectorNames: [] };
      await expect(f.request('POST', '/v1/bots/import', { clientNonce: nonce('import_resume'), name: 'Imported', machineId: 'machine', content, acceptedTerms: true })).rejects.toBeInstanceOf(ApiError);
      const bot = f.store.list<P.Bot>('bots')[0]!, skills = f.store.list<P.Skill>('skills'), routines = f.store.list<P.Routine>('routines');
      f.fail(null); const completed = await finish(f, bot, 'finish_import');
      expect(completed).toMatchObject({ id: bot.id, mainConversationId: bot.mainConversationId, job: content.job, skillIds: skills.map(skill => skill.id) });
      expect(f.store.list<P.Skill>('skills')).toHaveLength(skills.length); expect(f.store.list<P.Routine>('routines').map(routine => routine.id)).toEqual(routines.map(routine => routine.id));
    } finally { f.store.close(); }
  });
  test('address migration interrupted after controller replacement switches a single issuer using its digest receipt', async () => {
    const f = fixture();
    try {
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('old_address'), name: 'Moving address', machineId: 'machine' });
      const old = f.store.metadata<{ digest: string; url: string }>(`nativeFollowupIssuerConfig:${bot.id}`)!;
      f.services.config.publicUrl = 'https://new-product.example';
      const notice = (await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).lifecycle!;
      expect(notice.message).toContain(fixturePublicUrl); expect(notice.message).toContain('https://new-product.example'); expect(notice.canReaddress).toBe(true);
      f.failAfter(method => { if (method === 'profile.followup.admission.set') throw new ApiError('outcome_unknown', 'Replacement reply lost.', false); });
      await expect(f.request('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('address_lost'), revision: bot.revision })).rejects.toMatchObject({ code: 'outcome_unknown' });
      expect(f.store.metadata(`nativeFollowupIssuerConfig:${bot.id}`)).toMatchObject(old);
      const pending = f.store.metadata<{ digest: string }>(`nativeFollowupIssuerPending:${bot.id}`)!;
      expect(f.store.metadata(`nativeFollowupIssuer:${pending.digest}`)).toBeNull();
      f.failAfter(null);
      const completed = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('address_resume'), revision: bot.revision });
      expect(completed).toMatchObject({ id: bot.id, mainConversationId: bot.mainConversationId });
      expect(completed.lifecycle).toBeUndefined();
      expect(f.store.metadata(`nativeFollowupIssuer:${old.digest}`)).toBeNull();
      expect(f.store.metadata(`nativeFollowupIssuer:${pending.digest}`)).toBe(bot.id);
      expect(f.store.metadata(`nativeFollowupIssuerPending:${bot.id}`)).toBeNull();
      expect(f.calls.filter(call => call.method === 'profile.followup.admission.set')).toHaveLength(2);
      const desired = f.store.metadata<{ mcpServers: { url: string }[] }>(`botDesiredProfile:${bot.id}`)!;
      expect(desired.mcpServers[0]?.url).toBe('https://new-product.example/mcp');
      expect(f.calls.some(call => call.method === 'profile.followup.admission.get' && !call.mutation)).toBe(true);
    } finally { f.store.close(); }
  });
});

describe('interrupted scoped Bot deletion', () => {
  for (const method of ['sessions.delete', 'profiles.delete', 'node.secrets.delete']) {
    test(`lost ${method} reply reconciles read-only then explicit Delete completes without touching another Bot`, async () => {
      const f = fixture(); const gates = createGateService(f.services); f.services.gates = gates;
      try {
        const suffix = method.replaceAll('.', '_');
        const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce(`delete_create_${suffix}`), name: 'Delete me', machineId: 'machine' });
        const other = f.bot(), otherRoom = f.store.require<P.Conversation>('conversations', other.mainConversationId);
        const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`delete_preview_${suffix}`), action: 'delete' });
        f.failAfter(actual => { if (actual === method) throw new ApiError('outcome_unknown', 'Deletion receipt lost.', false); });
        await expect(f.request('DELETE', `/v1/bots/${bot.id}`, confirmed(preview, { clientNonce: nonce(`delete_first_${suffix}`) }))).rejects.toMatchObject({ code: 'outcome_unknown' });
        await expect(f.request('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`delete_before_read_${suffix}`), action: 'delete' })).rejects.toMatchObject({ code: 'outcome_unknown' });
        f.failAfter(null); const readsFrom = f.calls.length;
        await createBotService(f.services).reconcile();
        expect(f.calls.slice(readsFrom).every(call => !call.mutation)).toBe(true);
        expect((await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).lifecycle).toMatchObject({ status: 'failed', canDelete: true });
        const fresh = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`delete_again_preview_${suffix}`), action: 'delete' });
        await f.request('DELETE', `/v1/bots/${bot.id}`, confirmed(fresh, { clientNonce: nonce(`delete_again_${suffix}`) }));
        expect(f.store.get('bots', bot.id)).toBeNull();
        expect(f.store.require<P.Bot>('bots', other.id)).toEqual(other); expect(f.store.require<P.Conversation>('conversations', otherRoom.id)).toEqual(otherRoom);
        expect(f.calls.filter(call => call.method === method && call.mutation)).toHaveLength(1);
      } finally { gates.close(); f.store.close(); }
    });
  }
  test('failed deletion observations do not authorize another Delete', async () => {
    const f = fixture(), bot = f.bot(); const gates = createGateService(f.services); f.services.gates = gates;
    try {
      const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce('delete_observation_preview'), action: 'delete' });
      f.fail(method => { if (method === 'sessions.delete') throw new ApiError('outcome_unknown', 'Lost.', false); });
      await expect(f.request('DELETE', `/v1/bots/${bot.id}`, confirmed(preview))).rejects.toMatchObject({ code: 'outcome_unknown' });
      f.fail(method => { if (method === 'sessions.get') throw new ApiError('upstream_unavailable', 'Read unavailable.'); });
      await createBotService(f.services).reconcile();
      expect((await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).lifecycle?.canDelete).toBe(false);
    } finally { gates.close(); f.store.close(); }
  });
});

test('a loopback Bot resumes a lost address profile update and can move to a second public origin', async () => {
  const f = fixture();
  try {
    f.services.config.publicUrl = 'http://127.0.0.1:4100';
    f.store.setMetadata('machineSameHost:machine', 'node-source');
    const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('loopback_create'), name: 'Local Bot', machineId: 'machine' });
    const old = f.store.metadata<{ digest: string }>(`nativeFollowupIssuerConfig:${bot.id}`)!;
    f.services.config.publicUrl = 'https://public-product.example';
    const notice = (await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).lifecycle!;
    expect(notice.message).toContain('http://127.0.0.1:4100'); expect(notice.message).toContain('https://public-product.example');
    f.failAfter(method => { if (method === 'profiles.update') throw new ApiError('outcome_unknown', 'Profile reply lost.', false); });
    await expect(f.request('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('loopback_address_lost'), revision: bot.revision })).rejects.toMatchObject({ code: 'outcome_unknown' });
    expect((await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined)).lifecycle?.canReaddress).toBe(true);
    expect(f.store.metadata(`nativeFollowupIssuer:${old.digest}`)).toBeNull();
    f.failAfter(null);
    const writes = f.calls.filter(call => call.mutation).length;
    const completed = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('loopback_address_resume'), revision: bot.revision });
    expect(completed.lifecycle).toBeUndefined();
    expect(completed.mainConversationId).toBe(bot.mainConversationId);
    expect(f.calls.slice().filter(call => call.method === 'profiles.update')).toHaveLength(1);
    expect(f.calls.filter(call => call.mutation)).toHaveLength(writes + 1); // only the previously unstarted worker sync
    f.services.config.publicUrl = 'https://second-product.example';
    const again = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('second_address'), revision: completed.revision });
    expect(again.lifecycle).toBeUndefined();
    expect(f.store.metadata(`nativeFollowupIssuerConfig:${bot.id}`)).toMatchObject({ url: 'https://second-product.example/internal/runtime/followup/admission', state: 'configured' });
    expect(f.calls.filter(call => call.method === 'profiles.update')).toHaveLength(2);
  } finally { f.store.close(); }
});

test('address recovery of a failed update retains its worker mutation ID and requested Bot changes', async () => {
  const f = fixture();
  try {
    const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('update_address_create'), name: 'Before', machineId: 'machine' });
    f.services.config.publicUrl = 'https://updated-product.example';
    await expect(f.request('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('update_new_address'), revision: bot.revision, name: 'After' })).rejects.toMatchObject({ code: 'conflict' });
    f.fail(method => { if (method === 'profiles.sync') throw new ApiError('machine_offline', 'Reconnect worker.'); });
    await expect(f.request('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('update_address_offline'), revision: bot.revision })).rejects.toMatchObject({ code: 'machine_offline' });
    const sync = f.calls.filter(call => call.method === 'profiles.sync').at(-1)!;
    f.fail(null);
    const completed = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('update_address_online'), revision: bot.revision });
    expect(completed).toMatchObject({ id: bot.id, name: 'After', mainConversationId: bot.mainConversationId });
    expect(completed.lifecycle).toBeUndefined();
    expect(f.calls.filter(call => call.method === 'profiles.sync').at(-1)?.params).toEqual(sync.params);
    expect(f.store.metadata(`botProfileSync:${bot.id}`)).toMatchObject({ mutationId: sync.params.mutationId, acknowledged: true });
    expect(f.store.metadata(`botLifecycle:${bot.id}`)).toBeNull();
  } finally { f.store.close(); }
});

describe('production Router lifecycle review regressions', () => {
  test('concurrent re-address requests acquire one owner before asynchronous idle preflight', async () => {
    const f = fixture();
    try {
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('race_create'), name: 'Address race', machineId: 'machine' });
      f.services.config.publicUrl = 'https://race-product.example';
      const { promise: suspended, resolve: release } = Promise.withResolvers<void>();
      const { promise: observing, resolve: entered } = Promise.withResolvers<void>();
      f.before(async method => { if (method === 'runs.active.list') { entered(); await suspended; } });
      const first = f.request<P.Bot>('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('race_first'), revision: bot.revision });
      await observing;
      const owner = f.store.metadata<{ id: string }>(`botLifecycle:${bot.id}`)!;
      await expect(f.request('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('race_second'), revision: bot.revision })).rejects.toMatchObject({ code: 'conflict' });
      expect(f.store.metadata<{ id: string }>(`botLifecycle:${bot.id}`)?.id).toBe(owner.id);
      release(); await first;
      expect(f.calls.filter(call => call.method === 'runs.active.list')).toHaveLength(1);
      expect(f.calls.filter(call => call.method === 'profile.followup.admission.set')).toHaveLength(2); // create, then one replacement
    } finally { f.store.close(); }
  });
  test('address migration reserves the new URL aliases in its profile policy and remains receipt-resumable', async () => {
    const f = fixture();
    try {
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('alias_create'), name: 'Tool aliases', machineId: 'machine' });
      const oldAliases = productAliases(`${fixturePublicUrl}/mcp`).map(tool => tool.executionName);
      f.services.config.publicUrl = 'https://aliases-product.example';
      f.failAfter(method => { if (method === 'profiles.update') throw new ApiError('outcome_unknown', 'Profile response lost.', false); });
      await expect(f.request('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('alias_lost'), revision: bot.revision })).rejects.toMatchObject({ code: 'outcome_unknown' });
      const desired = f.store.metadata<{ toolPolicy: { allow: string[] }; mcpServers: { url: string }[]; profileIntentId: string }>(`botDesiredProfile:${bot.id}`)!;
      const aliases = productAliases('https://aliases-product.example/mcp').map(tool => tool.executionName);
      expect(desired.mcpServers[0]?.url).toBe('https://aliases-product.example/mcp');
      expect(desired.toolPolicy.allow).toEqual(expect.arrayContaining(aliases));
      expect(desired.toolPolicy.allow.some(name => oldAliases.includes(name))).toBe(false);
      f.failAfter(null);
      await f.request('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce('alias_resume'), revision: bot.revision });
      expect(f.calls.filter(call => call.method === 'profiles.update')).toHaveLength(1);
      expect(f.store.metadata<{ profileIntentId: string }>(`botDesiredProfile:${bot.id}`)?.profileIntentId).toBe(desired.profileIntentId);
    } finally { f.store.close(); }
  });
  test('success publishes a completed Bot with a revision newer than every in-progress event', async () => {
    const f = fixture(), events: P.Bot[] = [];
    const stop = f.services.events.subscribe(event => { if (event.event === 'bot.upserted') events.push(event.payload); });
    try {
      const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('completion_events'), name: 'Completed', machineId: 'machine' });
      const own = events.filter(event => event.id === bot.id), completed = own.at(-1)!;
      const running = own.filter(event => event.lifecycle?.status === 'running');
      expect(running.length).toBeGreaterThan(0);
      expect(completed.lifecycle).toBeUndefined();
      expect(completed.revision).toBe(bot.revision);
      expect(running.every(event => event.revision < completed.revision)).toBe(true);
    } finally { stop(); f.store.close(); }
  });
  for (const status of ['failed', 'outcome_unknown'] as const) {
    test(`a ${status} re-address Delete capability is accepted by the actual preview/delete routes`, async () => {
      const f = fixture(), gates = createGateService(f.services); f.services.gates = gates;
      try {
        const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce(`delete_address_${status}`), name: 'Remove migration', machineId: 'machine' });
        f.services.config.publicUrl = 'https://delete-migration.example';
        f.fail(method => { if (method === 'profile.followup.admission.set') throw new ApiError(status === 'failed' ? 'callback_origin_not_allowed' : 'outcome_unknown', 'Rejected or lost.', status === 'failed'); });
        await expect(f.request('POST', `/v1/bots/${bot.id}/readdress`, { clientNonce: nonce(`delete_address_start_${status}`), revision: bot.revision })).rejects.toBeInstanceOf(ApiError);
        const view = await f.request<P.Bot>('GET', `/v1/bots/${bot.id}`, undefined);
        expect(view.lifecycle).toMatchObject({ status, canDelete: true });
        f.fail(null);
        const preview = await f.request<P.Confirmation>('POST', `/v1/bots/${bot.id}/preview`, { clientNonce: nonce(`delete_address_preview_${status}`), action: 'delete' });
        await f.request('DELETE', `/v1/bots/${bot.id}`, confirmed(preview, { clientNonce: nonce(`delete_address_confirm_${status}`) }));
        expect(f.store.get('bots', bot.id)).toBeNull();
      } finally { gates.close(); f.store.close(); }
    });
  }
});

test('the completed update event revision remains the preference undo revision', async () => {
  const f = fixture();
  try {
    const bot = await f.request<P.Bot>('POST', '/v1/bots', { clientNonce: nonce('preference_revision_create'), name: 'Preferences', machineId: 'machine' });
    const changed = await f.request<P.Bot>('PATCH', `/v1/bots/${bot.id}`, { clientNonce: nonce('preference_revision_update'), revision: bot.revision, job: 'Updated job' });
    const preference = f.store.list<P.PreferenceChange>('preferenceChanges', row => row.botId === bot.id)[0]!;
    expect(preference.resultingBotRevision).toBe(changed.revision);
    expect(changed.lifecycle).toBeUndefined();
  } finally { f.store.close(); }
});

describe('production Router imported resource recovery', () => {
  const content: P.TemplateContent = { name: 'Import receipt', title: '', job: 'Recover this import', instructions: '', avatar: { kind: 'character', shape: 'round', color: 'yellow', attachmentId: null }, voice: { voiceId: 'default', speed: 1, language: null }, skills: [{ name: 'Review', description: 'Review changes', markdown: '# Review\nCheck the patch.' }], routines: [{ name: 'Review later', instruction: 'Review changes', trigger: { kind: 'webhook' }, enabled: false }], connectorNames: [] };
  interface ImportPlan { imported: { content: P.TemplateContent; disabledSkillIndexes: number[]; skillReservations?: { skill: P.Skill; operationId: string }[]; routineReservations?: { routine: P.Routine; conversation: P.Conversation; operationId: string }[]; skillIds?: string[]; routineIds?: string[] } }
  test('a lost imported host-write acknowledgement resumes the same reserved skill using its real file receipt', async () => {
    const f = fixture();
    try {
      f.fail(method => {
        if (method !== 'node.fs.write') return;
        const bot = f.store.list<P.Bot>('bots')[0]!;
        const reservation = f.store.metadata<ImportPlan>(`botSetup:${bot.id}`)!.imported.skillReservations![0]!;
        expect(reservation.skill.id).toBe(f.store.list<P.Skill>('skills')[0]!.id);
        expect(reservation.operationId.length).toBeGreaterThan(0);
      });
      f.failAfter(method => { if (method === 'node.fs.write') throw new ApiError('outcome_unknown', 'Worker acknowledgement lost.', false); });
      await expect(f.request('POST', '/v1/bots/import', { clientNonce: nonce('production_import_lost'), name: content.name, machineId: 'machine', content, acceptedTerms: true })).rejects.toMatchObject({ code: 'outcome_unknown' });
      const bot = f.store.list<P.Bot>('bots')[0]!, plan = f.store.metadata<ImportPlan>(`botSetup:${bot.id}`)!, reservation = plan.imported.skillReservations![0]!;
      const writes = f.calls.filter(call => call.method === 'node.fs.write');
      expect(writes).toHaveLength(1);
      expect(String(writes[0]!.params.path)).toContain(reservation.skill.id);
      f.fail(null); f.failAfter(null);
      const receiptStart = f.calls.length;
      const completed = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/finish-setup`, { clientNonce: nonce('production_import_resume'), revision: bot.revision });
      expect(completed.skillIds).toEqual([reservation.skill.id]);
      expect(completed.mainConversationId).toBe(bot.mainConversationId);
      expect(f.store.list<P.Skill>('skills')).toHaveLength(1);
      expect(f.store.list<P.Routine>('routines')).toHaveLength(1);
      expect(f.calls.filter(call => call.method === 'node.fs.write')).toHaveLength(1);
      expect(f.calls.slice(receiptStart).some(call => call.method === 'node.fs.read' && !call.mutation)).toBe(true);
      expect(f.store.metadata<ImportPlan>(`botSetup:${bot.id}`)!.imported.skillReservations![0]?.operationId).toBe(reservation.operationId);
    } finally { f.store.close(); }
  });
  test('an inconclusive imported skill receipt stays fenced without creating another resource or dispatching a write', async () => {
    const f = fixture();
    try {
      f.failAfter(method => { if (method === 'node.fs.write') throw new ApiError('outcome_unknown', 'Worker acknowledgement lost.', false); });
      await expect(f.request('POST', '/v1/bots/import', { clientNonce: nonce('production_import_blocked'), name: content.name, machineId: 'machine', content, acceptedTerms: true })).rejects.toMatchObject({ code: 'outcome_unknown' });
      const bot = f.store.list<P.Bot>('bots')[0]!, reserved = f.store.list<P.Skill>('skills')[0]!;
      f.failAfter(null); f.fail(method => { if (method === 'node.fs.read') throw new ApiError('upstream_unavailable', 'Receipt unavailable.'); });
      const count = f.calls.filter(call => call.mutation).length;
      await expect(f.request('POST', `/v1/bots/${bot.id}/finish-setup`, { clientNonce: nonce('production_import_blocked_finish'), revision: bot.revision })).rejects.toMatchObject({ code: 'outcome_unknown' });
      expect(f.store.list<P.Skill>('skills').map(skill => skill.id)).toEqual([reserved.id]);
      expect(f.calls.filter(call => call.mutation)).toHaveLength(count);
    } finally { f.store.close(); }
  });
  test('pre-reservation imports adopt an existing unknown skill by receipt instead of POSTing another skill', async () => {
    const f = fixture();
    try {
      f.failAfter(method => { if (method === 'node.fs.write') throw new ApiError('outcome_unknown', 'Worker acknowledgement lost.', false); });
      await expect(f.request('POST', '/v1/bots/import', { clientNonce: nonce('legacy_import_lost'), name: content.name, machineId: 'machine', content, acceptedTerms: true })).rejects.toMatchObject({ code: 'outcome_unknown' });
      const bot = f.store.list<P.Bot>('bots')[0]!, plan = f.store.metadata<ImportPlan>(`botSetup:${bot.id}`)!, skill = f.store.list<P.Skill>('skills')[0]!;
      f.store.setMetadata(`botSetup:${bot.id}`, { ...plan, imported: { content, disabledSkillIndexes: [], skillIds: [], routineIds: [] } });
      f.failAfter(null);
      const completed = await f.request<P.Bot>('POST', `/v1/bots/${bot.id}/finish-setup`, { clientNonce: nonce('legacy_import_finish'), revision: bot.revision });
      expect(completed.skillIds).toEqual([skill.id]);
      expect(f.store.list<P.Skill>('skills')).toHaveLength(1);
      expect(f.calls.filter(call => call.method === 'node.fs.write')).toHaveLength(1);
      expect(f.calls.some(call => call.method === 'node.fs.read')).toBe(true);
    } finally { f.store.close(); }
  });
  for (const interruption of ['none', 'delete_ack', 'install_receipt'] as const) {
    test(`an adopted legacy skill preserves disabled intent after receipt reconciliation (${interruption})`, async () => {
      const f = fixture();
      try {
        f.failAfter(method => { if (method === 'node.fs.write') throw new ApiError('outcome_unknown', 'Install acknowledgement lost.', false); });
        await expect(f.request('POST', '/v1/bots/import', { clientNonce: nonce(`disabled_legacy_start_${interruption}`), name: content.name, machineId: 'machine', content, acceptedTerms: true })).rejects.toMatchObject({ code: 'outcome_unknown' });
        const bot=f.store.list<P.Bot>('bots')[0]!,skill=f.store.list<P.Skill>('skills')[0]!,plan=f.store.metadata<ImportPlan>(`botSetup:${bot.id}`)!;
        expect(skill.enabled).toBe(true);
        // The older importer persisted its disabled selection but had not reached the disable step.
        f.store.setMetadata(`botSetup:${bot.id}`,{...plan,imported:{content,disabledSkillIndexes:[0],skillIds:[],routineIds:[]}});
        f.failAfter(interruption==='delete_ack'?method=>{if(method==='node.fs.delete')throw new ApiError('outcome_unknown','Disable acknowledgement lost.',false);}:null);
        if(interruption==='install_receipt')f.fail(method=>{if(method==='node.fs.read')throw new ApiError('upstream_unavailable','Install receipt unavailable.');});
        const finish=()=>f.request<P.Bot>('POST',`/v1/bots/${bot.id}/finish-setup`,{clientNonce:nonce(`disabled_legacy_finish_${interruption}`),revision:bot.revision});
        if(interruption==='install_receipt'){
          await expect(finish()).rejects.toMatchObject({code:'outcome_unknown'});
          expect(f.store.require<P.Skill>('skills',skill.id).enabled).toBe(true);
          expect(f.calls.filter(call=>call.method==='node.fs.delete')).toHaveLength(0);
        }else{
          let completed:P.Bot;
          if(interruption==='delete_ack'){
            await expect(finish()).rejects.toMatchObject({code:'outcome_unknown'});
            expect(f.store.require<P.Skill>('skills',skill.id).enabled).toBe(true);
            f.failAfter(null);
            completed=await f.request<P.Bot>('POST',`/v1/bots/${bot.id}/finish-setup`,{clientNonce:nonce('disabled_legacy_disable_resume'),revision:bot.revision});
          }else completed=await finish();
          expect(completed.skillIds).toEqual([skill.id]);
          expect(completed.lifecycle).toBeUndefined();
          expect(f.store.require<P.Skill>('skills',skill.id).enabled).toBe(false);
          expect(f.store.metadata(`skillHostPaths:${skill.id}`)).toEqual([]);
          expect(f.calls.filter(call=>call.method==='node.fs.delete')).toHaveLength(1);
          expect(f.calls.findIndex(call=>call.method==='node.fs.read')).toBeLessThan(f.calls.findIndex(call=>call.method==='node.fs.delete'));
        }
        expect(f.store.list<P.Skill>('skills')).toHaveLength(1);
        expect(f.calls.filter(call=>call.method==='node.fs.write')).toHaveLength(1);
      }finally{f.store.close();}
    });
  }
});
