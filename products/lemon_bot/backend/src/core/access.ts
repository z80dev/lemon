import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal } from './services';
import { fail } from './errors';
import { effectiveBotGrants, machineCapabilities } from './experiences';
import { sendMessage } from './conversations';
import { endApprovalAllowances } from './approval-allowances';
import { markBotProfilesForRefresh } from './bots';

const rank: Record<P.AccessLevel, number> = { off: 0, read_only: 1, read_interact: 2 };
const categories = { terminal: 'shell', files: 'files', browser: 'browser' } as const;
const labels = { terminal: 'Terminal', files: 'Files', browser: 'Browser' } as const;
const active: Partial<Record<P.Run['status'], true>> = { reserved: true, queued: true, running: true, awaiting_input: true, outcome_unknown: true };
export interface AccessPlan { capabilityIds: string[]; levels: Record<string, P.AccessLevel>; title: string; description: string }
export interface AccessFailure { code: P.ErrorCode | 'already_available'; message: string }
export interface PreparedAccessChanges { bot: P.Bot; changes: Record<string, P.AccessLevel>; accessRequestId: string }
export interface JitAccessService {
  prepare(principal: Principal, approval: P.Approval): Promise<PreparedAccessChanges | null>;
  queue(prepared: PreparedAccessChanges): void;
  schedule(botId: string): void;
  reconcileAll(): Promise<void>;
  close(): void;
}
export interface AccessRequestRecord extends P.Resource {
  botId: string; machineId: string; conversationId: string; runId: string; sourceEntryId: string | null;
  capabilityIds: string[]; levels: Record<string, P.AccessLevel>;
  state: 'queued' | 'applying' | 'applied' | 'continued' | 'not_continued' | 'failed';
  continuation?: { text: string; dispatch: boolean };
}

/** Computes a server-owned scope; model text can never select tools or grant rows. */
export function requestable(s: BackendServices, owner: Principal, bot: P.Bot, measured: P.MachineCapabilities, policy: P.EffectivePolicy, grants: P.BotGrant[], capability: P.AccessCapability, access: 'view' | 'full' = 'full'): AccessPlan | AccessFailure {
  if (owner.kind !== 'user' || owner.userId !== bot.ownerUserId) return { code: 'forbidden', message: 'Only the Bot owner can grant access.' };
  if (!policy.productAccess || policy.localExecutionCeiling === 'deny') return { code: 'policy_denied', message: 'Current policy does not allow local access.' };
  const item = measured.items.find(value => value.id === capability && value.category === categories[capability]);
  const available = (value: P.MachineCapabilities['items'][number] | undefined) => !!value && !measured.stale && !value.stale && value.supported && ['granted', 'not_required'].includes(value.osGrant) && value.configuredLevel !== 'off';
  if (measured.machineId !== bot.machineId || !available(item) || !s.lemon.methods.includes('profiles.update')) return { code: 'capability_unavailable', message: 'This machine cannot currently provide that access.' };
  const target: P.AccessLevel = capability === 'terminal' || access !== 'view' ? 'read_interact' : 'read_only';
  const level: P.AccessLevel = rank[item!.configuredLevel] < rank[target] ? item!.configuredLevel : target;
  if (capability === 'terminal' && level !== 'read_interact') return { code: 'capability_unavailable', message: 'Terminal has no enforceable read-only access.' };
  const grant = grants.find(value => value.capabilityId === capability);
  if (rank[grant?.requestedLevel ?? 'off'] >= rank[level] || rank[grant?.pendingLevel ?? 'off'] >= rank[level]) return { code: 'already_available', message: 'This access is already available or queued.' };
  const changes: Record<string, P.AccessLevel> = { [capability]: level };
  if (capability === 'terminal') {
    const files = measured.items.find(value => value.id === 'files' && value.category === 'files');
    const fileGrant = grants.find(value => value.capabilityId === 'files');
    if (available(files)) {
      const fileLevel = files!.configuredLevel;
      if (rank[fileGrant?.requestedLevel ?? 'off'] < rank[fileLevel] && rank[fileGrant?.pendingLevel ?? 'off'] < rank[fileLevel]) changes.files = fileLevel;
    }
  }
  const machine = s.store.get<P.Machine>('machines', bot.machineId);
  const consequence = capability === 'terminal' ? 'run commands and work with files' : capability === 'files' ? level === 'read_only' ? 'read files' : 'read and change files' : level === 'read_only' ? 'view browser pages' : 'view and interact with browser pages';
  return { capabilityIds: Object.keys(changes), levels: changes, title: `${bot.name} needs ${labels[capability]}`, description: `Allow ${bot.name} to ${consequence} on ${machine?.name ?? 'this machine'}${capability === 'terminal' && changes.files ? ` (including Files access: ${changes.files === 'read_only' ? 'view' : 'full'})` : ''}. Individual actions still follow your review policy.` };
}
export function anyRequestable(s: BackendServices, owner: Principal, bot: P.Bot, measured: P.MachineCapabilities, policy: P.EffectivePolicy, grants: P.BotGrant[]): boolean {
  return (Object.keys(categories) as P.AccessCapability[]).some(capability => !('code' in requestable(s, owner, bot, measured, policy, grants, capability)));
}

