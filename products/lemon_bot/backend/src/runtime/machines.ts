import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../core/services';
import { ApiError, fail } from '../core/errors';
import { z, parse, principal, id, mutation, update, confirm, boundedText, queryObject } from '../core/validation';
import { decodeChunk, getTerminalService } from './terminals';
import { emitBotRuntimeProjection } from './projection';
import { machineCapabilities, effectiveBotGrants } from '../core/experiences';
import { quiesceMachineInvocations } from './runs';

const text = boundedText(120, 1);
const path = z.string().min(1).max(4096).refine(value => !/[\u0000-\u001f]/.test(value));
const integer = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const ttl = z.number().int().min(1).max(86_400_000).optional();
const labels = z.record(z.string().min(1).max(256), z.string().max(256)).refine(value => Object.keys(value).length <= 32);
const pageQuery = z.object({ cursor: z.string().optional(), limit: z.coerce.number().int().min(1).max(200).optional() }).strict();
const statSchema = z.object({ path, type: z.enum(['regular', 'directory', 'symlink']), size: integer, mtimeMs: integer, mode: integer, mime: z.string().nullable(), readable: z.boolean(), writable: z.boolean() }).passthrough();
type RemoteStat = z.infer<typeof statSchema>;
const hostSchema = z.object({ hostname: z.string(), os: z.string(), osVersion: z.string(), arch: z.string(), cpuCount: integer.positive(), memTotalBytes: integer, memFreeBytes: integer, diskTotalBytes: integer, diskFreeBytes: integer, uptimeSec: z.number().nonnegative(), lemonVersion: z.string(), defaultCwd: path, user: z.string() }).passthrough();
const nodesSchema = z.object({ nodes: z.array(z.object({ id, name: z.string().nullable(), purpose: z.string().nullable(), enrollmentInviteId: id.nullable(), status: z.enum(['online', 'offline', 'unknown']), lastSeenMs: integer.nullable(), pairedAtMs: integer.nullable(), capabilities: z.array(z.string()) }).passthrough()), summary: z.object({ presenceAvailable: z.boolean(), truncated: z.boolean() }).passthrough() }).passthrough();
const inviteSchema = z.object({ inviteId: id, inviteCode: z.string().min(1), joinCommand: z.string().min(1), expiresAtMs: integer }).passthrough();
const chunkSchema = z.object({ path, offset: integer, dataBase64: z.string(), size: integer, mime: z.string(), eof: z.boolean() }).passthrough();
interface FilePreviewBinding { machineId: string; path: string; principalId: string; targetId: string; revision: number; snapshot: string; upstreamToken: string; expiresAtMs: number; name: string }
export interface MachineRuntimeFeatures { nodeId: string; protocol: 1; lemonVersion: string; methods: string[]; features: { hostIO: boolean; filesystemCAS: boolean; deletePreviews: boolean; encryptedSecrets: boolean; ptyShell: boolean; mcpDiscovery: boolean; profileSync: boolean; liveStreaming: boolean; repairInvites: boolean; nativeExecutionPolicy: boolean }; botReady: boolean; missingFeatures: string[]; capabilities?: P.JSONObject; nativePrivacyContext?: { version: 1 } }
const runtimeFeaturesSchema = z.object({ nodeId: id, protocol: z.literal(1), lemonVersion: z.string(), methods: z.array(z.string()), features: z.object({ hostIO: z.boolean(), filesystemCAS: z.boolean(), deletePreviews: z.boolean(), encryptedSecrets: z.boolean(), ptyShell: z.boolean(), mcpDiscovery: z.boolean(), profileSync: z.boolean(), liveStreaming: z.boolean(), repairInvites: z.boolean(), nativeExecutionPolicy: z.boolean() }).strict(), botReady: z.boolean(), missingFeatures: z.array(z.string().max(128)).max(100), capabilities: z.record(z.string(), z.json()).optional(), nativePrivacyContext: z.object({ version: z.literal(1) }).strict().optional() }).strict();

export async function ensureMachineRuntimeReady(services: BackendServices, machine: P.Machine, refresh = false): Promise<MachineRuntimeFeatures> {
  if (!services.lemon.connected) fail('upstream_unavailable', 'The controller is not connected.');
  if (!machine.nodeId || machine.status === 'revoked' || machine.status === 'offline') fail('machine_offline', 'The trusted execution machine is not online.');
  const epoch = services.store.metadata<string>('controllerEpoch');
  let cached = services.store.metadata<MachineRuntimeFeatures & { controlEpoch: string | null }>(`nodeRuntimeFeatures:${machine.id}`);
  if (refresh || !cached || cached.nodeId !== machine.nodeId || cached.controlEpoch !== epoch) {
    const result = remote(runtimeFeaturesSchema, await services.lemon.call('node.runtime.features', { nodeId: machine.nodeId }));
    if (result.nodeId !== machine.nodeId) fail('upstream_unavailable', 'Runtime feature measurement belongs to another node.');
    cached = { ...result, controlEpoch: epoch }; services.store.setMetadata(`nodeRuntimeFeatures:${machine.id}`, cached);
  }
  if (!cached.botReady || !Object.values(cached.features).every(value => value === true)) fail('capability_unavailable', 'The worker is connected but lacks required Lemon Bot runtime features. Upgrade and reverify that same durable worker.');
  return cached;
}

