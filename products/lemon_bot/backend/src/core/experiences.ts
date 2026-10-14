import { inflateRawSync } from 'node:zlib';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from './services';
import { ApiError, fail } from './errors';
import { z, parse, principal, id, mutation, update, voice, queryObject } from './validation';
import { productBotTools } from './bots';
import { buildPrivateBotMemoryContextKey } from '../runtime/runs';

const level = z.enum(['off', 'read_only', 'read_interact']);
const revision = z.number().int().positive();
const patch = z.object({ job: z.string().max(32768).optional(), instructions: z.string().max(32768).optional(), voice: voice.optional(), language: z.string().min(2).max(64).nullable().optional() }).strict().refine(value => {
  const count = Number(value.job !== undefined || value.instructions !== undefined) + Number(value.voice !== undefined) + Number(value.language !== undefined);
  return count === 1;
});
const preferenceCreate = update.extend({ changes: patch, reason: z.string().trim().min(1).max(2048), sourceEntryId: id.optional() });
const preferenceUndo = update.extend({ botRevision: revision });
const previewRequest = mutation.extend({ text: z.string().max(1048576).optional(), attachmentId: id.optional(), format: z.enum(['facts_text', 'lemon_memory_json', 'chat_export_zip']) }).refine(value => (value.text !== undefined) !== (value.attachmentId !== undefined));
const importRequest = update.extend({ previewId: id, confirmationToken: z.string().min(16).max(512), selectedCandidateIds: z.array(id).min(1).max(200).refine(ids => new Set(ids).size === ids.length) });
const reminderRequest = mutation.extend({ botId: id, conversationId: id, text: z.string().trim().min(1).max(4096), dueAtMs: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER), timezone: z.string().min(1).max(100).refine(value => { try { new Intl.DateTimeFormat('en', { timeZone: value }); return true; } catch { return false; } }) });
const filters = z.object({ cursor: z.string().max(512).optional(), limit: z.coerce.number().int().min(1).max(200).optional(), botId: id.optional(), machineId: id.optional(), fromAtMs: z.coerce.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional(), toAtMs: z.coerce.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional() }).strict();
const pageQuery = filters.pick({ cursor: true, limit: true });
const secrets = /(?:-----BEGIN [A-Z ]*PRIVATE KEY|\b(?:password|passwd|passphrase|secret|api[_ -]?key|private[_ -]?key|token|access[_ -]?token|bearer|credential|authorization|cookie|session[_ -]?token)\b|\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{16,}|AIza[A-Za-z0-9_-]{30,})\b|\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b|https?:\/\/[^\s/]+:[^\s@]+@)/i;
const scopes = ['job', 'instructions', 'voice', 'language'] as const;
const rank: Record<P.AccessLevel, number> = { off: 0, read_only: 1, read_interact: 2 };
const levels: P.AccessLevel[] = ['off', 'read_only', 'read_interact'];
const key = (at: number, valueId: string) => `${String(at).padStart(16, '0')}:${valueId}`;
const readable = (s: BackendServices, user: Principal, collection: string, entity: unknown) => s.auth.canRead(user, collection, entity);
function assertBotOwner(user: Principal, bot: P.Bot): void {
  if (user.kind !== 'user' || bot.ownerUserId !== user.userId) fail('forbidden', 'Only the bot owner can access its experiences and native policy.');
}
function ownedBot(s: BackendServices, requester: Principal, botId: string): P.Bot {
  const bot = s.auth.bot(requester, botId);
  assertBotOwner(requester, bot);
  return bot;
}
function conversation(s: BackendServices, user: Principal, conversationId: string): P.Conversation | null {
  const value = s.store.get<P.Conversation>('conversations', conversationId);
  // Workspace roles never grant access to another owner's conversation, including channels.
  if (!value || value.ownerUserId !== user.userId) return null;
  return readable(s, user, 'conversations', value) ? value : null;
}
function entryVisible(s: BackendServices, user: Principal, entry: P.TranscriptEntry): boolean {
  return !!conversation(s, user, entry.conversationId) && (entry.targetedUserId === null || entry.targetedUserId === user.userId) && readable(s, user, 'entries', entry);
}
function sourceEntry(s: BackendServices, user: Principal, bot: P.Bot, sourceEntryId?: string): P.TranscriptEntry | null {
  if (!sourceEntryId) return null;
  const entry = s.store.require<P.TranscriptEntry>('entries', sourceEntryId);
  const room = conversation(s, user, entry.conversationId);
  if (!room || !room.botIds.includes(bot.id) || !entryVisible(s, user, entry) || entry.kind !== 'message' || entry.role !== 'user' || entry.actor.kind !== 'user' || entry.actor.id !== user.userId || room.kind === 'channel') fail('forbidden', 'Preference changes require an authorized user message in this bot conversation.');
  return entry;
}
function preferenceVisible(s: BackendServices, user: Principal, change: P.PreferenceChange): boolean {
  const bot = s.store.get<P.Bot>('bots', change.botId);
  return change.userId === user.userId && bot?.ownerUserId === user.userId && readable(s, user, 'preferenceChanges', change);
}

/** Keeps manual and natural-language preference changes in the same inspectable ledger. */
export function recordPreferenceChange(s: BackendServices, user: Principal, before: P.Bot, after: P.Bot, changes: P.JobPreferencePatch, reason: string, sourceEntryId: string | null = null): P.PreferenceChange {
  assertBotOwner(user, before); assertBotOwner(user, after);
  finalizePreferenceUndos(s, before.id);
  const previous: P.JobPreferencePatch = {};
  for (const field of scopes) if (Object.hasOwn(changes, field)) Object.assign(previous, { [field]: before[field] });
  const value: P.PreferenceChange = s.resource('preference', { botId: before.id, machineId: before.machineId, userId: user.userId, sourceEntryId, scope: changes.voice !== undefined ? 'voice' : Object.hasOwn(changes, 'language') ? 'language' : 'job', before: previous, after: changes, reason, resultingBotRevision: after.revision, state: 'applied' as const, undoneAtMs: null });
  s.store.put('preferenceChanges', value);
  s.events.emit('preference_change.upserted', value, { userIds: [user.userId] });
  return value;
}

interface PreferenceUndoAttempt { id: string; botId: string; userId: string; botRevision: number; changeRevision: number }
/** Completes only the product ledger after owning profile readback acknowledges an uncertain undo. */
export function finalizePreferenceUndos(s: BackendServices, botId?: string): void {
  for (const attempt of s.store.list<PreferenceUndoAttempt>('preferenceUndoAttempts', value => !botId || value.botId === botId)) {
    const receipt = s.store.metadata<{ state: string; revision: number }>(`preferenceSync:${attempt.botId}`);
    if (receipt?.state !== 'acknowledged' || receipt.revision !== attempt.botRevision) continue;
    s.store.transaction(() => {
      const change = s.store.get<P.PreferenceChange>('preferenceChanges', attempt.id);
      if (change?.state === 'applied' && change.revision === attempt.changeRevision) {
        const undone = s.update(change, { state: 'undone', undoneAtMs: s.now() });
        s.store.put('preferenceChanges', undone);
        s.events.emit('preference_change.upserted', undone, { userIds: [change.userId] });
      }
      s.store.remove('preferenceUndoAttempts', attempt.id);
    });
  }
}