/** Synchronous by design: approval transition and pending rows share the caller's transaction. */
export function queueGrantChanges(s: BackendServices, bot: P.Bot, changes: Record<string, P.AccessLevel>, accessRequestId?: string): void {
  const currentBot = s.store.require<P.Bot>('bots', bot.id);
  if (currentBot.machineId !== bot.machineId || currentBot.profileId !== bot.profileId || currentBot.revision !== bot.revision || s.store.metadata(`botLifecycle:${bot.id}`)) fail('policy_denied', 'This Bot’s setup changed. Ask for access again.');
  const approval = accessRequestId ? s.store.require<P.Approval>('approvals', accessRequestId) : null;
  const actualChanges: Record<string, P.AccessLevel> = {};
  if (approval) {
    const primary = s.store.list<P.BotGrant>('botGrants', value => value.botId === bot.id && value.machineId === bot.machineId && value.capabilityId === approval.inputs.capability)[0];
    const target = changes[String(approval.inputs.capability)];
    if (!target || rank[primary?.requestedLevel ?? 'off'] >= rank[target] || rank[primary?.pendingLevel ?? 'off'] >= rank[target]) return;
  }
  for (const [capabilityId, pendingLevel] of Object.entries(changes)) {
    const grant = s.store.list<P.BotGrant>('botGrants', value => value.botId === bot.id && value.machineId === bot.machineId && value.capabilityId === capabilityId)[0];
    if (!grant) fail('not_found', 'The requested grant no longer exists.');
    if (approval && (rank[grant.requestedLevel] >= rank[pendingLevel] || rank[grant.pendingLevel ?? 'off'] >= rank[pendingLevel])) continue;
    actualChanges[capabilityId] = pendingLevel;
    const next = s.update(grant, { pendingLevel: grant.requestedLevel === pendingLevel ? null : pendingLevel });
    s.store.put('botGrants', next);
    s.events.emit('grant.upserted', next, { userIds: [bot.ownerUserId], botId: bot.id });
  }
  if (accessRequestId && approval && Object.keys(actualChanges).length) {
    if (!approval.runId) fail('invalid_request', 'Access requests require an originating run.');
    const origin = s.store.require<P.Run>('runs', approval.runId);
    if (origin.botId !== bot.id || origin.initiatorUserId !== bot.ownerUserId) fail('forbidden', 'The access request belongs to a different execution.');
    const record: AccessRequestRecord = { ...s.resource('access', { botId: bot.id, machineId: bot.machineId, conversationId: origin.conversationId, runId: approval.runId, sourceEntryId: s.store.metadata<string>(`runSourceEntry:${approval.runId}`), capabilityIds: Object.keys(actualChanges), levels: actualChanges, state: 'queued' as const }), id: accessRequestId, createdAtMs: approval.createdAtMs };
    s.store.put('accessRequests', record);
    s.store.setMetadata(`accessRequestQueued:${accessRequestId}`, true);
  }
}