function remote<T>(schema: z.ZodType<T>, value: unknown): T {
  const parsed = schema.safeParse(value);
  if (!parsed.success) fail('upstream_unavailable', 'The destination returned an invalid resource.');
  return parsed.data;
}
function fileInfo(stat: RemoteStat): P.FileInfo {
  return { path: stat.path, name: stat.path.split('/').filter(Boolean).at(-1) ?? stat.path, kind: stat.type === 'regular' ? 'file' : stat.type, size: stat.size, mime: stat.mime, modifiedAtMs: stat.mtimeMs, readable: stat.readable, writable: stat.writable };
}
export async function refreshMachines(services: BackendServices): Promise<void> {
  const all = remote(nodesSchema, await services.lemon.call('nodes.list'));
  if (!all.summary.presenceAvailable) fail('upstream_unavailable', 'Node presence could not be measured.');
  for (const machine of services.store.list<P.Machine>('machines', value => value.status !== 'revoked')) {
    const response = all.summary.truncated ? remote(nodesSchema, await services.lemon.call('nodes.list', machine.nodeId ? { nodeId: machine.nodeId } : { name: machine.nodeName })) : all;
    if (!response.summary.presenceAvailable || response.summary.truncated) fail('upstream_unavailable', 'The exact node presence could not be measured.');
    const invites = services.store.list<P.MachineInvite>('machineInvites', value => value.machineId === machine.id);
    const inviteIds = invites.map(value => services.store.metadata<string>(`machineInviteUpstream:${value.id}`)).filter((value): value is string => value !== null);
    const node = response.nodes.find(value => machine.nodeId ? value.id === machine.nodeId : value.name === machine.nodeName && value.purpose === 'lemon_bot' && value.enrollmentInviteId !== null && inviteIds.includes(value.enrollmentInviteId));
    if (node?.status === 'unknown') fail('upstream_unavailable', 'Node presence is unknown.');
    let status: P.Machine['status'] = node?.status === 'online' ? 'online' : machine.nodeId ? 'offline' : 'pending';
    let incompatibility: string | null = null;
    if (node?.status === 'online') {
      try { await ensureMachineRuntimeReady(services, { ...machine, nodeId: node.id, status: 'online' }, true); }
      catch (error) { if (!(error instanceof ApiError) || error.code !== 'capability_unavailable') throw error; status = 'pending'; incompatibility = error.message; }
    }
    if (node) services.store.setMetadata(`nodeSnapshot:${machine.id}`, node);
    const lastSeenAtMs = node?.lastSeenMs ?? machine.lastSeenAtMs;
    if (status !== machine.status || (node && node.id !== machine.nodeId) || lastSeenAtMs !== machine.lastSeenAtMs) {
      const next = services.update(machine, { status, nodeId: node?.id ?? machine.nodeId, lastSeenAtMs });
      services.store.put('machines', next); services.events.emit('machine.upserted', next, { machineId: next.id });
      for (const bot of services.store.list<P.Bot>('bots', value => value.machineId === next.id)) {
        const activity = status !== 'online' ? 'offline' : bot.activeRunIds.length ? 'working' : 'idle';
        if (bot.activity !== activity) { const updated = services.update(bot, { activity }); services.store.put('bots', updated); emitBotRuntimeProjection(services, updated); }
      }
    }
    if (node?.status === 'online') for (const invitation of services.store.list<P.MachineInvite>('machineInvites', value => value.machineId === machine.id && (value.status === 'pending' || value.status === 'joined' && value.enrollment === 'failed') && services.store.metadata<string>(`machineInviteUpstream:${value.id}`) === node.enrollmentInviteId)) {
      const joined = services.update(invitation, { status: 'joined', enrollment: incompatibility ? 'failed' : 'online', lastError: incompatibility });
      services.store.put('machineInvites', joined); services.events.emit('machine_invite.upserted', joined, { userIds: [machine.ownerUserId] });
    }
  }
  for (const invitation of services.store.list<P.MachineInvite>('machineInvites', value => value.status === 'pending' && value.expiresAtMs <= services.now())) {
    const expired = services.update(invitation, { status: 'expired', enrollment: 'expired' }); services.store.put('machineInvites', expired);
    const machine = services.store.require<P.Machine>('machines', invitation.machineId); services.events.emit('machine_invite.upserted', expired, { userIds: [machine.ownerUserId] });
  }
}
export async function getHostInfo(services: BackendServices, user: Principal, machineId: string): Promise<P.HostInfo> {
  const machine = services.auth.machine(user, machineId);
  if (!services.lemon.connected) fail('upstream_unavailable', 'The controller is not connected.');
  if (!machine.nodeId || machine.status !== 'online') { if (services.store.metadata<MachineRuntimeFeatures>(`nodeRuntimeFeatures:${machine.id}`)?.botReady === false) fail('capability_unavailable', 'The connected worker lacks required product runtime features.'); fail('machine_offline', 'The machine is not online.'); }
  const value = remote(hostSchema, await services.lemon.call('node.host.info', { nodeId: machine.nodeId }));
  const host: P.HostInfo = { hostname: value.hostname, os: value.os, osVersion: value.osVersion, arch: value.arch, cpuCount: value.cpuCount, memTotalBytes: value.memTotalBytes, memFreeBytes: value.memFreeBytes, diskTotalBytes: value.diskTotalBytes, diskFreeBytes: value.diskFreeBytes, uptimeSec: value.uptimeSec, lemonVersion: value.lemonVersion, defaultCwd: value.defaultCwd, user: value.user, measuredAtMs: services.now() };
  services.store.setMetadata(`hostInfo:${machine.id}`, host); return host;
}