const nodeReply = z.object({ nodes: z.array(z.object({ id: z.string(), status: z.string(), capabilities: z.array(z.string()) }).passthrough()), summary: z.object({ presenceAvailable: z.boolean(), truncated: z.boolean() }).passthrough() }).passthrough();
const measuredCapabilities = z.object({ nodeId: z.string(), os: z.string(), measuredAtMs: z.number().int().nonnegative(), stale: z.boolean(), items: z.array(z.object({ id: z.string().min(1).max(128), name: z.string().max(256), category: z.enum(['files', 'shell', 'browser', 'connector', 'os_app']), supported: z.boolean(), configuredLevel: level, osGrant: z.enum(['granted', 'denied', 'not_required', 'unknown']), tools: z.array(z.string().max(128)).max(512), reason: z.string().max(2048), measuredAtMs: z.number().int().nonnegative(), stale: z.boolean() }).strict()).max(100) }).strict();
/** RPC advertisements prove implementation support, not OS or native-tool authorization. */
export async function machineCapabilities(s: BackendServices, user: Principal, machineId: string, bot?: P.Bot): Promise<P.MachineCapabilities> {
  if (bot && ownedBot(s, user, bot.id).machineId !== machineId) fail('invalid_request', 'Capability measurement must use the bot assigned machine.');
  const machine = bot ? s.store.require<P.Machine>('machines', machineId) : s.auth.machine(user, machineId);
  const cached = s.store.get<P.MachineCapabilities & { id: string }>('machineCapabilities', machineId);
  if (!s.lemon.connected || machine.status !== 'online' || !machine.nodeId) {
    if (!cached) fail('machine_offline', 'No measured capability snapshot is available for this machine.');
    return { machineId, os: cached.os, measuredAtMs: cached.measuredAtMs, stale: true, items: cached.items.map(value => ({ ...value, stale: true })) };
  }
  const listed = nodeReply.safeParse(await s.lemon.call('nodes.list', { nodeId: machine.nodeId }));
  if (!listed.success || !listed.data.summary.presenceAvailable || listed.data.summary.truncated) fail('upstream_unavailable', 'The controller did not return complete measured node presence.');
  const node = listed.data.nodes.find(value => value.id === machine.nodeId);
  if (!node || node.status !== 'online') {
    if (cached) return { machineId, os: cached.os, measuredAtMs: cached.measuredAtMs, stale: true, items: cached.items.map(value => ({ ...value, stale: true })) };
    fail('machine_offline', 'The destination is not verified online.');
  }
  if (!s.lemon.methods.includes('node.capabilities.get')) fail('capability_unavailable', 'The runtime does not advertise measured destination capability inspection.');
  const reply = measuredCapabilities.safeParse(await s.lemon.call('node.capabilities.get', { nodeId: machine.nodeId }));
  if (!reply.success || reply.data.nodeId !== machine.nodeId) fail('upstream_unavailable', 'Destination returned an invalid capability measurement.');
  const { nodeId: _nodeId, ...measurement } = reply.data;
  const result: P.MachineCapabilities = { ...measurement, machineId };
  s.store.put('machineCapabilities', { ...result, id: machineId });
  return result;
}
export async function effectiveBotGrants(s: BackendServices, user: Principal, bot: P.Bot, capabilities?: P.MachineCapabilities): Promise<P.BotGrant[]> {
  assertBotOwner(user, bot);
  const measured = capabilities ?? await machineCapabilities(s, user, bot.machineId, bot);
  return projectEffectiveBotGrants(s, user, bot, measured, await s.integrations.effectivePolicy(user, bot.id), false);
}
/** Owner-authorized desired configuration only; callers must not use it to admit work before cutover ACK. */
export async function desiredBotGrants(s: BackendServices, user: Principal, bot: P.Bot, capabilities?: P.MachineCapabilities): Promise<P.BotGrant[]> {
  assertBotOwner(user, bot);
  const measured = capabilities ?? await machineCapabilities(s, user, bot.machineId, bot);
  return projectEffectiveBotGrants(s, user, bot, measured, await s.integrations.effectivePolicy(user, bot.id), true);
}
function projectEffectiveBotGrants(s: BackendServices, user: Principal, bot: P.Bot, measured: P.MachineCapabilities, policy: P.EffectivePolicy, desired: boolean): P.BotGrant[] {
  const synchronization = s.store.metadata<{ state: string }>(`botPolicySync:${bot.id}`);
  const unresolved = !desired && synchronization !== null && synchronization.state !== 'acknowledged';
  const persisted = s.store.list<P.BotGrant>('botGrants', value => {
    if (value.botId !== bot.id || value.machineId !== bot.machineId) return false;
    if (!value.capabilityId.startsWith('connector:')) return true;
    const connector = s.store.get<P.Connector>('connectors', value.capabilityId.slice('connector:'.length));
    return !!connector && connector.ownerUserId === user.userId && readable(s, user, 'connectors', connector);
  });
  const inventory = [...measured.items];
  for (const connector of s.store.list<P.Connector>('connectors', value => value.botId === bot.id && value.ownerUserId === user.userId && readable(s, user, 'connectors', value))) {
    const encrypted = s.store.metadata<string>(`connector:${connector.id}`);
    if (!encrypted) continue;
    const details = z.object({ machineId: z.string(), configuredLevel: level, discoveredAtMs: z.number().nullable() }).passthrough().safeParse(s.decrypt(encrypted));
    if (!details.success || details.data.machineId !== bot.machineId) continue;
    inventory.push({ id: `connector:${connector.id}`, name: connector.name, category: 'connector', supported: connector.state === 'connected' && details.data.discoveredAtMs !== null, configuredLevel: details.data.configuredLevel, osGrant: 'not_required', tools: connector.tools.map(tool => tool.name), reason: 'Destination connector discovery and secret resolution are acknowledged; no OS app permission is implied.', measuredAtMs: details.data.discoveredAtMs ?? connector.updatedAtMs, stale: !s.lemon.connected || s.store.require<P.Machine>('machines', bot.machineId).status !== 'online' });
  }
  return inventory.map(cap => {
    let stored = persisted.find(value => value.capabilityId === cap.id);
    if (!stored) {
      stored = { ...s.resource('grant', { botId: bot.id, machineId: bot.machineId, capabilityId: cap.id, requestedLevel: 'off' as const, effectiveLevel: 'off' as const, reasons: [] as string[] }), id: `grant_${s.mutations.digest({ botId: bot.id, machineId: bot.machineId, capabilityId: cap.id }).slice(0, 48)}` };
      s.store.put('botGrants', stored);
    }
    const requestedLevel = stored?.requestedLevel ?? 'off';
    const machineLevel = cap.supported && !cap.stale && (cap.osGrant === 'granted' || cap.osGrant === 'not_required') ? cap.configuredLevel : 'off';
    const policyLevel: P.AccessLevel = unresolved || !policy.productAccess || policy.localExecutionCeiling === 'deny' ? 'off' : 'read_interact';
    return { ...stored, botId: bot.id, machineId: bot.machineId, capabilityId: cap.id, requestedLevel, effectiveLevel: levels[Math.min(rank[requestedLevel], rank[machineLevel], rank[policyLevel])]!, reasons: [cap.reason, 'Native grants restrict named tools, not host privileges; shell and browser evaluation can access other host resources.', ...(unresolved ? ['Tool-policy cutover has not been acknowledged.'] : []), ...policy.explanations] };
  }).concat(persisted.filter(value => !inventory.some(cap => cap.id === value.capabilityId)).map(value => ({ ...value, effectiveLevel: 'off' as const, reasons: ['No measured machine capability ceiling is available.'] })));
}

const nativeReadTools: Record<string, true> = { read: true, grep: true, find: true, ls: true, browser_tabs: true, browser_snapshot: true, browser_get_content: true, browser_events: true, browser_screenshot: true, browser_analyze: true };
const nativeToolFamilies: Record<string, string[]> = {
  files: ['read', 'write', 'edit', 'patch', 'ast_grep', 'grep', 'find', 'ls', 'checkpoint'],
  shell: ['bash', 'bash_output', 'kill_process'],
  browser: ['browser_tabs', 'browser_tab_open', 'browser_tab_activate', 'browser_tab_close', 'browser_navigate', 'browser_snapshot', 'browser_get_content', 'browser_click', 'browser_type', 'browser_hover', 'browser_select_option', 'browser_upload_file', 'browser_download', 'browser_press', 'browser_scroll', 'browser_back', 'browser_wait_for_selector', 'browser_evaluate', 'browser_events', 'browser_get_cookies', 'browser_set_cookies', 'browser_clear_state', 'browser_screenshot', 'browser_analyze'],
};
const nativeBaselineTools = ['read_skill', 'webfetch', 'websearch', 'task', 'agent_message', 'wait', 'parent_question'];
async function productExecutionNames(s: BackendServices): Promise<string[]> {
  if (!s.lemon.connected || !s.lemon.methods.includes('mcp.execution_names')) fail('capability_unavailable', 'The controller does not advertise pure MCP execution-name projection.');
  const server = { name: 'lemon-bot', url: new URL('/mcp', s.config.publicUrl).href };
  const raw = await s.lemon.call('mcp.execution_names', { server, toolNames: [...productBotTools] }, { mutation: false });
  const result = z.object({ server: z.object({ name: z.literal('lemon-bot') }).strict(), tools: z.array(z.object({ name: z.string(), executionName: z.string().min(1).max(64).regex(/^mcp_[a-z0-9_]+$/) }).strict()).length(productBotTools.length), count: z.literal(productBotTools.length) }).strict().safeParse(raw);
  if (!result.success || new Set(result.data.tools.map(tool => tool.name)).size !== productBotTools.length || new Set(result.data.tools.map(tool => tool.executionName)).size !== productBotTools.length || result.data.tools.some(tool => !productBotTools.some(name => name === tool.name))) fail('upstream_unavailable', 'The controller returned an incomplete or ambiguous product execution-name projection.');
  return result.data.tools.map(tool => tool.executionName);
}
const productExcludedNativeTools: Record<string, true> = {
  agent: true, remember: true, recall: true,
  cron: true, goal: true, kanban: true, todo: true, peer: true,
  skill_manage: true, tool_auth: true, extensions_status: true,
};
/** Desired and per-run native policy use the actual Bot owner; runtime admission fences pending cutovers. */
export async function nativeBotToolPolicy(s: BackendServices, user: Principal, bot: P.Bot, capabilities?: P.MachineCapabilities): Promise<P.JSONObject> {
  assertBotOwner(user, bot);
  const measured = capabilities ?? await machineCapabilities(s, user, bot.machineId, bot);
  const policy = await s.integrations.effectivePolicy(user, bot.id);
  const grants = projectEffectiveBotGrants(s, user, bot, measured, policy, true);
  const allowed = new Set([...nativeBaselineTools, ...await productExecutionNames(s)]), denied = new Set<string>(), approvalTools = new Set<string>();
  // Product resources require their authenticated MCP lifecycle rather than daemon-wide native managers.
  // Recall is temporarily excluded until the complete verified audience conduit is proven.
  for (const tool of Object.keys(productExcludedNativeTools)) denied.add(tool);
  for (const [category, defaults] of Object.entries(nativeToolFamilies)) {
    const capability = measured.items.find(value => value.category === category);
    const grant = capability && grants.find(value => value.capabilityId === capability.id);
    const effective = grant?.effectiveLevel ?? 'off';
    for (const tool of defaults) {
      if (!capability?.tools.includes(tool) || effective === 'off' || effective === 'read_only' && !nativeReadTools[tool]) denied.add(tool);
      else {
        allowed.add(tool);
        if (policy.localExecutionCeiling === 'ask' || policy.rules.some(rule => (rule.category === category || rule.category === 'permissions') && rule.mode !== 'allow')) approvalTools.add(tool);
      }
    }
  }
  // Diagnostics can execute project-local compilers (including mix compile) and write workspace artifacts.
  // Neither a read-only file grant nor an unrestricted baseline may authorize this local execution.
  const diagnosticFiles = measured.items.find(value => value.category === 'files');
  const diagnosticShell = measured.items.find(value => value.category === 'shell');
  if (!diagnosticShell?.tools.includes('lsp_diagnostics') || grants.find(value => value.capabilityId === diagnosticFiles?.id)?.effectiveLevel !== 'read_interact' || grants.find(value => value.capabilityId === diagnosticShell.id)?.effectiveLevel !== 'read_interact') denied.add('lsp_diagnostics');
  else {
    allowed.add('lsp_diagnostics');
    if (policy.localExecutionCeiling === 'ask' || policy.rules.some(rule => ['files', 'shell', 'permissions'].includes(rule.category) && rule.mode !== 'allow')) approvalTools.add('lsp_diagnostics');
  }
  for (const connector of s.store.list<P.Connector>('connectors', value => value.botId === bot.id && value.ownerUserId === user.userId && readable(s, user, 'connectors', value))) {
    const encrypted = s.store.metadata<string>(`connector:${connector.id}`);
    if (!encrypted) continue;
    const details = z.object({ readOnlyTools: z.array(z.string()), executionNames: z.record(z.string(), z.string().min(1).max(64)) }).passthrough().safeParse(s.decrypt(encrypted));
    const grant = grants.find(value => value.capabilityId === `connector:${connector.id}`);
    if (!details.success) {
      if (connector.state === 'connected' && grant && grant.effectiveLevel !== 'off' && connector.tools.some(tool => tool.enabled)) fail('capability_unavailable', 'Connector discovery did not supply actual execution-tool names.');
      continue;
    }
    for (const tool of connector.tools) {
      const executionName = details.data.executionNames[tool.name];
      if (!executionName) {
        if (tool.enabled && grant?.effectiveLevel !== 'off') fail('capability_unavailable', 'An enabled connector tool has no measured execution-name mapping.');
        continue;
      }
      const readOnly = details.data.readOnlyTools.includes(tool.name);
      if (!tool.enabled || !grant || grant.effectiveLevel === 'off' || grant.effectiveLevel === 'read_only' && !readOnly) denied.add(executionName);
      else {
        allowed.add(executionName);
        if (!readOnly || policy.localExecutionCeiling === 'ask' || policy.rules.some(rule => ['connector', 'permissions', 'external_message', 'publish', 'purchase'].includes(rule.category) && rule.mode !== 'allow')) approvalTools.add(executionName);
      }
    }
  }
  for (const tool of denied) { allowed.delete(tool); approvalTools.delete(tool); }
  if (allowed.size > 16384 || denied.size > 16384 || approvalTools.size > 16384) fail('capability_unavailable', 'The native policy schema cannot represent this complete tool permission set.');
  return { profile: 'custom', allow: [...allowed].sort(), deny: [...denied].sort(), blocked_tools: Object.keys(productExcludedNativeTools), require_approval: [...approvalTools].sort() };
}