function ownerPrincipal(s: BackendServices, ownerUserId: string): Principal | null {
  const member = s.store.list<P.Member>('members', value => value.userId === ownerUserId && value.enabled)[0];
  const workspaceId = s.store.metadata<string>('workspaceId');
  return member && workspaceId ? { kind: 'user', id: member.userId, userId: member.userId, workspaceId, role: member.role, sessionId: null, botId: null, deviceId: null } : null;
}

export function createAccessService(s: BackendServices): JitAccessService {
  let closed = false;
  const jobs = new Map<string, Promise<void>>();
  const records = (botId: string) => s.store.list<AccessRequestRecord>('accessRequests', value => value.botId === botId);
  const hasActive = (botId: string) => s.store.list<P.Run>('runs', value => value.botId === botId && active[value.status] === true).length > 0;
  function notice(owner: Principal, record: AccessRequestRecord, text: string, state: 'failed' | 'not_continued'): void {
    s.store.transaction(() => {
      const current = s.store.get<AccessRequestRecord>('accessRequests', record.id);
      if (!current || ['continued', 'not_continued', 'failed'].includes(current.state)) return;
      const room = s.store.get<P.Conversation>('conversations', record.conversationId);
      if (room?.ownerUserId === owner.userId) s.entry(owner, room.id, { kind: 'notice', severity: 'info', text, requestId: null, targetedUserId: owner.userId, actor: { kind: 'system', id: null, displayName: 'System' } });
      s.store.put('accessRequests', s.update(current, { state }));
    });
  }
  function publishAcknowledgedGrants(owner: Principal, botId: string, grants: P.BotGrant[]): void {
    const key = `botPolicySync:${botId}`;
    const sync = s.store.metadata<{ state: string; grantIds?: string[]; applier?: boolean; published?: boolean }>(key);
    if (sync?.state !== 'acknowledged' || !sync.applier || sync.published) return;
    s.store.transaction(() => {
      for (const grant of grants) {
        if (!sync.grantIds?.includes(grant.id)) continue;
        s.store.put('botGrants', grant);
        s.events.emit('grant.upserted', grant, { userIds: [owner.userId], botId });
      }
      endApprovalAllowances(s, owner, { botId }, 'permissions_changed');
      s.store.setMetadata(key, { ...sync, published: true });
    });
  }
  async function continueRequest(owner: Principal, bot: P.Bot, record: AccessRequestRecord): Promise<void> {
    const groupKey = `accessContinuation:${record.botId}:${record.runId}:${record.sourceEntryId ?? ''}`;
    const shared = s.store.metadata<{ nonce: string; continuation?: AccessRequestRecord['continuation']; continued?: boolean }>(groupKey)
      ?? { nonce: `access_${createHash('sha256').update(groupKey).digest('hex').slice(0, 40)}` };
    if (shared.continued) {
      s.store.put('accessRequests', s.update(record, { state: 'continued' }));
      return;
    }
    if (shared.continuation) record = { ...record, continuation: shared.continuation };
    const approval = s.store.get<P.Approval>('approvals', record.id);
    const label = labels[approval?.inputs.capability as P.AccessCapability] ?? 'Access';
    const room = s.store.get<P.Conversation>('conversations', record.conversationId);
    const run = s.store.get<P.Run>('runs', record.runId);
    const source = record.sourceEntryId ? s.store.get<P.TranscriptEntry>('entries', record.sourceEntryId) : null;
    const newerHuman = s.store.list<P.TranscriptEntry>('entries', entry => entry.conversationId === record.conversationId && entry.kind === 'message' && entry.actor.kind === 'user' && entry.timestampMs >= record.createdAtMs && entry.id !== source?.id && !s.store.metadata(`externalEntry:${entry.id}`)).length > 0;
    const canContinue = !!room && room.ownerUserId === owner.userId && room.botIds.includes(bot.id) && !!run && ['succeeded', 'failed'].includes(run.status) && !!source && source.kind === 'message' && source.actor.kind === 'user' && source.actor.id === owner.userId && source.conversationId === room.id && !s.store.metadata(`externalEntry:${source.id}`) && !newerHuman;
    if (record.continuation?.dispatch && !canContinue) {
      const nonce = shared.nonce;
      if (!s.store.metadata(`messageReceipt:${owner.kind}:${owner.id}:${record.conversationId}:${nonce}`)) {
        notice(owner, record, `${label} is now on for ${bot.name}. Send your request again when you're ready.`, 'not_continued');
        return;
      }
    }
    const noticeText = `${label} is now on for ${bot.name}. Send your request again when you're ready.`;
    if (!record.continuation) {
      const prefix = `${label} is now on for ${bot.name} — continuing your request.\n\nOriginal request (quoted):\n`;
      const original = source && source.kind === 'message' ? source.text : '';
      const budget = 65536 - Buffer.byteLength(prefix);
      const quoted = Buffer.byteLength(original) <= budget ? original : new TextDecoder().decode(Buffer.from(original).subarray(0, budget - 4), { stream: true }) + '\n…';
      record = s.update(record, { continuation: { dispatch: canContinue, text: canContinue ? prefix + quoted : noticeText } });
      s.store.put('accessRequests', record);
      shared.continuation = record.continuation;
      s.store.setMetadata(groupKey, shared);
    }
    if (!record.continuation!.dispatch) { notice(owner, record, record.continuation!.text, 'not_continued'); return; }
    // A persisted send receipt is the only retry path: sendMessage never redispatches a nonce.
    const clientNonce = shared.nonce;
    await sendMessage(s, owner, record.conversationId, { clientNonce, text: record.continuation!.text, mentions: [bot.id] }, undefined, undefined, { sourceEntryId: record.sourceEntryId!, actor: { kind: 'system', id: null, displayName: 'System' } });
    s.store.setMetadata(groupKey, { ...shared, continued: true });
    const current = s.store.get<AccessRequestRecord>('accessRequests', record.id);
    if (current) s.store.put('accessRequests', s.update(current, { state: 'continued' }));
  }
  async function apply(botId: string): Promise<void> {
    if (closed || hasActive(botId) || s.store.metadata(`botLifecycle:${botId}`)) return;
    const bot = s.store.get<P.Bot>('bots', botId);
    if (!bot) {
      for (const record of records(botId).filter(value => ['queued', 'applying', 'applied'].includes(value.state))) {
        const room = s.store.get<P.Conversation>('conversations', record.conversationId);
        const owner = room ? ownerPrincipal(s, room.ownerUserId) : null;
        if (owner) notice(owner, record, 'This Bot was removed. Its access request was not continued.', 'not_continued');
        else s.store.put('accessRequests', s.update(record, { state: 'not_continued' }));
      }
      return;
    }
    const owner = ownerPrincipal(s, bot.ownerUserId), machine = s.store.get<P.Machine>('machines', bot.machineId);
    if (!owner || !s.lemon.connected || machine?.status !== 'online') return;
    const syncKey = `botPolicySync:${bot.id}`;
    const sync = s.store.metadata<{ state: string; applier?: boolean; published?: boolean }>(syncKey);
    if (sync && sync.state !== 'acknowledged') return;
    if (!(sync?.applier && !sync.published) && !s.store.metadata(`profileRefresh:${botId}`) && !s.store.list<P.BotGrant>('botGrants', value => value.botId === botId && value.pendingLevel != null).length && !records(botId).some(value => ['queued', 'applying', 'applied'].includes(value.state))) return;
    // Readback reconciliation can acknowledge a cutover after the original caller crashed.
    const grants = await effectiveBotGrants(s, owner, bot);
    publishAcknowledgedGrants(owner, botId, grants);
    for (const record of records(botId).filter(value => value.state === 'applying')) {
      const applied = record.machineId === bot.machineId && record.capabilityIds.every(id => grants.some(grant => grant.capabilityId === id && rank[grant.effectiveLevel] >= rank[record.levels[id]!]));
      if (applied) s.store.put('accessRequests', s.update(record, { state: 'applied' }));
      else notice(owner, record, 'Requested access could not be applied. Check this Bot’s access settings and send your request again.', 'failed');
    }
    const pending = s.store.list<P.BotGrant>('botGrants', value => value.botId === botId && value.machineId === bot.machineId && value.pendingLevel != null);
    const refresh = s.store.metadata(`profileRefresh:${botId}`);
    if (pending.length || refresh) {
      const measured = await machineCapabilities(s, owner, bot.machineId, bot);
      const valid = pending.filter(grant => {
        if (grant.capabilityId.startsWith('connector:')) return !!s.integrations.connectorProvisioning && !!s.store.get('connectors', grant.capabilityId.slice(10));
        const item = measured.items.find(value => value.id === grant.capabilityId && ['files', 'shell', 'browser'].includes(value.category));
        return !!item && item.supported && !(item.category === 'shell' && grant.pendingLevel === 'read_only');
      });
      // No await between the admission check and installing the cutover fence.
      const currentSync = s.store.metadata<{ state: string }>(syncKey);
      const liveBot = s.store.get<P.Bot>('bots', botId);
      if (!liveBot || liveBot.machineId !== bot.machineId || liveBot.profileId !== bot.profileId || liveBot.revision !== bot.revision) return;
      if (closed || hasActive(botId) || s.store.metadata(`botLifecycle:${botId}`) || currentSync && currentSync.state !== 'acknowledged') return;
      s.store.transaction(() => {
        const changed = pending.map(grant => {
          s.mutations.checkRevision(s.store.require<P.BotGrant>('botGrants', grant.id), grant.revision);
          const value = s.update(grant, { pendingLevel: null, ...(valid.includes(grant) ? { requestedLevel: grant.pendingLevel! } : {}) });
          s.store.put('botGrants', value);
          if (!valid.includes(grant)) s.events.emit('grant.upserted', value, { userIds: [owner.userId], botId });
          return value;
        });
        for (const record of records(botId).filter(value => value.state === 'queued')) {
          if (record.machineId !== bot.machineId || !record.capabilityIds.every(id => changed.some(grant => grant.capabilityId === id && rank[grant.requestedLevel] >= rank[record.levels[id]!]))) notice(owner, record, 'Requested access could not be applied. Check this Bot’s access settings and send your request again.', 'failed');
          else s.store.put('accessRequests', s.update(record, { state: 'applying' }));
        }
        if (valid.length || refresh) s.store.setMetadata(syncKey, { state: 'pending', grantIds: valid.map(grant => grant.id), revision: Math.max(0, ...changed.map(grant => grant.revision)), applier: true, published: false });
      });
      if (valid.length || refresh) {
        try {
          if (valid.some(grant => grant.capabilityId.startsWith('connector:'))) await s.integrations.connectorProvisioning!(owner, bot.id);
          else await s.syncBotProfile(owner, bot.id);
        } catch {
          s.store.setMetadata(syncKey, { ...s.store.metadata<object>(syncKey), state: 'outcome_unknown' });
          return;
        }
        s.store.transaction(() => {
          s.store.setMetadata(syncKey, { ...s.store.metadata<object>(syncKey), state: 'acknowledged' });
          s.store.setMetadata(`profileRefresh:${botId}`, null);
        });
        const projected = await effectiveBotGrants(s, owner, bot);
        publishAcknowledgedGrants(owner, botId, projected);
        if (closed || !s.store.get<P.Bot>('bots', botId)) return;
        for (const record of records(botId).filter(value => value.state === 'applying')) {
          if (record.capabilityIds.every(id => projected.some(grant => grant.capabilityId === id && rank[grant.effectiveLevel] >= rank[record.levels[id]!]))) s.store.put('accessRequests', s.update(record, { state: 'applied' }));
          else notice(owner, record, 'Requested access could not be applied. Check this Bot’s access settings and send your request again.', 'failed');
        }
      }
    }
    // A manual edit can supersede a queued request without leaving pending rows.
    for (const record of records(botId).filter(value => value.state === 'queued')) notice(owner, record, 'Requested access was changed in settings. Send your request again when you’re ready.', 'failed');
    for (const record of records(botId).filter(value => value.state === 'applied')) {
      if (closed || hasActive(botId)) break;
      await continueRequest(owner, bot, record);
    }
  }
  function scheduleJob(botId: string): Promise<void> {
    const prior = jobs.get(botId);
    if (prior || closed) return prior ?? Promise.resolve();
    const job = Promise.resolve().then(() => apply(botId)).catch(() => { /* Reconcile retries only safe reads and nonce-bound continuations. */ }).finally(() => jobs.delete(botId));
    jobs.set(botId, job);
    return job;
  }
  return {
    async prepare(principal: Principal, approval: P.Approval): Promise<PreparedAccessChanges | null> {
      const bot = s.auth.bot(principal, approval.botId);
      if (principal.kind !== 'user' || bot.ownerUserId !== principal.userId || approval.gate.targetUserId !== principal.userId) fail('forbidden', 'Only the requesting Bot owner can approve access.');
      if (approval.scope.machineId !== bot.machineId || s.store.metadata(`botLifecycle:${bot.id}`)) fail('policy_denied', 'This Bot’s machine or setup changed. Ask for access again.');
      const run = approval.runId ? s.store.get<P.Run>('runs', approval.runId) : null;
      if (!run || run.botId !== bot.id || run.initiatorUserId !== principal.userId || run.routineRunId !== null || s.store.metadata(`runCron:${run.id}`)) fail('policy_denied', 'Access requests need you present; tell the owner which access to turn on');
      const measured = await machineCapabilities(s, principal, bot.machineId, bot);
      const policy = await s.integrations.effectivePolicy(principal, bot.id);
      const grants = await effectiveBotGrants(s, principal, bot, measured);
      const capability = approval.inputs.capability;
      if (capability !== 'terminal' && capability !== 'files' && capability !== 'browser') fail('invalid_request', 'Invalid access capability.');
      const plan = requestable(s, principal, bot, measured, policy, grants, capability, approval.inputs.level === 'read_only' ? 'view' : 'full');
      if ('code' in plan) { if (plan.code === 'already_available') return null; fail(plan.code, plan.message); }
      const approvedIds = Array.isArray(approval.inputs.capabilityIds) ? approval.inputs.capabilityIds : [];
      const approvedLevels = approval.inputs.levels && typeof approval.inputs.levels === 'object' && !Array.isArray(approval.inputs.levels) ? approval.inputs.levels : {};
      const changes: Record<string, P.AccessLevel> = {};
      for (const [id, level] of Object.entries(plan.levels)) {
        if (!approvedIds.includes(id)) continue;
        const ceiling = approvedLevels[id] ?? approval.inputs.level;
        if (ceiling !== 'read_only' && ceiling !== 'read_interact') fail('invalid_request', 'The approved access level is invalid.');
        changes[id] = rank[level] <= rank[ceiling] ? level : ceiling;
      }
      if (!Object.hasOwn(changes, capability)) return null;
      return { bot, changes, accessRequestId: approval.id };
    },
    queue(prepared: PreparedAccessChanges): void { queueGrantChanges(s, prepared.bot, prepared.changes, prepared.accessRequestId); },
    schedule(botId: string): void { void scheduleJob(botId); },
    async reconcileAll(): Promise<void> {
      if (closed) return;
      markBotProfilesForRefresh(s);
      const botIds = new Set(s.store.list<P.Bot>('bots').map(bot => bot.id));
      for (const record of s.store.list<AccessRequestRecord>('accessRequests', value => ['queued', 'applying', 'applied'].includes(value.state))) botIds.add(record.botId);
      await Promise.all([...botIds].map(scheduleJob));
    },
    close(): void { closed = true; },
  };
}