export function createMachineRoutes(services: BackendServices): Route[] {
  const terminal = getTerminalService(services);
  const routes: Route[] = [];
  function add(method: string, suffix: string, handler: Route['handler'], status = 200, auth: Route['auth'] = 'member') {
    routes.push({ method, path: `/v1${suffix}`, auth, status, handler, authorizeReplay(context) {
      const actor = principal(context.user);
      if (suffix.startsWith('/terminals/:id')) { terminal.require(actor, context.params.id!); return; }
      if (suffix.startsWith('/machines/:id')) {
        const value = services.auth.machine(actor, context.params.id!);
        if (suffix.includes('/invites') || suffix.endsWith('/reconnect') || suffix === '/machines/:id' && method !== 'GET' || suffix === '/machines/:id/preview') manager(actor, value);
      }
      if (suffix.endsWith('/terminals') && typeof context.body === 'object' && context.body !== null && 'deviceId' in context.body && typeof context.body.deviceId === 'string') {
        const device = services.store.require<P.Device>('devices', context.body.deviceId);
        if (device.userId !== actor.userId || actor.deviceId !== null && actor.deviceId !== device.id) fail('forbidden', 'The terminal receipt belongs to another device.');
      }
    } });
  }
  function user(context: RequestContext) { return principal(context.user); }
  function machine(context: RequestContext, manage = false, online = false) {
    const value = services.auth.machine(user(context), context.params.id!, manage);
    if (online) { if (!services.lemon.connected) fail('upstream_unavailable', 'The controller is not connected.'); if (value.status !== 'online' || !value.nodeId) { if (services.store.metadata<MachineRuntimeFeatures>(`nodeRuntimeFeatures:${value.id}`)?.botReady === false) fail('capability_unavailable', 'The connected worker lacks required product runtime features.'); fail('machine_offline', 'The machine is not online.'); } }
    return value;
  }
  function manager(actor: Principal, value: P.Machine) {
    if (actor.kind !== 'user' || (value.ownerUserId !== actor.userId && !['admin', 'owner'].includes(actor.role))) fail('forbidden', 'Only the machine owner or an authorized administrator may manage enrollment and access.');
  }
  async function stat(value: P.Machine, name: string) { return remote(statSchema, await services.lemon.call('node.fs.stat', { nodeId: value.nodeId!, path: name })); }
  async function issue(context: RequestContext, value: P.Machine, expiresInMs: number | undefined): Promise<P.MachineInvite> {
    manager(user(context), value);
    const invitation: P.MachineInvite = services.resource('machine_invite', { machineId: value.id, inviteCode: '', joinCommand: '', expiresAtMs: services.now() + (expiresInMs ?? 900_000), status: 'pending', enrollment: 'invited', lastError: null });
    context.nonceResourceIds.push(value.id, invitation.id);
    services.store.put('machineInvites', invitation);
    try {
      const raw = await services.lemon.call('node.pair.invite', { nodeName: value.nodeName, purpose: 'lemon_bot', labels: value.labels, ...(value.nodeId ? { nodeId: value.nodeId } : {}), ...(expiresInMs !== undefined ? { expiresInMs } : {}) }, { mutation: true, resourceIds: [value.id, invitation.id] });
      const parsed = inviteSchema.safeParse(raw);
      if (!parsed.success) fail('outcome_unknown', 'The enrollment may have been issued but its receipt is invalid.', false, { resourceIds: [value.id, invitation.id] });
      const result = parsed.data;
      if (services.config.operatorToken && result.joinCommand.includes(services.config.operatorToken)) fail('outcome_unknown', 'The enrollment receipt contained forbidden controller authority.', false, { resourceIds: [value.id, invitation.id] });
      services.store.setMetadata(`machineInviteUpstream:${invitation.id}`, result.inviteId);
      const issued = services.update(invitation, { inviteCode: result.inviteCode, joinCommand: result.joinCommand, expiresAtMs: result.expiresAtMs, enrollment: 'waiting_for_join' });
      services.store.put('machineInvites', issued); services.events.emit('machine_invite.upserted', issued, { userIds: [value.ownerUserId] });
      return issued;
    } catch (error) {
      const known = error instanceof ApiError ? error : new ApiError('outcome_unknown', 'Enrollment issuance could not be confirmed.', false, { resourceIds: [value.id, invitation.id] });
      const failed = services.update(invitation, { status: known.retrySafe ? 'revoked' : 'pending', enrollment: 'failed', lastError: known.retrySafe ? 'Enrollment was rejected before an invitation was issued.' : 'Enrollment issuance has an unknown outcome. Reconcile this invitation; do not issue a duplicate.' });
      services.store.put('machineInvites', failed); services.events.emit('machine_invite.upserted', failed, { userIds: [value.ownerUserId] });
      throw known;
    }
  }
  async function revokeInvite(actor: Principal, invitation: P.MachineInvite) {
    const value = services.store.require<P.Machine>('machines', invitation.machineId); manager(actor, value);
    if (invitation.status !== 'pending') return;
    const upstream = services.store.metadata<string>(`machineInviteUpstream:${invitation.id}`);
    if (!upstream) fail('outcome_unknown', 'Enrollment issuance is unresolved; do not issue a replacement.', false, { resourceIds: [invitation.id, value.id] });
    await services.lemon.call('node.pair.invite.revoke', { inviteId: upstream }, { mutation: true, resourceIds: [invitation.id] });
    const revoked = services.update(invitation, { status: 'revoked', enrollment: 'revoked', inviteCode: '', joinCommand: '' }); services.store.put('machineInvites', revoked); services.events.emit('machine_invite.upserted', revoked, { userIds: [value.ownerUserId] });
  }
  add('GET', '/machines', async context => { parse(pageQuery, queryObject(context.query)); await refreshMachines(services); return services.page(context, services.store.list<P.Machine>('machines', value => value.status !== 'revoked' && services.auth.canRead(user(context), 'machines', value))); });
  add('POST', '/machines', async context => {
    const body = parse(mutation.extend({ name: text, nodeName: z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$/), labels: labels.optional(), expiresInMs: ttl }), context.body);
    await refreshMachines(services);
    if (services.store.list<P.Machine>('machines', value => value.nodeName === body.nodeName).length) fail('conflict', 'This durable node name is already attached.');
    const nodes = remote(nodesSchema, await services.lemon.call('nodes.list', { name: body.nodeName }));
    if (nodes.nodes.some(value => value.name === body.nodeName)) fail('conflict', 'An existing node cannot be attached without host enrollment.');
    const value: P.Machine = services.resource('machine', { nodeId: null, nodeName: body.nodeName, name: body.name, ownerUserId: user(context).userId, accessUserIds: [], status: 'pending', lastSeenAtMs: null, labels: body.labels ?? {}, botIds: [] });
    services.store.put('machines', value); context.nonceResourceIds.push(value.id);
    services.events.emit('machine.upserted', value, { machineId: value.id });
    return { machine: value, invite: await issue(context, value, body.expiresInMs) } satisfies P.MachineAttachResult;
  }, 201, 'admin');
  add('GET', '/machines/:id', async context => { machine(context); await refreshMachines(services); return machine(context); });
  add('PATCH', '/machines/:id', context => {
    const body = parse(update.extend({ name: text.optional(), accessUserIds: z.array(id).max(200).optional(), labels: labels.optional() }), context.body);
    const value = machine(context, true); manager(user(context), value); services.mutations.checkRevision(value, body.revision);
    if (body.accessUserIds) for (const userId of body.accessUserIds) { const member = services.auth.member(userId); if (!member.enabled) fail('invalid_request', 'Machine access requires an enabled member.'); }
    const changes: Partial<P.Machine> = {}; if (body.name !== undefined) changes.name = body.name; if (body.labels !== undefined) changes.labels = body.labels; if (body.accessUserIds !== undefined) changes.accessUserIds = [...new Set(body.accessUserIds)];
    const next = services.update(value, changes); services.store.put('machines', next); services.events.emit('machine.upserted', next, { machineId: value.id }); return next;
  });
  add('POST', '/machines/:id/reconnect', async context => {
    const body = parse(mutation.extend({ expiresInMs: ttl }), context.body); const value = machine(context, true); manager(user(context), value);
    if (value.status === 'revoked') fail('conflict', 'A detached machine must be explicitly enrolled again.');
    for (const invitation of services.store.list<P.MachineInvite>('machineInvites', item => item.machineId === value.id && item.status === 'pending')) await revokeInvite(user(context), invitation);
    return issue(context, value, body.expiresInMs);
  });
  add('GET', '/machines/:id/invites', context => { parse(pageQuery, queryObject(context.query)); const value = machine(context, true); manager(user(context), value); return services.page(context, services.store.list<P.MachineInvite>('machineInvites', item => item.machineId === value.id)); });
  add('DELETE', '/machines/:id/invites/:inviteId', async context => { parse(mutation, context.body); const value = machine(context, true); const invitation = services.store.require<P.MachineInvite>('machineInvites', context.params.inviteId!); if (invitation.machineId !== value.id) fail('not_found', 'Machine invitation not found.'); await revokeInvite(user(context), invitation); return { id: invitation.id, deleted: true }; });
  add('GET', '/machines/:id/host', context => getHostInfo(services, user(context), machine(context, false, true).id));
  function detachBinding(value: P.Machine) {
    const bots = services.store.list<P.Bot>('bots', item => item.machineId === value.id);
    const routines = services.store.list<P.Routine>('routines', item => bots.some(bot => bot.id === item.botId));
    return { botIds: bots.map(item => item.id).sort(), routineIds: routines.map(item => item.id).sort(), runIds: services.store.list<P.Run>('runs', item => bots.some(bot => bot.id === item.botId) && !['succeeded', 'failed', 'cancelled'].includes(item.status)).map(item => item.id).sort() };
  }
  add('POST', '/machines/:id/preview', context => {
    const body = parse(mutation.extend({ action: z.literal('detach') }), context.body); const value = machine(context, true); manager(user(context), value); const binding = detachBinding(value);
    const affected: P.ScopeEffect[] = [{ resourceType: 'machine', id: value.id, machineId: value.id, operation: 'revoke', explanation: 'Revoke execution trust; keep host files, SSH, browser logins and installed software.' }, ...binding.botIds.map(id => ({ resourceType: 'bot', id, machineId: value.id, operation: 'retain' as const, explanation: 'Bot remains visible offline until moved or deleted.' })), ...binding.routineIds.map(id => ({ resourceType: 'routine', id, machineId: value.id, operation: 'retain' as const, explanation: 'Pause future triggers; retained routine metadata.' }))];
    return services.mutations.preview(user(context), value, body.action, value.name, ['Cancel active work and pause future routines.', 'Revoke node trust, not SSH or user host data.'], affected, binding);
  });
  add('DELETE', '/machines/:id', async context => {
    const body = parse(confirm, context.body); const value = machine(context, true); manager(user(context), value); const binding = detachBinding(value);
    services.mutations.confirm(user(context), value, 'detach', body, binding);
    context.nonceResourceIds.push(value.id);
    // Disabling schedules is acknowledged before revoking execution trust.
    for (const routineId of binding.routineIds) { const routine = services.store.require<P.Routine>('routines', routineId); if (routine.cronJobId && routine.enabled) await services.lemon.call('cron.pause', { id: routine.cronJobId }, { mutation: true, resourceIds: [routineId, value.id] }); const paused = services.update(routine, { enabled: false, nextRunAtMs: null }); services.store.put('routines', paused); services.events.emit('routine.upserted', paused, { userIds: [routine.ownerUserId] }); }
    const stopped = await quiesceMachineInvocations(services, user(context), value.id);
    if (stopped.status !== 'cancelled') fail('outcome_unknown', 'The machine’s executing invocations have not reached an acknowledged terminal state.', false, { resourceIds: [value.id, ...stopped.runIds] });
    await terminal.closeMachine(value.id);
    if (value.nodeId) await services.lemon.call('nodes.revoke', { nodeId: value.nodeId, confirmName: value.nodeName }, { mutation: true, resourceIds: [value.id] });
    for (const invitation of services.store.list<P.MachineInvite>('machineInvites', item => item.machineId === value.id && item.status === 'pending')) await revokeInvite(user(context), invitation);
    const revoked = services.update(value, { status: 'revoked' }); services.store.put('machines', revoked); services.events.emit('machine.deleted', { id: value.id, deleted: true }, { machineId: value.id });
    for (const botId of binding.botIds) { const bot = services.store.require<P.Bot>('bots', botId); const offline = services.update(bot, { activity: 'offline' }); services.store.put('bots', offline); emitBotRuntimeProjection(services, offline); }
    services.audit(user(context), 'machine.detach', value.id, 'succeeded'); return { id: value.id, deleted: true };
  });
  add('GET', '/machines/:id/files', async context => {
    const query = parse(pageQuery.extend({ path, showHidden: z.enum(['true', 'false']).optional() }), queryObject(context.query)); const value = machine(context, false, true);
    const listing = remote(z.object({ entries: z.array(statSchema.extend({ name: z.string() })), truncated: z.boolean() }).passthrough(), await services.lemon.call('node.fs.list', { nodeId: value.nodeId!, path: query.path, showHidden: query.showHidden === 'true' }));
    if (listing.truncated) fail('too_large', 'This directory exceeds the destination listing limit; choose a narrower directory.');
    const files = listing.entries.map(fileInfo); files.sort((a, b) => Number(a.kind !== 'directory') - Number(b.kind !== 'directory') || a.name.localeCompare(b.name) || a.path.localeCompare(b.path));
    return services.page(context, files, { ascending: true, key: item => `${item.kind === 'directory' ? '0' : '1'}:${item.name}:${item.path}`, binding: { machineId: value.id, path: query.path, showHidden: query.showHidden ?? 'false', snapshot: services.mutations.digest(listing.entries) } });
  });
  add('GET', '/machines/:id/files/stat', async context => { const query = parse(z.object({ path }).strict(), queryObject(context.query)); return fileInfo(await stat(machine(context, false, true), query.path)); });
  add('GET', '/machines/:id/files/read', async context => {
    const query = parse(z.object({ path, offset: z.coerce.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(), length: z.coerce.number().int().min(1).max(1_048_576).optional() }).strict(), queryObject(context.query)); const value = machine(context, false, true);
    const result = remote(chunkSchema, await services.lemon.call('node.fs.read', { nodeId: value.nodeId!, path: query.path, offset: query.offset ?? 0, length: query.length ?? 1_048_576 })); decodeChunk(result.dataBase64, 1_048_576); return { path: result.path, offset: result.offset, dataBase64: result.dataBase64, size: result.size, mime: result.mime, eof: result.eof } satisfies P.FileChunk;
  });
  add('PUT', '/machines/:id/files', async context => {
    const body = parse(mutation.extend({ path, dataBase64: z.string().max(1_398_104), offset: integer.optional(), truncate: z.boolean().optional(), mkdirs: z.boolean().optional(), expectedModifiedAtMs: integer.optional() }), context.body); decodeChunk(body.dataBase64, 1_048_576); if (body.truncate && (body.offset ?? 0) !== 0) fail('invalid_request', 'Truncate requires offset zero.'); const value = machine(context, false, true);
    const written = remote(z.object({ path, offset: integer, bytesWritten: integer, size: integer, mtimeMs: integer }).passthrough(), await services.lemon.call('node.fs.write', { nodeId: value.nodeId!, path: body.path, dataBase64: body.dataBase64, offset: body.offset ?? 0, truncate: body.truncate ?? false, mkdirs: body.mkdirs ?? false, expectedModifiedAtMs: body.expectedModifiedAtMs ?? 0 }, { mutation: true, resourceIds: [value.id] }));
    try { const info = fileInfo(await stat(value, written.path)); if (info.modifiedAtMs !== written.mtimeMs || info.size !== written.size) fail('revision_conflict', 'The file changed after this acknowledged write.'); return info; }
    catch { fail('outcome_unknown', 'The write was acknowledged but its current file receipt cannot be confirmed. Inspect the destination before another write.', false, { resourceIds: [value.id] }); }
  });
  add('POST', '/machines/:id/files/mkdir', async context => { const body = parse(mutation.extend({ path }), context.body); const value = machine(context, false, true); await services.lemon.call('node.fs.mkdir', { nodeId: value.nodeId!, path: body.path }, { mutation: true, resourceIds: [value.id] }); try { return fileInfo(await stat(value, body.path)); } catch { fail('outcome_unknown', 'Directory creation was acknowledged but its current receipt is unavailable.', false, { resourceIds: [value.id] }); } }, 201);
  add('POST', '/machines/:id/files/move', async context => { const body = parse(mutation.extend({ path, destination: path, expectedModifiedAtMs: integer }), context.body); const value = machine(context, false, true); await services.lemon.call('node.fs.move', { nodeId: value.nodeId!, path: body.path, destination: body.destination, expectedModifiedAtMs: body.expectedModifiedAtMs, overwrite: false }, { mutation: true, resourceIds: [value.id] }); try { return fileInfo(await stat(value, body.destination)); } catch { fail('outcome_unknown', 'The move was acknowledged but its destination receipt is unavailable.', false, { resourceIds: [value.id] }); } });
  add('POST', '/machines/:id/files/preview', async context => {
    const body = parse(mutation.extend({ path, action: z.literal('delete') }), context.body); const value = machine(context, false, true);
    const upstream = remote(z.object({ path, stat: statSchema, childCount: integer, childrenDigest: z.string(), candidateCount: integer, confirmationToken: z.string(), expiresAtMs: integer }).passthrough(), await services.lemon.call('node.fs.delete.preview', { nodeId: value.nodeId!, path: body.path }));
    const snapshot = services.mutations.digest({ stat: upstream.stat, childrenDigest: upstream.childrenDigest, candidateCount: upstream.candidateCount });
    const targetId = `file_${services.mutations.digest({ machineId: value.id, path: body.path }).slice(0, 40)}`;
    const target = { id: targetId, revision: 1 }; const name = fileInfo(upstream.stat).name;
    const preview = services.mutations.preview(user(context), target, 'delete', name, [`Delete this destination ${upstream.stat.type === 'directory' ? 'directory' : 'file'} (${upstream.candidateCount} affected item(s)).`, 'Product transcripts, imported attachments and backups remain.'], [{ resourceType: 'file', id: body.path, machineId: value.id, operation: 'delete', explanation: 'Delete the exact previewed destination-local file; retain independently imported product attachments.' }], snapshot);
    services.store.setMetadata(`filePreview:${preview.confirmationToken}`, { machineId: value.id, path: body.path, principalId: user(context).id, targetId, revision: target.revision, snapshot, upstreamToken: upstream.confirmationToken, expiresAtMs: upstream.expiresAtMs, name } satisfies FilePreviewBinding);
    return preview;
  });
  add('DELETE', '/machines/:id/files', async context => {
    const body = parse(mutation.extend({ path, confirmationToken: z.string().min(16).max(512), confirmName: z.string().min(1).max(4096) }), context.body); const value = machine(context, false, true); const saved = services.store.metadata<FilePreviewBinding>(`filePreview:${body.confirmationToken}`);
    if (!saved || saved.machineId !== value.id || saved.path !== body.path || saved.principalId !== user(context).id) fail('confirmation_required', 'Preview this exact file before deleting it.');
    if (saved.expiresAtMs <= services.now()) fail('expired', 'The destination deletion preview expired.');
    services.mutations.confirm(user(context), { id: saved.targetId, revision: saved.revision }, 'delete', { ...body, revision: saved.revision }, saved.snapshot);
    await services.lemon.call('node.fs.delete', { nodeId: value.nodeId!, path: body.path, confirm: body.path, confirmationToken: saved.upstreamToken }, { mutation: true, resourceIds: [value.id] }); return { id: body.path, deleted: true };
  });
  add('POST', '/machines/:id/files/import', async context => {
    const body = parse(mutation.extend({ path, conversationId: id.optional(), botId: id.optional() }), context.body);
    const value = machine(context, false, true);
    return importMachineFile(services, user(context), value.id, body);
  }, 201);
  add('GET', '/machines/:id/secrets', async context => {
    parse(pageQuery, queryObject(context.query)); const value = machine(context, false, true); const result = remote(z.object({ names: z.array(z.string()) }).passthrough(), await services.lemon.call('node.secrets.list', { nodeId: value.nodeId! }));
    const secrets = result.names.filter(name => /^[A-Z][A-Z0-9_]{0,63}$/.test(name)).map(name => { const stored = services.store.list<P.Secret & { machineId: string }>('secrets', item => item.machineId === value.id && item.name === name)[0]; return stored ?? { id: `secret_${services.mutations.digest({ machineId: value.id, name }).slice(0, 40)}`, revision: 1, createdAtMs: value.createdAtMs, updatedAtMs: value.updatedAtMs, name, description: '', scope: 'machine' as const, botId: null }; }).filter(secret => secret.botId === null || services.auth.canRead(user(context), 'bots', services.store.get('bots', secret.botId)));
    return services.page(context, secrets.map(({ id, revision, createdAtMs, updatedAtMs, name, description, scope, botId }) => ({ id, revision, createdAtMs, updatedAtMs, name, description, scope, botId })));
  });
  add('PUT', '/machines/:id/secrets/:name', async context => {
    const body = parse(mutation.extend({ description: boundedText(1024), value: boundedText(32_768, 1), scope: z.enum(['machine', 'bot']), botId: id.optional() }), context.body); const name = parse(z.string().regex(/^[A-Z][A-Z0-9_]{0,63}$/), context.params.name); const value = machine(context, false, true);
    if (body.scope === 'bot') { if (!body.botId) fail('invalid_request', 'Bot scope requires a bot.'); if (services.auth.bot(user(context), body.botId, true).machineId !== value.id) fail('invalid_request', 'Bot secret belongs to a different machine.'); } else if (body.botId) fail('invalid_request', 'Machine scope cannot name a bot.');
    if (new TextEncoder().encode(body.value).byteLength > 32_768) fail('too_large', 'Secret value exceeds 32 KiB.');
    const existing = services.store.list<P.Secret & { machineId: string }>('secrets', item => item.machineId === value.id && item.name === name)[0];
    const secret: P.Secret = existing ? services.update(existing, { description: body.description, scope: body.scope, botId: body.botId ?? null }) : services.resource('secret', { name, description: body.description, scope: body.scope, botId: body.botId ?? null }); context.nonceResourceIds.push(secret.id);
    await services.lemon.call('node.secrets.set', { nodeId: value.nodeId!, name, value: body.value }, { mutation: true, resourceIds: [secret.id, value.id] }); services.store.put('secrets', { ...secret, machineId: value.id }); services.audit(user(context), 'machine.secret.set', value.id, 'succeeded'); return { id: secret.id, revision: secret.revision, createdAtMs: secret.createdAtMs, updatedAtMs: secret.updatedAtMs, name, description: secret.description, scope: secret.scope, botId: secret.botId } satisfies P.Secret;
  });
  add('DELETE', '/machines/:id/secrets/:name', async context => { parse(mutation, context.body); const name = parse(z.string().regex(/^[A-Z][A-Z0-9_]{0,63}$/), context.params.name); const value = machine(context, false, true); const existing = services.store.list<P.Secret & { machineId: string }>('secrets', item => item.machineId === value.id && item.name === name)[0]; if (existing?.botId) services.auth.bot(user(context), existing.botId, true); await services.lemon.call('node.secrets.delete', { nodeId: value.nodeId!, name }, { mutation: true, resourceIds: [value.id] }); if (existing) services.store.remove('secrets', existing.id); return { id: existing?.id ?? name, deleted: true }; });
  const size = { cols: z.number().int().min(20).max(500), rows: z.number().int().min(5).max(300) };
  add('POST', '/machines/:id/terminals', async context => { const body = parse(mutation.extend({ deviceId: id, cwd: path.optional(), ...size }), context.body); const value = machine(context, false, true); const input = body.cwd === undefined ? { ...body, cwd: (await getHostInfo(services, user(context), value.id)).defaultCwd } : body; return terminal.open(user(context), value, input, context); }, 201);
  add('GET', '/terminals/:id', context => terminal.require(user(context), context.params.id!));
  add('POST', '/terminals/:id/input', async context => { const body = parse(mutation.extend({ dataBase64: z.string().max(87_384) }), context.body); return terminal.input(user(context), context.params.id!, body.dataBase64); });
  add('POST', '/terminals/:id/resize', async context => { const body = parse(mutation.extend(size), context.body); return terminal.resize(user(context), context.params.id!, body.cols, body.rows); });
  add('DELETE', '/terminals/:id', async context => { parse(mutation, context.body); return terminal.close(user(context), context.params.id!); });
  return routes;
}