export function botPresence(s: BackendServices, user: Principal, bot: P.Bot): P.BotPresence {
  assertBotOwner(user, bot);
  const machine = s.store.require<P.Machine>('machines', bot.machineId);
  const online = s.lemon.connected && machine.status === 'online';
  const allActive = s.store.list<P.Run>('runs', run => run.botId === bot.id && ['running', 'awaiting_input', 'queued', 'reserved', 'outcome_unknown'].includes(run.status));
  const active = allActive.filter(run => !!conversation(s, user, run.conversationId)).sort((a, b) => b.updatedAtMs - a.updatedAtMs);
  const run = active.find(value => value.status === 'awaiting_input') ?? active[0];
  const entries = run ? s.store.list<P.TranscriptEntry>('entries', entry => entry.runId === run.id && entryVisible(s, user, entry)) : [];
  const artifact = entries.find(entry => {
    if (entry.kind !== 'card' || entry.card.type !== 'attachment') return false;
    const attachment = s.store.get<P.Attachment>('attachments', entry.card.attachmentId);
    return attachment?.state === 'ready' && attachment.provenance.botId === bot.id && attachment.provenance.runId === run?.id && attachment.provenance.machineId === bot.machineId && readable(s, user, 'attachments', attachment);
  });
  const gate = ['approvals', 'questions', 'humanSteps'].some(collection => s.store.list<P.Approval | P.Question | P.HumanStep>(collection, value => value.botId === bot.id && value.gate.state === 'pending' && value.gate.targetUserId === user.userId && value.gate.expiresAtMs > s.now() && !!conversation(s, user, value.conversationId)).length > 0) || s.store.list<P.SecretRequest>('secretRequests', value => value.botId === bot.id && value.gate.state === 'pending' && value.gate.targetUserId === user.userId && value.gate.expiresAtMs > s.now() && (() => { const entry = s.store.get<P.TranscriptEntry>('entries', value.entryId); return !!entry && entryVisible(s, user, entry); })()).length > 0;
  const status: P.BotPresence['status'] = !online ? 'offline' : gate || run?.status === 'awaiting_input' ? 'needs_input' : artifact && run?.status === 'running' ? 'making' : allActive.length ? 'working' : 'idle';
  const room = run ? conversation(s, user, run.conversationId) : null;
  const pendingProfile = ['preferenceSync', 'botPolicySync'].some(prefix => { const receipt = s.store.metadata<{ state: string }>(`${prefix}:${bot.id}`); return receipt !== null && receipt.state !== 'acknowledged'; }) || !!s.store.metadata(`botLifecycle:${bot.id}`);
  const summary = status === 'offline' ? 'Assigned machine is unavailable.' : status === 'needs_input' ? 'Waiting for your input.' : status === 'making' ? 'A verified output is being produced.' : status === 'working' ? !run ? 'Work is active in a private scope.' : run.status === 'queued' || run.status === 'reserved' ? 'Work is queued.' : run.status === 'outcome_unknown' ? 'Execution outcome is being reconciled.' : 'Run in progress.' : 'No active work.';
  return {
    botId: bot.id, status, machineId: machine.id, machineLabel: machine.name, machineStatus: machine.status,
    currentRunId: run?.id ?? null, taskConversationId: room?.kind === 'task' ? room.id : null,
    summary: pendingProfile ? `${summary} Profile synchronization is unconfirmed.` : summary,
    evidenceEntryId: status === 'making' ? artifact?.id ?? null : null, measuredAtMs: s.now(),
    stale: !online || pendingProfile || allActive.some(value => value.status === 'outcome_unknown'),
  };
}

function activityValues(s: BackendServices, user: Principal): P.ActivityItem[] {
  const results: P.ActivityItem[] = [];
  const add = (resource: P.Resource, botId: string, roomId: string | null, fields: Pick<P.ActivityItem, 'kind' | 'status' | 'title' | 'summary' | 'runId' | 'entryId' | 'approvalId'>, at = resource.updatedAtMs, machineId?: string) => {
    const bot = s.store.get<P.Bot>('bots', botId);
    if (!bot || bot.ownerUserId !== user.userId || !readable(s, user, 'bots', bot)) return;
    const room = roomId ? conversation(s, user, roomId) : null;
    if (roomId && !room) return;
    const machine = s.store.get<P.Machine>('machines', machineId ?? bot.machineId);
    if (!machine) return;
    results.push({ id: `activity_${s.mutations.digest({ kind: fields.kind, resourceId: resource.id, botId }).slice(0, 48)}`, revision: resource.revision, createdAtMs: resource.createdAtMs, updatedAtMs: resource.updatedAtMs, botId, machineId: machine.id, machineLabel: machine.name, conversationId: room?.id ?? null, taskConversationId: room?.kind === 'task' ? room.id : null, ...fields, occurredAtMs: at });
  };
  for (const run of s.store.list<P.Run>('runs')) add(run, run.botId, run.conversationId, { kind: 'run', status: run.status === 'running' ? 'working' : run.status === 'awaiting_input' || run.status === 'queued' || run.status === 'reserved' ? 'pending' : run.status, title: 'Bot run', summary: `Execution ${run.status.replaceAll('_', ' ')}.`, runId: run.id, entryId: null, approvalId: null });
  for (const entry of s.store.list<P.TranscriptEntry>('entries')) {
    if (entry.kind !== 'tool_call' || !entry.runId || !entryVisible(s, user, entry)) continue;
    const run = s.store.get<P.Run>('runs', entry.runId);
    if (run) add(entry, run.botId, entry.conversationId, { kind: 'tool', status: entry.status === 'started' ? 'working' : entry.status === 'completed' ? 'succeeded' : 'failed', title: 'Tool execution', summary: `Tool ${entry.status}.`, runId: run.id, entryId: entry.id, approvalId: null }, entry.timestampMs);
  }
  for (const approval of s.store.list<P.Approval>('approvals')) {
    const state = approval.gate.state;
    const status: P.ActivityItem['status'] = state === 'pending' || state === 'submitted' ? 'pending' : state === 'approved' || state === 'completed' ? 'succeeded' : state === 'outcome_unknown' || state === 'cancelled' || state === 'failed' ? state : 'denied';
    add(approval, approval.botId, approval.conversationId, { kind: 'approval', status, title: 'Action review', summary: `Review ${state}.`, runId: approval.runId, entryId: approval.entryId, approvalId: approval.id }, approval.updatedAtMs, approval.scope.machineId);
  }
  for (const change of s.store.list<P.PreferenceChange>('preferenceChanges')) if (change.userId === user.userId) {
    const source = change.sourceEntryId ? s.store.get<P.TranscriptEntry>('entries', change.sourceEntryId) : null;
    const sync = s.store.metadata<{ state: string; revision: number }>(`preferenceSync:${change.botId}`);
    const status: P.ActivityItem['status'] = sync?.revision === change.resultingBotRevision && sync.state !== 'acknowledged' ? sync.state === 'pending' ? 'pending' : 'outcome_unknown' : 'succeeded';
    add(change, change.botId, source && entryVisible(s, user, source) ? source.conversationId : null, { kind: 'preference', status, title: 'Preference change', summary: status === 'succeeded' ? `${change.scope} preference ${change.state}.` : 'Destination preference synchronization is unconfirmed.', runId: null, entryId: source && entryVisible(s, user, source) ? source.id : null, approvalId: null }, change.updatedAtMs, change.machineId);
  }
  for (const memory of s.store.list<P.Memory & { runtimeMemoryId?: string | null; memoryContextKey?: string }>('memories')) {
    const bot = s.store.get<P.Bot>('bots', memory.botId);
    if (!bot || bot.ownerUserId !== user.userId || !memory.runtimeMemoryId || memory.memoryContextKey !== buildPrivateBotMemoryContextKey(s, user, bot) || !readable(s, user, 'memories', memory)) continue;
    const operation = s.store.metadata<{ state: 'pending' | 'outcome_unknown' }>(`resourceOperation:${memory.id}`);
    add(memory, memory.botId, null, { kind: 'memory', status: operation?.state ?? 'succeeded', title: 'Bot memory', summary: operation ? 'Destination memory mutation is unconfirmed.' : `${memory.kind} saved to the owned Bot profile.`, runId: null, entryId: null, approvalId: null });
  }
  for (const attachment of s.store.list<P.Attachment>('attachments')) {
    const p = attachment.provenance;
    if (attachment.state !== 'ready' || !p.botId || !p.machineId || !readable(s, user, 'attachments', attachment) || (!attachment.conversationId && attachment.ownerUserId !== user.userId)) continue;
    const sourceRun = p.runId ? s.store.get<P.Run>('runs', p.runId) : null;
    const source = p.sourceEntryId ? s.store.get<P.TranscriptEntry>('entries', p.sourceEntryId) : null;
    add(attachment, p.botId, attachment.conversationId, { kind: 'artifact', status: 'succeeded', title: 'Output available', summary: 'Verified attachment from the assigned machine.', runId: sourceRun && conversation(s, user, sourceRun.conversationId) ? sourceRun.id : null, entryId: source && entryVisible(s, user, source) ? source.id : null, approvalId: null }, p.generatedAtMs ?? attachment.createdAtMs, p.machineId);
  }
  for (const invite of s.store.list<P.MachineInvite>('machineInvites', value => value.status === 'joined' && value.enrollment === 'online')) {
    for (const bot of s.store.list<P.Bot>('bots', value => value.ownerUserId === user.userId && value.machineId === invite.machineId && readable(s, user, 'bots', value))) add(invite, bot.id, null, { kind: 'enrollment', status: 'succeeded', title: 'Machine attached', summary: 'Destination enrollment was verified online.', runId: null, entryId: null, approvalId: null }, invite.updatedAtMs, invite.machineId);
  }
  return results;
}
function queryRange(context: RequestContext, upcoming: boolean) {
  const value = parse(filters, queryObject(context.query));
  if (context.params.id && value.botId && value.botId !== context.params.id) fail('invalid_request', 'Query cannot override the path bot.');
  const from = value.fromAtMs ?? (upcoming ? context.services.now() : 0);
  const to = value.toAtMs ?? (upcoming ? from + 30 * 86400000 : Number.MAX_SAFE_INTEGER);
  if (to < from || (upcoming && to - from > 366 * 86400000)) fail('invalid_request', 'Time range is invalid.');
  return { ...value, botId: context.params.id ?? value.botId, from, to };
}
function activityPage(context: RequestContext): P.Page<P.ActivityItem> {
  const s = context.services, user = principal(context.user), query = queryRange(context, false);
  if (query.botId) ownedBot(s, user, query.botId);
  if (query.machineId && !s.store.list<P.Bot>('bots', value => value.ownerUserId === user.userId && value.machineId === query.machineId && readable(s, user, 'bots', value)).length) s.auth.machine(user, query.machineId);
  return s.page(context, activityValues(s, user).filter(value => (!query.botId || value.botId === query.botId) && (!query.machineId || value.machineId === query.machineId) && value.occurredAtMs >= query.from && value.occurredAtMs <= query.to), { key: value => key(value.occurredAtMs, value.id), binding: { botId: query.botId ?? null } });
}
function upcomingPage(context: RequestContext): P.Page<P.UpcomingItem> {
  const s = context.services, user = principal(context.user), query = queryRange(context, true), items: P.UpcomingItem[] = [];
  if (query.botId) ownedBot(s, user, query.botId);
  if (query.machineId && !s.store.list<P.Bot>('bots', value => value.ownerUserId === user.userId && value.machineId === query.machineId && readable(s, user, 'bots', value)).length) s.auth.machine(user, query.machineId);
  const add = (valueId: string, botId: string, title: string, dueAtMs: number, timezone: string, routineId: string | null, reminderId: string | null, lastRunId: string | null) => {
    const bot = s.store.get<P.Bot>('bots', botId), machine = bot && s.store.get<P.Machine>('machines', bot.machineId);
    if (!bot || bot.ownerUserId !== user.userId || !machine || !readable(s, user, 'bots', bot) || (query.botId && query.botId !== botId) || (query.machineId && query.machineId !== machine.id) || dueAtMs < query.from || dueAtMs > query.to) return;
    const last = lastRunId ? s.store.get<P.RoutineRun>('routineRuns', lastRunId) : null;
    items.push({ id: valueId, kind: routineId ? 'routine' : 'reminder', botId, machineId: machine.id, machineLabel: machine.name, machineStatus: machine.status, title, dueAtMs, timezone, routineId, reminderId, lastRunId, lastRunStatus: last?.status ?? null, blockedReason: routineId && (!s.lemon.connected || machine.status !== 'online') ? 'Assigned machine is unavailable.' : null });
  };
  for (const routine of s.store.list<P.Routine>('routines')) if (routine.enabled && routine.ownerUserId === user.userId && routine.trigger.kind === 'schedule' && routine.nextRunAtMs !== null && readable(s, user, 'routines', routine)) add(`routine:${routine.id}`, routine.botId, routine.name, routine.nextRunAtMs, routine.trigger.timezone, routine.id, null, routine.lastRunId);
  for (const reminder of s.store.list<P.Reminder>('reminders')) if (reminder.userId === user.userId && reminder.state === 'scheduled' && conversation(s, user, reminder.conversationId)) add(`reminder:${reminder.id}`, reminder.botId, reminder.text, reminder.dueAtMs, reminder.timezone, null, reminder.id, null);
  return s.page(context, items, { ascending: true, key: value => key(value.dueAtMs, value.id), binding: { botId: query.botId ?? null } });
}