export interface FileToolProvenance { filename?: string; runId?: string; sourceEntryId?: string }

/** Shared bounded transfer: immutable filename and provenance are assigned before blob creation. */
export async function importMachineFile(services: BackendServices, actor: Principal, machineId: string, input: P.FileImport, provenance: FileToolProvenance = {}): Promise<P.Attachment> {
  const scopedRun = provenance.runId ? services.store.require<P.Run>('runs', provenance.runId) : null;
  const retained = scopedRun ? services.store.metadata<Principal>(`runPrincipal:${scopedRun.id}`) : null;
  if (scopedRun && (!retained || retained.kind !== actor.kind || retained.id !== actor.id || retained.userId !== actor.userId || scopedRun.botId !== input.botId || scopedRun.conversationId !== input.conversationId || !['running', 'awaiting_input', 'queued'].includes(scopedRun.status))) fail('forbidden', 'Only the actual bot invocation may import its output file.');
  const sourceBot = scopedRun ? services.auth.bot(actor, scopedRun.botId) : null;
  const machine = sourceBot ? services.store.require<P.Machine>('machines', machineId) : services.auth.machine(actor, machineId);
  if (sourceBot) {
    if (sourceBot.machineId !== machine.id) fail('forbidden', 'Invocation file import belongs to another machine.');
    const measured = await machineCapabilities(services, actor, machine.id, sourceBot);
    const grants = await effectiveBotGrants(services, actor, sourceBot, measured);
    const files = measured.items.find(item => item.category === 'files');
    if (!files || !grants.some(grant => grant.capabilityId === files.id && grant.effectiveLevel !== 'off')) fail('policy_denied', 'This bot does not have effective file-read permission on its machine.');
  }
  if (!services.lemon.connected) fail('upstream_unavailable', 'The controller is not connected.');
  if (!machine.nodeId || machine.status !== 'online') fail('machine_offline', 'The destination is not online.');
  if (input.conversationId) services.auth.conversation(actor, input.conversationId);
  if (input.botId && services.auth.bot(actor, input.botId).machineId !== machine.id) fail('invalid_request', 'Bot file import belongs to another destination.');
  const run = provenance.runId ? services.store.require<P.Run>('runs', provenance.runId) : null;
  if (run && (run.botId !== input.botId || run.initiatorUserId !== actor.userId || run.conversationId !== input.conversationId)) fail('forbidden', 'File provenance does not belong to this bot invocation.');
  if (provenance.sourceEntryId) { const entry = services.store.require<P.TranscriptEntry>('entries', provenance.sourceEntryId); if (!input.conversationId || entry.conversationId !== input.conversationId || !services.auth.canRead(actor, 'entries', entry)) fail('not_found', 'File source entry is not accessible.'); }
  const before = remote(statSchema, await services.lemon.call('node.fs.stat', { nodeId: machine.nodeId, path: input.path }));
  if (before.type !== 'regular') fail('invalid_request', 'Only regular destination files may be imported.');
  if (before.size > 200 * 1_048_576) fail('too_large', 'File import exceeds 200 MiB; content-inspected non-video attachments remain limited to 25 MiB.');
  const bytes = new Uint8Array(before.size); let offset = 0;
  while (offset < bytes.length) {
    const result = remote(chunkSchema, await services.lemon.call('node.fs.read', { nodeId: machine.nodeId, path: before.path, offset, length: Math.min(1_048_576, bytes.length - offset) }));
    const chunk = decodeChunk(result.dataBase64, 1_048_576);
    if (result.offset !== offset || result.path !== before.path || result.size !== before.size || !chunk.length || offset + chunk.length > bytes.length) fail('revision_conflict', 'The destination file changed during transfer.');
    bytes.set(chunk, offset); offset += chunk.length;
  }
  const after = remote(statSchema, await services.lemon.call('node.fs.stat', { nodeId: machine.nodeId, path: before.path }));
  if (after.size !== before.size || after.mtimeMs !== before.mtimeMs) fail('revision_conflict', 'The destination file changed during transfer.');
  const metadata = { clientNonce: input.clientNonce, purpose: 'message' as const, filename: provenance.filename ?? fileInfo(before).name, source: 'node' as const, ...(input.botId ? { botId: input.botId } : {}), ...(input.conversationId ? { conversationId: input.conversationId } : {}), provenance: { botId: input.botId ?? null, runId: run?.id ?? null, machineId: machine.id, sourceEntryId: provenance.sourceEntryId ?? null, generatedAtMs: run?.completedAtMs ?? null } };
  return services.attachments.create(actor, bytes, metadata);
}