interface ImportBinding { botRevision: number; machineId: string; attachmentId: string | null; attachmentRevision: number | null; sourceSha256: string; sourceText: string | null; format: P.MemoryImportPreviewRequest['format']; consumed: boolean }
interface ImportAttempt { id: string; previewId: string; candidateId: string; nonce: string; state: 'pending' | 'completed' | 'outcome_unknown'; memoryId: string | null }
const memoryKind = z.enum(['fact', 'preference', 'instruction', 'summary']);
const memoryRow = z.object({ id, revision, createdAtMs: z.number().int().nonnegative(), updatedAtMs: z.number().int().nonnegative(), botId: id, text: z.string().min(1).max(4096), kind: memoryKind, sourceEntryId: id.nullable() }).strict();
const memoryExport = z.object({ botId: id, items: z.array(z.unknown()).max(10000), exportedAtMs: z.number().int().nonnegative() }).strict();
const decoder = new TextDecoder('utf-8', { fatal: true });
function decode(bytes: Uint8Array): string { try { return decoder.decode(bytes); } catch { return fail('unsupported_media', 'Import requires valid UTF-8 documents.'); } }
function json(text: string): unknown { try { return JSON.parse(text); } catch { return fail('unsupported_media', 'Import JSON is invalid.'); } }
/** Bounded central-directory ZIP reader; never extracts paths or trusts local headers. */
function zipDocuments(bytes: Uint8Array): { filename: string; text: string }[] {
  if (bytes.length > 25 * 1024 * 1024) fail('too_large', 'ZIP exceeds the compressed limit.');
  const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = -1;
  for (let at = bytes.length - 22; at >= Math.max(0, bytes.length - 65557); at--) if (data.getUint32(at, true) === 0x06054b50 && at + 22 + data.getUint16(at + 20, true) === bytes.length) { end = at; break; }
  if (end < 0 || data.getUint16(end + 4, true) !== 0 || data.getUint16(end + 6, true) !== 0) fail('unsupported_media', 'ZIP must be a single unencrypted archive.');
  const count = data.getUint16(end + 10, true), start = data.getUint32(end + 16, true), directorySize = data.getUint32(end + 12, true);
  if (count > 200 || count !== data.getUint16(end + 8, true) || start + directorySize !== end) fail('too_large', 'ZIP directory exceeds supported bounds.');
  let at = start, expanded = 0;
  const documents: { filename: string; text: string }[] = [], names = new Set<string>();
  for (let index = 0; index < count; index++) {
    if (at + 46 > end || data.getUint32(at, true) !== 0x02014b50) fail('unsupported_media', 'ZIP directory is invalid.');
    const flags = data.getUint16(at + 8, true), method = data.getUint16(at + 10, true), crc = data.getUint32(at + 16, true), compressed = data.getUint32(at + 20, true), size = data.getUint32(at + 24, true), nameLength = data.getUint16(at + 28, true), extra = data.getUint16(at + 30, true), comment = data.getUint16(at + 32, true), mode = data.getUint32(at + 38, true) >>> 16, offset = data.getUint32(at + 42, true);
    if (at + 46 + nameLength + extra + comment > end) fail('unsupported_media', 'ZIP directory is truncated.');
    const filename = decode(bytes.subarray(at + 46, at + 46 + nameLength));
    if ((flags & 1) || ![0, 8].includes(method) || (mode & 0xf000) === 0xa000 || filename.includes('\\') || filename.includes('\0') || filename.startsWith('/') || /^[A-Za-z]:/.test(filename) || filename.split('/').some(part => part === '..' || part === '.') || names.has(filename)) fail('unsupported_media', 'ZIP has unsafe or unsupported entries.');
    names.add(filename); expanded += size;
    if (expanded > 100 * 1024 * 1024 || size > 100 * 1024 * 1024 || (size > 1048576 && size > Math.max(1, compressed) * 1000)) fail('too_large', 'ZIP expansion exceeds supported bounds.');
    if (offset + 30 > start || data.getUint32(offset, true) !== 0x04034b50 || data.getUint16(offset + 6, true) !== flags || data.getUint16(offset + 8, true) !== method) fail('unsupported_media', 'ZIP local header is invalid.');
    const localNameLength = data.getUint16(offset + 26, true), localExtra = data.getUint16(offset + 28, true), payload = offset + 30 + localNameLength + localExtra;
    if (payload + compressed > start || decode(bytes.subarray(offset + 30, offset + 30 + localNameLength)) !== filename) fail('unsupported_media', 'ZIP entry bounds are invalid.');
    const source = bytes.subarray(payload, payload + compressed);
    let output: Uint8Array;
    try { output = method === 0 ? source : inflateRawSync(source, { maxOutputLength: Math.max(1, size) }); } catch { return fail('unsupported_media', 'ZIP entry cannot be decoded safely.'); }
    if (output.length !== size || crc32(output) !== crc) fail('unsupported_media', 'ZIP checksum or size does not match.');
    if (!filename.endsWith('/')) documents.push({ filename, text: ['facts.txt', 'facts.md', 'memory.json', 'conversations.json'].includes(filename) ? decode(output) : '' });
    at += 46 + nameLength + extra + comment;
  }
  if (at !== end) fail('unsupported_media', 'ZIP directory contains trailing entries.');
  return documents;
}
const zipCrcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let crc = index;
  for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  return crc >>> 0;
});
function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = (crc >>> 8) ^ zipCrcTable[(crc ^ byte) & 255]!;
  return (crc ^ 0xffffffff) >>> 0;
}
export function reviewedCandidates(s: BackendServices, bytes: Uint8Array, format: P.MemoryImportPreviewRequest['format'], existing: string[]): Pick<P.MemoryImportPreview, 'candidates' | 'exclusions'> {
  const candidates: P.MemoryImportCandidate[] = [], exclusions: P.MemoryImportPreview['exclusions'] = [], seen = new Set(existing.map(value => value.trim().toLocaleLowerCase()));
  const exclude = (locator: string, reason: P.MemoryImportPreview['exclusions'][number]['reason']) => {
    if (exclusions.length >= 10000) fail('too_large', 'The source contains too many excluded statements for one exact review; split the source document.');
    exclusions.push({ locator: locator.slice(0, 200), reason, summary: reason === 'credential' ? 'Credential-like content excluded.' : reason === 'private_profile' ? 'Private-profile source excluded.' : reason === 'duplicate' ? 'Duplicate fact excluded.' : reason === 'not_durable' ? 'No explicit durable statement.' : 'Unsupported source entry excluded.' });
  };
  const candidate = (text: string, kind: P.Memory['kind'], filename: string | null, locator: string) => {
    text = text.trim();
    if (secrets.test(text)) return exclude(locator, 'credential');
    if (text.length < 4 || Buffer.byteLength(text, 'utf8') > 4096 || text.includes('\0')) return exclude(locator, 'not_durable');
    const normalized = text.toLocaleLowerCase();
    if (seen.has(normalized)) return exclude(locator, 'duplicate');
    if (candidates.length >= 200) return exclude(locator, 'unsupported');
    seen.add(normalized);
    candidates.push({ id: s.id('candidate'), text, kind, source: { filename, locator, excerpt: text.slice(0, 256) }, selectedByDefault: false });
  };
  const facts = (text: string, filename: string | null) => text.split(/\r?\n\s*\r?\n/).forEach((paragraph, index) => {
    const lines = paragraph.split(/\r?\n/).filter(line => line.trim());
    if (lines.length && lines.every(line => /^\s*(?:[-*]|\d+\.)\s+/.test(line))) lines.forEach((line, item) => candidate(line.replace(/^\s*(?:[-*]|\d+\.)\s+/, ''), 'fact', filename, `paragraph:${index + 1}/item:${item + 1}`));
    else candidate(paragraph, 'fact', filename, `paragraph:${index + 1}`);
  });
  const exported = (text: string, filename: string | null) => {
    const value = memoryExport.safeParse(json(text));
    if (!value.success) fail('unsupported_media', 'JSON must match a Lemon memory export.');
    value.data.items.forEach((item, index) => {
      const row = memoryRow.safeParse(item), locator = `items:${index}`;
      if (!row.success) return exclude(locator, secrets.test(JSON.stringify(item)) ? 'credential' : 'unsupported');
      candidate(row.data.text, row.data.kind, filename, locator);
    });
  };
  const chats = (text: string, filename: string) => {
    const exports = z.array(z.object({ mapping: z.record(z.string(), z.object({ message: z.object({ author: z.object({ role: z.string() }).passthrough(), content: z.object({ parts: z.array(z.unknown()).optional() }).passthrough() }).passthrough().nullable().optional() }).passthrough()) }).passthrough()).safeParse(json(text));
    if (!exports.success) fail('unsupported_media', 'Chat export structure is unsupported.');
    exports.data.forEach((chat, ci) => Object.values(chat.mapping).forEach((node, mi) => {
      const locator = `conversation:${ci}/message:${mi}`, message = node.message;
      if (!message || message.author.role !== 'user') return exclude(locator, 'not_durable');
      const text = (message.content.parts ?? []).filter((value): value is string => typeof value === 'string').join('\n').trim();
      if (secrets.test(text)) return exclude(locator, 'credential');
      const declaration = /^(?:please\s+)?(?:remember(?:\s+that)?|my preference is|i prefer)\s*[:,-]?\s+([\s\S]+)$/i.exec(text);
      if (!declaration) return exclude(locator, 'not_durable');
      candidate(declaration[1]!, /^i prefer|^my preference/i.test(text) ? 'preference' : 'fact', filename, locator);
    }));
  };
  if (format === 'facts_text') facts(decode(bytes), null);
  else if (format === 'lemon_memory_json') exported(decode(bytes), null);
  else for (const [index, doc] of zipDocuments(bytes).entries()) {
    if (doc.filename === 'facts.txt' || doc.filename === 'facts.md') facts(doc.text, doc.filename);
    else if (doc.filename === 'memory.json') exported(doc.text, doc.filename);
    else if (doc.filename === 'conversations.json') chats(doc.text, doc.filename);
    else exclude(`archive-entry:${index}`, 'unsupported');
  }
  return { candidates, exclusions };
}

async function previewMemory(context: RequestContext): Promise<P.MemoryImportPreview> {
  const s = context.services, user = principal(context.user), body = parse(previewRequest, context.body), bot = ownedBot(s, user, context.params.id!);
  let attachment: P.Attachment | null = null;
  if (body.attachmentId) { attachment = s.auth.attachment(user, body.attachmentId); if (attachment.ownerUserId !== user.userId || attachment.state !== 'ready') fail('forbidden', 'Import requires your own ready attachment.'); }
  const bytes = attachment ? await s.attachments.bytes(attachment.id) : new TextEncoder().encode(body.text!);
  if (body.format !== 'chat_export_zip' && bytes.length > 1048576) fail('too_large', 'Facts documents are limited to one MiB.');
  const snapshot = await s.invoke<P.MemoryExport>(user, 'GET', `/v1/bots/${encodeURIComponent(bot.id)}/memory/export`);
  const existing = snapshot.items.map(value => value.text);
  const reviewed = reviewedCandidates(s, bytes, body.format, existing), digest = new Bun.CryptoHasher('sha256').update(bytes).digest('hex');
  const base = s.resource('import', { botId: bot.id, machineId: bot.machineId, userId: user.userId, sourceSha256: digest, ...reviewed });
  const confirmation = s.mutations.preview(user, base, 'memory_import', bot.name, ['Only explicitly selected reviewed candidates will be saved.'], [{ resourceType: 'bot', id: bot.id, machineId: bot.machineId, operation: 'retain', explanation: 'History and unselected facts remain unchanged.' }], { botRevision: bot.revision, machineId: bot.machineId, sourceSha256: digest, candidateIds: reviewed.candidates.map(value => value.id) }, 600000);
  const result: P.MemoryImportPreview = { ...base, confirmationToken: confirmation.confirmationToken, expiresAtMs: confirmation.expiresAtMs };
  s.store.put('memoryImportPreviews', result);
  context.nonceResourceIds.push(result.id);
  s.store.setMetadata(`memoryImport:${result.id}`, { botRevision: bot.revision, machineId: bot.machineId, attachmentId: attachment?.id ?? null, attachmentRevision: attachment?.revision ?? null, sourceSha256: digest, sourceText: attachment ? null : s.encrypt(body.text!), format: body.format, consumed: false } satisfies ImportBinding);
  return result;
}
async function confirmMemory(context: RequestContext): Promise<P.MemoryImportResult> {
  const s = context.services, user = principal(context.user), body = parse(importRequest, context.body), preview = s.store.require<P.MemoryImportPreview>('memoryImportPreviews', body.previewId);
  if (preview.userId !== user.userId || preview.botId !== context.params.id) fail('forbidden', 'Import preview belongs to another owner or Bot.');
  const bot = ownedBot(s, user, preview.botId), binding = s.store.metadata<ImportBinding>(`memoryImport:${preview.id}`);
  if (!binding || binding.consumed) fail('conflict', 'This preview has already been confirmed.');
  if (preview.expiresAtMs <= s.now()) fail('expired', 'Import preview has expired.');
  s.mutations.checkRevision(preview, body.revision);
  if (bot.revision !== binding.botRevision || bot.machineId !== binding.machineId) fail('revision_conflict', 'Bot or assigned machine changed after preview.');
  const selected = body.selectedCandidateIds.map(candidateId => preview.candidates.find(value => value.id === candidateId) ?? fail('invalid_request', 'Selected candidate is not part of the preview.'));
  let bytes: Uint8Array;
  if (binding.attachmentId) { const attachment = s.auth.attachment(user, binding.attachmentId); if (attachment.state !== 'ready' || attachment.ownerUserId !== user.userId || attachment.revision !== binding.attachmentRevision) fail('revision_conflict', 'Import attachment changed.'); bytes = await s.attachments.bytes(attachment.id); }
  else bytes = new TextEncoder().encode(s.decrypt<string>(binding.sourceText!));
  if (new Bun.CryptoHasher('sha256').update(bytes).digest('hex') !== preview.sourceSha256) fail('revision_conflict', 'Import source changed.');
  const current = ownedBot(s, user, bot.id);
  if (current.revision !== binding.botRevision || current.machineId !== binding.machineId) fail('revision_conflict', 'Bot placement changed during source verification.');
  s.mutations.confirm(user, preview, 'memory_import', { ...body, confirmName: bot.name }, { botRevision: bot.revision, machineId: bot.machineId, sourceSha256: preview.sourceSha256, candidateIds: preview.candidates.map(value => value.id) });
  s.store.setMetadata(`memoryImport:${preview.id}`, { ...binding, consumed: true });
  context.nonceResourceIds.push(preview.id, bot.id);
  const items: P.Memory[] = [], failedCandidateIds: string[] = [];
  let uncertain = false;
  for (const candidate of selected) {
    const attempt: ImportAttempt = { id: `${preview.id}:${candidate.id}`, previewId: preview.id, candidateId: candidate.id, nonce: s.id('memoryimport'), state: 'pending', memoryId: null };
    s.store.put('memoryImportAttempts', attempt);
    try {
      const memory = await s.invoke<P.Memory>(user, 'POST', `/v1/bots/${encodeURIComponent(bot.id)}/memory`, { clientNonce: attempt.nonce, text: candidate.text, kind: candidate.kind });
      items.push(memory); s.store.put('memoryImportAttempts', { ...attempt, state: 'completed', memoryId: memory.id });
    } catch (error) {
      failedCandidateIds.push(candidate.id);
      const unknown = !(error instanceof ApiError) || error.code === 'outcome_unknown' || !error.retrySafe;
      uncertain ||= unknown;
      s.store.put('memoryImportAttempts', { ...attempt, state: unknown ? 'outcome_unknown' : 'completed' });
      if (unknown) { failedCandidateIds.push(...selected.slice(selected.indexOf(candidate) + 1).map(value => value.id)); break; }
    }
  }
  return { previewId: preview.id, items, status: uncertain ? 'outcome_unknown' : 'completed', failedCandidateIds };
}

function visibleMilestones(s: BackendServices, user: Principal, bot: P.Bot): P.Milestone[] {
  assertBotOwner(user, bot);
  const evidence: { kind: P.Milestone['kind']; id: string; at: number }[] = [];
  const machine = s.store.require<P.Machine>('machines', bot.machineId);
  const placement = s.store.metadata<{ profileId: string; nodeId: string; acknowledged?: boolean; completedAtMs?: number }>(`botProfileSync:${bot.id}`);
  if (s.lemon.connected && machine.status === 'online' && machine.nodeId && machine.lastSeenAtMs !== null && placement?.acknowledged && placement.profileId === bot.profileId && placement.nodeId === machine.nodeId && !s.store.metadata(`botLifecycle:${bot.id}`)) evidence.push({ kind: 'machine_attached', id: machine.nodeId, at: placement.completedAtMs ?? machine.lastSeenAtMs });
  const successful = s.store.list<P.Run>('runs', run => run.botId === bot.id && run.status === 'succeeded' && run.completedAtMs !== null && !!conversation(s, user, run.conversationId)).sort((a, b) => a.completedAtMs! - b.completedAtMs!);
  const routine = successful.find(run => run.routineRunId !== null && s.store.get<P.RoutineRun>('routineRuns', run.routineRunId)?.status === 'succeeded');
  if (routine) evidence.push({ kind: 'first_routine_success', id: routine.id, at: routine.completedAtMs! });
  const approved = successful.find(run => conversation(s, user, run.conversationId)?.kind === 'task' && s.store.list<P.Approval>('approvals', approval => approval.runId === run.id && approval.gate.state === 'approved' && approval.gate.resolvedByUserId === user.userId && approval.gate.resolvedAtMs !== null && approval.gate.resolvedAtMs <= run.completedAtMs!).length > 0);
  if (approved) evidence.push({ kind: 'first_approved_task_completed', id: approved.id, at: approved.completedAtMs! });
  s.store.transaction(() => { for (const fact of evidence) {
    const valueId = `milestone_${s.mutations.digest({ botId: bot.id, userId: user.userId, kind: fact.kind }).slice(0, 48)}`;
    if (s.store.get('milestones', valueId)) continue;
    const milestone: P.Milestone = { ...s.resource('milestone', { botId: bot.id, userId: user.userId, kind: fact.kind, evidenceId: fact.id, earnedAtMs: fact.at, acknowledgedAtMs: null }), id: valueId };
    s.store.put('milestones', milestone); s.events.emit('milestone.upserted', milestone, { userIds: [user.userId] });
  } });
  return s.store.list<P.Milestone>('milestones', value => value.botId === bot.id && value.userId === user.userId);
}

export interface ExperienceService { dispatchDueReminders(): void; reconcile(): void; start(): void; close(): void }

/** Durable notification due-time dispatcher only; all agent scheduling stays in Lemon cron. */
export function createExperienceService(s: BackendServices): ExperienceService {
  let timer: Timer | undefined;
  let unsubscribe: (() => void) | undefined;
  const publish = (event: P.RealtimeEvent): void => {
    let botIds: string[] = [], kind: P.ActivityItem['kind'] | null = null, resourceId: string | null = null;
    switch (event.event) {
      case 'run.upserted': botIds = [event.payload.botId]; kind = 'run'; resourceId = event.payload.id; break;
      case 'entry.upserted': botIds = s.store.get<P.Conversation>('conversations', event.payload.conversationId)?.botIds ?? []; if (event.payload.kind === 'tool_call') { kind = 'tool'; resourceId = event.payload.id; } break;
      case 'entry.delta': return;
      case 'approval.upserted': botIds = [event.payload.botId]; kind = 'approval'; resourceId = event.payload.id; break;
      case 'question.upserted': case 'human_step.upserted': case 'secret_request.upserted': botIds = [event.payload.botId]; break;
      case 'attachment.upserted': botIds = event.payload.provenance.botId ? [event.payload.provenance.botId] : []; kind = 'artifact'; resourceId = event.payload.id; break;
      case 'memory.upserted': botIds = [event.payload.botId]; kind = 'memory'; resourceId = event.payload.id; break;
      case 'preference_change.upserted': botIds = [event.payload.botId]; kind = 'preference'; resourceId = event.payload.id; break;
      case 'machine_invite.upserted': { const machineId = event.payload.machineId; botIds = s.store.list<P.Bot>('bots', value => value.machineId === machineId).map(value => value.id); kind = 'enrollment'; resourceId = event.payload.id; break; }
      case 'machine.upserted': { const machineId = event.payload.id; botIds = s.store.list<P.Bot>('bots', value => value.machineId === machineId).map(value => value.id); break; }
      case 'bot.upserted': botIds = [event.payload.id]; break;
      case 'routine_run.upserted': { const routine = s.store.get<P.Routine>('routines', event.payload.routineId); if (routine) botIds = [routine.botId]; break; }
      default: return;
    }
    const workspaceId = s.store.metadata<string>('workspaceId');
    if (!workspaceId) return;
    for (const member of s.store.list<P.Member>('members', value => value.enabled)) {
      const user: Principal = { kind: 'user', id: member.userId, userId: member.userId, workspaceId, role: member.role, sessionId: null, botId: null, deviceId: null };
      for (const botId of botIds) {
        const bot = s.store.get<P.Bot>('bots', botId), machine = bot && s.store.get<P.Machine>('machines', bot.machineId);
        if (!bot || bot.ownerUserId !== user.userId || !machine || !readable(s, user, 'bots', bot)) continue;
        const presence = botPresence(s, user, bot), { measuredAtMs: _measuredAtMs, ...facts } = presence;
        const fingerprint = s.mutations.digest(facts), presenceKey = `presenceDigest:${bot.id}:${user.userId}`;
        if (s.store.metadata<string>(presenceKey) !== fingerprint) { s.store.setMetadata(presenceKey, fingerprint); s.events.emit('bot.presence', presence, { userIds: [user.userId] }); }
        visibleMilestones(s, user, bot);
        if (kind && resourceId) {
          const activityId = `activity_${s.mutations.digest({ kind, resourceId, botId }).slice(0, 48)}`;
          const item = activityValues(s, user).find(value => value.id === activityId);
          if (item) s.events.emit('activity.upserted', item, { userIds: [user.userId] });
        }
      }
    }
  };
  function dispatchDueReminders(): void {
    for (const pending of s.store.list<P.Reminder>('reminders', value => value.state === 'scheduled' && value.dueAtMs <= s.now())) {
      s.store.transaction(() => {
        const reminder = s.store.require<P.Reminder>('reminders', pending.id);
        if (reminder.state !== 'scheduled') return;
        const member = s.store.list<P.Member>('members', value => value.userId === reminder.userId)[0];
        const workspaceId = s.store.metadata<string>('workspaceId');
        if (!member?.enabled || !workspaceId) return;
        const user: Principal = { kind: 'user', id: member.userId, userId: member.userId, workspaceId, role: member.role, sessionId: null, botId: null, deviceId: null };
        const bot = s.store.get<P.Bot>('bots', reminder.botId), room = conversation(s, user, reminder.conversationId);
        if (!bot || bot.ownerUserId !== user.userId || !room || !readable(s, user, 'bots', bot)) { s.store.put('reminders', s.update(reminder, { state: 'cancelled' })); return; }
        const notificationKey = `reminderNotification:${reminder.id}`;
        if (!s.store.metadata<string>(notificationKey)) {
          const entry = s.entry(user, room.id, { kind: 'notice', severity: 'info', text: reminder.text, requestId: null, targetedUserId: user.userId, actor: { kind: 'system', id: null, displayName: 'Reminder' } });
          const notification = s.notify(user, { userId: user.userId, kind: 'result', botId: bot.id, conversationId: room.id, entryId: entry.id, title: 'Reminder', body: reminder.text.slice(0, 1024), target: { kind: 'entry', botId: bot.id, conversationId: room.id, taskConversationId: room.kind === 'task' ? room.id : null, entryId: entry.id } });
          s.store.setMetadata(notificationKey, notification.id);
        }
        const delivered = s.update(reminder, { state: 'delivered' }); s.store.put('reminders', delivered); s.events.emit('reminder.upserted', delivered, { userIds: [user.userId] });
      });
    }
  }
  function reconcile(): void { finalizePreferenceUndos(s); dispatchDueReminders(); }
  return {
    dispatchDueReminders, reconcile,
    start() {
      if (timer !== undefined) return;
      unsubscribe = s.events.subscribe(publish);
      reconcile();
      timer = setInterval(reconcile, 1000);
    },
    close() { clearInterval(timer); timer = undefined; unsubscribe?.(); unsubscribe = undefined; },
  };
}

export function createExperienceRoutes(s: BackendServices): Route[] {
  const route = (method: string, path: string, handler: Route['handler'], status = 200): Route => ({
    method, path: `/v1${path}`, auth: 'member', status, handler,
    authorizeReplay: method === 'GET' ? undefined : context => {
      const user = principal(context.user);
      switch (path) {
        case '/bots/:id/grants/:grantId': ownedBot(s, user, context.params.id!); return;
        case '/bots/:id/preference-changes': {
          const body = parse(preferenceCreate, context.body), bot = ownedBot(s, user, context.params.id!);
          sourceEntry(s, user, bot, body.sourceEntryId); return;
        }
        case '/preference-changes/:id/undo': {
          const change = s.store.require<P.PreferenceChange>('preferenceChanges', context.params.id!);
          ownedBot(s, user, change.botId);
          if (!preferenceVisible(s, user, change)) fail('not_found', 'Preference change is not accessible.');
          return;
        }
        case '/bots/:id/memory/import/preview': {
          const body = parse(previewRequest, context.body);
          ownedBot(s, user, context.params.id!);
          if (body.attachmentId) s.auth.attachment(user, body.attachmentId);
          return;
        }
        case '/bots/:id/memory/import': {
          const body = parse(importRequest, context.body), preview = s.store.require<P.MemoryImportPreview>('memoryImportPreviews', body.previewId);
          if (preview.userId !== user.userId || preview.botId !== context.params.id) fail('not_found', 'Import preview is not accessible.');
          ownedBot(s, user, preview.botId); return;
        }
        case '/reminders': {
          const body = parse(reminderRequest, context.body), bot = ownedBot(s, user, body.botId), room = conversation(s, user, body.conversationId);
          if (!room || !room.botIds.includes(bot.id)) fail('not_found', 'Reminder conversation is not accessible.');
          return;
        }
        case '/reminders/:id': {
          const reminder = s.store.require<P.Reminder>('reminders', context.params.id!);
          if (reminder.userId !== user.userId || !conversation(s, user, reminder.conversationId)) fail('not_found', 'Reminder is not accessible.');
          ownedBot(s, user, reminder.botId); return;
        }
        case '/milestones/:id/ack': {
          const milestone = s.store.require<P.Milestone>('milestones', context.params.id!);
          if (milestone.userId !== user.userId) fail('not_found', 'Milestone is not accessible.');
          ownedBot(s, user, milestone.botId); return;
        }
        default: fail('internal_error', 'Experience mutation has no replay authorization.', false);
      }
    },
  });
  const activityRead = async (context: RequestContext) => {
    const user = principal(context.user);
    if (context.params.id) ownedBot(s, user, context.params.id);
    await s.runtime.reconcile();
    return activityPage(context);
  };
  const preference = async (context: RequestContext) => {
    const user = principal(context.user), body = parse(preferenceCreate, context.body);
    ownedBot(s, user, context.params.id!);
    const bot = s.store.require<P.Bot>('bots', context.params.id!);
    s.mutations.checkRevision(bot, body.revision); sourceEntry(s, user, bot, body.sourceEntryId);
    finalizePreferenceUndos(s, bot.id);
    const sync = s.store.metadata<{ state: string }>(`preferenceSync:${bot.id}`);
    if (sync && sync.state !== 'acknowledged') fail('outcome_unknown', 'An earlier preference synchronization is unresolved.', false);
    const next = s.store.transaction(() => {
      s.mutations.checkRevision(s.store.require<P.Bot>('bots', bot.id), body.revision);
      const value = s.update(bot, body.changes);
      s.store.put('bots', value);
      s.store.setMetadata(`preferenceSync:${bot.id}`, { state: 'pending', revision: value.revision });
      return value;
    });
    const recorded = recordPreferenceChange(s, user, bot, next, body.changes, body.reason, body.sourceEntryId ?? null);
    context.nonceResourceIds.push(bot.id, recorded.id);
    try { await s.syncBotProfile(user, bot.id); } catch {
      s.store.setMetadata(`preferenceSync:${bot.id}`, { state: 'outcome_unknown', revision: next.revision });
      fail('outcome_unknown', 'Preference changes were saved but destination synchronization is unconfirmed.', false, { resourceIds: [bot.id, recorded.id] });
    }
    s.store.setMetadata(`preferenceSync:${bot.id}`, { state: 'acknowledged', revision: next.revision });
    s.events.emit('bot.upserted', next, { botId: bot.id });
    return recorded;
  };
  return [
    route('GET', '/machines/:id/capabilities', context => { parse(z.object({}).strict(), queryObject(context.query)); return machineCapabilities(s, principal(context.user), context.params.id!); }),
    route('GET', '/bots/:id/presence', async context => { parse(z.object({}).strict(), queryObject(context.query)); const user = principal(context.user); ownedBot(s, user, context.params.id!); await s.runtime.reconcile(); return botPresence(s, user, ownedBot(s, user, context.params.id!)); }),
    route('GET', '/bots/:id/grants', async context => { parse(pageQuery, queryObject(context.query)); const user = principal(context.user); return s.page(context, await effectiveBotGrants(s, user, ownedBot(s, user, context.params.id!))); }),
    route('PATCH', '/bots/:id/grants/:grantId', async context => {
      const user = principal(context.user), body = parse(update.extend({ requestedLevel: level }), context.body), bot = ownedBot(s, user, context.params.id!);
      const measured = await machineCapabilities(s, user, bot.machineId, bot);
      const grant = (await effectiveBotGrants(s, user, bot, measured)).find(value => value.id === context.params.grantId) ?? fail('not_found', 'Grant does not exist.');
      s.mutations.checkRevision(grant, body.revision);
      const connector = grant.capabilityId.startsWith('connector:');
      const capability = measured.items.find(value => value.id === grant.capabilityId);
      if (connector ? !s.integrations.connectorProvisioning : !capability || !Object.hasOwn(nativeToolFamilies, capability.category) || !s.lemon.methods.includes('profiles.update')) fail('capability_unavailable', 'No destination policy mapping exists for this capability.');
      if (!connector && capability?.category === 'shell' && body.requestedLevel === 'read_only') fail('capability_unavailable', 'A general shell has no enforceable read-only native tool mapping.');
      await s.runtime.reconcile();
      if (s.store.list<P.Run>('runs', run => run.botId === bot.id && ['reserved', 'queued', 'running', 'awaiting_input', 'outcome_unknown'].includes(run.status)).length) fail('conflict', 'Stop or finish active bot work before changing tool permissions.');
      const sync = s.store.metadata<{ state: string }>(`botPolicySync:${bot.id}`);
      if (sync && sync.state !== 'acknowledged') fail('outcome_unknown', 'An earlier tool-policy cutover is unresolved.', false);
      const next = s.update(grant, { requestedLevel: body.requestedLevel });
      context.nonceResourceIds.push(bot.id, next.id);
      s.store.transaction(() => { const current = s.store.get<P.BotGrant>('botGrants', grant.id); if (current) s.mutations.checkRevision(current, body.revision); s.store.put('botGrants', next); s.store.setMetadata(`botPolicySync:${bot.id}`, { state: 'pending', grantId: next.id, revision: next.revision }); });
      const effective = projectEffectiveBotGrants(s, user, bot, measured, await s.integrations.effectivePolicy(user, bot.id), true).find(value => value.id === next.id)!;
      s.store.put('botGrants', effective);
      try {
        if (connector) await s.integrations.connectorProvisioning!(user, bot.id);
        else await s.syncBotProfile(user, bot.id);
      } catch {
        s.store.setMetadata(`botPolicySync:${bot.id}`, { state: 'outcome_unknown', grantId: next.id, revision: next.revision });
        fail('outcome_unknown', 'Requested grants were saved but native policy enforcement is unconfirmed.', false, { resourceIds: [bot.id, next.id] });
      }
      s.store.setMetadata(`botPolicySync:${bot.id}`, { state: 'acknowledged', grantId: next.id, revision: next.revision });
      s.events.emit('grant.upserted', effective, { userIds: [user.userId] });
      return effective;
    }),
    route('GET', '/activity', activityRead), route('GET', '/bots/:id/activity', activityRead),
    route('GET', '/upcoming', upcomingPage), route('GET', '/bots/:id/upcoming', upcomingPage),
    route('GET', '/bots/:id/overview', async context => {
      parse(z.object({}).strict(), queryObject(context.query)); const user = principal(context.user); ownedBot(s, user, context.params.id!); await s.runtime.reconcile(); const bot = ownedBot(s, user, context.params.id!), presence = botPresence(s, user, bot);
      const paged = { ...context, query: new URLSearchParams({ limit: '20' }) };
      return { bot: { ...bot, activity: presence.status }, presence, machine: s.store.require<P.Machine>('machines', bot.machineId), grants: await effectiveBotGrants(s, user, bot), activity: activityPage({ ...paged, route: { ...context.route, path: '/v1/bots/:id/activity' } }), upcoming: upcomingPage({ ...paged, route: { ...context.route, path: '/v1/bots/:id/upcoming' } }) } satisfies P.BotOverview;
    }),
    route('GET', '/reminders', context => { const user = principal(context.user), query = parse(pageQuery.extend({ botId: id.optional() }), queryObject(context.query)); if (query.botId) ownedBot(s, user, query.botId); return s.page(context, s.store.list<P.Reminder>('reminders', value => value.userId === user.userId && s.store.get<P.Bot>('bots', value.botId)?.ownerUserId === user.userId && (!query.botId || value.botId === query.botId) && !!conversation(s, user, value.conversationId))); }),
    route('POST', '/reminders', context => { const user = principal(context.user), body = parse(reminderRequest, context.body), bot = ownedBot(s, user, body.botId), room = s.auth.conversation(user, body.conversationId); if (!room.botIds.includes(bot.id) || !conversation(s, user, room.id)) fail('forbidden', 'Reminder conversation must belong to this bot and user.'); if (body.dueAtMs <= s.now()) fail('expired', 'Reminder due time must be in the future.'); const value: P.Reminder = s.resource('reminder', { botId: bot.id, userId: user.userId, conversationId: room.id, text: body.text, dueAtMs: body.dueAtMs, timezone: body.timezone, state: 'scheduled' }); s.store.put('reminders', value); s.events.emit('reminder.upserted', value, { userIds: [user.userId] }); return value; }, 201),
    route('DELETE', '/reminders/:id', context => { const user = principal(context.user), body = parse(update, context.body); return s.store.transaction(() => { const value = s.store.require<P.Reminder>('reminders', context.params.id!); if (value.userId !== user.userId) fail('forbidden', 'Reminder belongs to another user.'); ownedBot(s, user, value.botId); s.mutations.checkRevision(value, body.revision); if (value.state === 'delivered') fail('conflict', 'Reminder already delivered.'); const cancelled = value.state === 'cancelled' ? value : s.update(value, { state: 'cancelled' }); s.store.put('reminders', cancelled); s.events.emit('reminder.upserted', cancelled, { userIds: [user.userId] }); return cancelled; }); }),
    route('GET', '/bots/:id/preference-changes', context => { const user = principal(context.user); parse(pageQuery, queryObject(context.query)); const bot = ownedBot(s, user, context.params.id!); return s.page(context, s.store.list<P.PreferenceChange>('preferenceChanges', value => value.botId === bot.id && preferenceVisible(s, user, value))); }),
    route('POST', '/bots/:id/preference-changes', preference, 201),
    route('POST', '/preference-changes/:id/undo', async context => {
      const user = principal(context.user), body = parse(preferenceUndo, context.body), target = s.store.require<P.PreferenceChange>('preferenceChanges', context.params.id!);
      ownedBot(s, user, target.botId); finalizePreferenceUndos(s, target.botId);
      const change = s.store.require<P.PreferenceChange>('preferenceChanges', target.id), bot = s.store.require<P.Bot>('bots', target.botId);
      if (!preferenceVisible(s, user, change)) fail('not_found', 'Preference change is not accessible.');
      s.mutations.checkRevision(change, body.revision); s.mutations.checkRevision(bot, body.botRevision);
      if (change.state !== 'applied' || bot.revision !== change.resultingBotRevision || Object.entries(change.after).some(([field, value]) => JSON.stringify(bot[field as keyof P.Bot]) !== JSON.stringify(value))) fail('revision_conflict', 'A subsequent bot change prevents undo.');
      const sync = s.store.metadata<{ state: string }>(`preferenceSync:${bot.id}`);
      if (sync && sync.state !== 'acknowledged') fail('outcome_unknown', 'An earlier preference synchronization is unresolved.', false);
      const restored = s.store.transaction(() => {
        s.mutations.checkRevision(s.store.require<P.Bot>('bots', bot.id), body.botRevision);
        const value = s.update(bot, change.before);
        s.store.put('bots', value);
        s.store.setMetadata(`preferenceSync:${bot.id}`, { state: 'pending', revision: value.revision });
        s.store.put('preferenceUndoAttempts', { id: change.id, botId: bot.id, userId: change.userId, botRevision: value.revision, changeRevision: change.revision } satisfies PreferenceUndoAttempt);
        return value;
      });
      context.nonceResourceIds.push(bot.id, change.id);
      try { await s.syncBotProfile(user, bot.id); } catch {
        s.store.setMetadata(`preferenceSync:${bot.id}`, { state: 'outcome_unknown', revision: restored.revision });
        fail('outcome_unknown', 'Preference undo was saved but destination synchronization is unconfirmed.', false, { resourceIds: [bot.id, change.id] });
      }
      s.store.setMetadata(`preferenceSync:${bot.id}`, { state: 'acknowledged', revision: restored.revision });
      finalizePreferenceUndos(s, bot.id);
      s.events.emit('bot.upserted', restored, { botId: bot.id });
      return s.store.require<P.PreferenceChange>('preferenceChanges', change.id);
    }),
    route('POST', '/bots/:id/memory/import/preview', previewMemory), route('POST', '/bots/:id/memory/import', confirmMemory),
    route('GET', '/bots/:id/ideas', async context => {
      parse(z.object({}).strict(), queryObject(context.query)); const user = principal(context.user), bot = ownedBot(s, user, context.params.id!), machine = s.store.require<P.Machine>('machines', bot.machineId);
      const ready = s.lemon.connected && machine.status === 'online';
      const grants = ready ? await effectiveBotGrants(s, user, bot) : s.store.list<P.BotGrant>('botGrants', value => value.botId === bot.id && value.machineId === bot.machineId).map(value => ({ ...value, effectiveLevel: 'off' as const }));
      const policy = await s.integrations.effectivePolicy(user, bot.id);
      const make = (ideaId: string, title: string, prompt: string, output: string, skills: string[] = [], connectors: string[] = [], caps: string[] = []): P.BotIdea => {
        const blockers = ready ? [] : ['Assigned machine is unavailable.'];
        if (!policy.productAccess || policy.localExecutionCeiling === 'deny') blockers.push('Current product policy blocks execution.');
        for (const cap of caps) if (!grants.some(grant => grant.capabilityId === cap && grant.effectiveLevel !== 'off')) blockers.push(`Capability ${cap} is unavailable or not authorized.`);
        return { id: ideaId, botId: bot.id, title, prompt, expectedOutput: output, requiredSkillIds: skills, requiredConnectorIds: connectors, requiredCapabilityIds: caps, ready: blockers.length === 0, blockedReasons: blockers };
      };
      const ideas = [make('plan', 'Plan a useful next step', 'Using your Job and boundaries, propose three concrete next steps. Do not take action yet.', 'A short prioritized plan with dependencies.'), make('review', 'Review a draft', 'Review the draft I provide for clarity and correctness. Return suggested edits without publishing.', 'A reviewed draft and concise explanation.')];
      if (bot.job.trim()) ideas.push(make('job', 'Turn your Job into a checklist', 'Turn your current Job into a reusable checklist, noting what requires my input. Do not execute it.', 'A checklist aligned with your Job.'));
      for (const skillId of bot.skillIds) { const skill = s.store.get<P.Skill>('skills', skillId); if (skill?.enabled && skill.machineIds.includes(bot.machineId) && readable(s, user, 'skills', skill)) ideas.push(make(`skill:${skill.id}`, `Use ${skill.name}`, `Help me use the installed skill ${skill.name}. First ask for missing inputs, then draft the result for review.`, 'A skill-specific draft for review.', [skill.id])); if (ideas.length === 6) break; }
      for (const connector of s.store.list<P.Connector>('connectors', value => value.botId === bot.id && value.ownerUserId === user.userId && readable(s, user, 'connectors', value))) {
        if (ideas.length >= 6) break;
        const idea = make(`connector:${connector.id}`, `Prepare a ${connector.name} draft`, `Use the ${connector.name} connector to prepare a draft from inputs I provide. Ask for missing details; do not send or publish.`, 'A connector-backed draft awaiting explicit review.', [], [connector.id], [`connector:${connector.id}`]);
        if (connector.state !== 'connected') { idea.ready = false; idea.blockedReasons.push('Connector is not connected.'); }
        ideas.push(idea);
      }
      if (ideas.length < 6) ideas.push(make('files', 'Organize selected files', 'Inspect only the files I explicitly select and propose an organization plan. Do not move or delete anything.', 'A file inventory and proposed organization.', [], [], ['files']));
      return ideas.slice(0, 6);
    }),
    route('GET', '/bots/:id/milestones', async context => { parse(pageQuery, queryObject(context.query)); const user = principal(context.user); ownedBot(s, user, context.params.id!); await s.runtime.reconcile(); const bot = ownedBot(s, user, context.params.id!); return s.page(context, visibleMilestones(s, user, bot)); }),
    route('POST', '/milestones/:id/ack', context => { const user = principal(context.user); parse(mutation, context.body); return s.store.transaction(() => { const value = s.store.require<P.Milestone>('milestones', context.params.id!); if (value.userId !== user.userId) fail('forbidden', 'Milestone belongs to another user.'); ownedBot(s, user, value.botId); if (value.acknowledgedAtMs !== null) fail('conflict', 'Milestone already acknowledged.'); const acknowledged = s.update(value, { acknowledgedAtMs: s.now() }); s.store.put('milestones', acknowledged); s.events.emit('milestone.upserted', acknowledged, { userIds: [user.userId] }); return acknowledged; }); }),
  ];
}
