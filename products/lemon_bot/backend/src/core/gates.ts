import type * as P from '../../../contracts/protocol';
import type { BackendServices, GateService, Principal, RequestContext, Route } from './services';
import { ApiError, fail } from './errors';
import { z, parse, id, nonce, update, boundedText, principal, queryObject } from './validation';

const MAX_WAIT = 600_000;
const categories = z.enum(['shell', 'files', 'external_message', 'calendar', 'publish', 'purchase', 'permissions', 'connector', 'handoff']);
const states = z.enum(['pending', 'submitted', 'approved', 'denied', 'declined', 'expired', 'cancelled', 'completed', 'failed', 'outcome_unknown']);
const json: z.ZodType<P.JSONValue> = z.lazy(() => z.union([z.null(), z.boolean(), z.number().finite(), boundedText(65_536), z.array(json), z.record(z.string(), json)]));
const common = z.object({ botId: id, conversationId: id, targetUserId: id.optional(), runId: id.nullable().optional(), clientNonce: nonce.optional(), expiresInMs: z.number().int().min(1000).max(MAX_WAIT).optional() }).strict();
const option = z.object({ value: boundedText(1024, 1), label: boundedText(1024, 1) }).strict();
const field = z.object({ id: boundedText(128, 1), label: boundedText(1024, 1), kind: z.enum(['text', 'multiline', 'number', 'boolean', 'single_select', 'multi_select']), required: z.boolean(), options: z.array(option).min(1).max(100).optional(), min: z.number().finite().optional(), max: z.number().finite().optional() }).strict();
const upstreamSchema = z.object({ approvalId: id, sessionKey: boundedText(1024, 1), runId: id, nodeId: id.nullable().optional(), invokeId: id.nullable().optional() }).strict();
export type ApprovalSource = z.infer<typeof upstreamSchema>;
const approvalInput = common.extend({ category: categories, title: boundedText(1024, 1), description: boundedText(32_768), target: boundedText(4096, 1), inputs: z.record(z.string(), json), source: z.enum(['product', 'lemon_exec']).optional(), upstream: upstreamSchema.optional(), forceHuman: z.boolean().optional() });
const questionInput = common.extend({ title: boundedText(1024, 1), fields: z.array(field).min(1).max(32) });
const humanInput = common.extend({ title: boundedText(1024, 1), instructions: boundedText(32_768, 1), reason: z.enum(['login', 'mfa', 'captcha', 'payment', 'identity', 'other']), externalUrl: z.url().refine(value => new URL(value).protocol === 'https:').nullable().optional() });
const secretInput = common.extend({ name: z.string().min(1).max(256).regex(/^[A-Za-z0-9][A-Za-z0-9_.-]*$/), description: boundedText(4096), scope: z.enum(['machine', 'bot']) });
const attachmentIds = z.array(id).max(6);
export const draftContentSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('email'), connectorId: id, from: boundedText(1024, 1), to: z.array(boundedText(1024, 1)).min(1).max(100), cc: z.array(boundedText(1024, 1)).max(100), bcc: z.array(boundedText(1024, 1)).max(100), subject: boundedText(4096), body: boundedText(65_536), attachmentIds }).strict(),
  z.object({ kind: z.literal('slack'), connectorId: id, workspace: boundedText(1024, 1), target: boundedText(1024, 1), thread: boundedText(1024, 1).nullable(), body: boundedText(65_536), attachmentIds }).strict(),
  z.object({ kind: z.literal('message'), channelBindingId: id, target: boundedText(1024, 1), thread: boundedText(1024, 1).nullable(), body: boundedText(65_536), attachmentIds }).strict(),
]);
const draftInput = common.omit({ expiresInMs: true }).extend({ content: draftContentSchema });
const approvalResolve = update.extend({ decision: z.enum(['approve_once', 'deny']) });
const questionResolve = update.extend({ decision: z.enum(['answer', 'decline']), answers: z.record(z.string(), json).optional() }).superRefine((value, context) => {
  if ((value.decision === 'answer') !== (value.answers !== undefined)) context.addIssue({ code: 'custom', message: 'Answer requires answers; decline must omit answers.' });
});
const humanResolve = update.extend({ decision: z.enum(['done', 'skip']) });
const secretResolve = update.extend({ decision: z.enum(['save', 'decline']), value: boundedText(1_048_576, 1).refine(value => new TextEncoder().encode(value).byteLength <= 1_048_576).optional() }).superRefine((value, context) => {
  if ((value.decision === 'save') !== (value.value !== undefined)) context.addIssue({ code: 'custom', message: 'Save requires value; decline must omit value.' });
});
const draftEdit = update.extend({ content: draftContentSchema });
type GateResource = P.Approval | P.Question | P.HumanStep | P.SecretRequest;
type Collection = 'approvals' | 'questions' | 'humanSteps' | 'secretRequests';
const collections: Collection[] = ['approvals', 'questions', 'humanSteps', 'secretRequests'];
const collectionFor = { approval: 'approvals', question: 'questions', human_step: 'humanSteps', secret_request: 'secretRequests' } as const;

export interface BotGateResourceScope {
  collection: Collection | 'drafts';
  id: string;
  revision: number;
  entryId: string;
  entryRevision: number;
  state: P.ResolutionState | P.Draft['state'];
}
/** Opaque deletion candidates only: no answers, draft content or private transcript text. */
export function previewBotResources(services: BackendServices, botId: string): BotGateResourceScope[] {
  const result: BotGateResourceScope[] = [];
  for (const name of collections) for (const resource of services.store.list<GateResource>(name, value => value.botId === botId)) result.push({ collection: name, id: resource.id, revision: resource.revision, entryId: resource.entryId, entryRevision: services.store.require<P.TranscriptEntry>('entries', resource.entryId).revision, state: resource.gate.state });
  for (const draft of services.store.list<P.Draft>('drafts', value => value.botId === botId)) result.push({ collection: 'drafts', id: draft.id, revision: draft.revision, entryId: draft.entryId, entryRevision: services.store.require<P.TranscriptEntry>('entries', draft.entryId).revision, state: draft.state });
  return result.sort((left, right) => left.collection.localeCompare(right.collection) || left.id.localeCompare(right.id));
}

function collection(value: string): Collection {
  if (!collections.includes(value as Collection)) fail('invalid_request', 'Unsupported gate collection.');
  return value as Collection;
}
function targetPrincipal(services: BackendServices, actor: Principal, userId: string): Principal {
  const member = services.auth.member(userId);
  if (!member.enabled) fail('forbidden', 'The target member is disabled.');
  return { ...actor, kind: 'user', id: userId, userId, role: member.role, botId: null, sessionId: null, deviceId: null };
}
function ownedBot(services: BackendServices, actor: Principal, botId: string): P.Bot {
  const bot = services.auth.bot(actor, botId);
  if (bot.ownerUserId !== actor.userId) fail('forbidden', 'Only the Bot owner has live execution authority.');
  return bot;
}
function ownsRoom(services: BackendServices, ownerUserId: string, botId: string, room: P.Conversation | null): boolean {
  return !!room && room.ownerUserId === ownerUserId && room.botIds.includes(botId) && room.botIds.every(id => services.store.get<P.Bot>('bots', id)?.ownerUserId === ownerUserId);
}
function creationOwner(services: BackendServices, actor: Principal, input: z.infer<typeof common>): P.Bot {
  const bot = ownedBot(services, actor, input.botId);
  if (input.targetUserId !== undefined && input.targetUserId !== bot.ownerUserId) fail('forbidden', 'Human input must target the Bot owner.');
  const room = services.auth.conversation(actor, input.conversationId);
  if (!ownsRoom(services, bot.ownerUserId, bot.id, room)) fail('forbidden', 'Conversation execution belongs only to its Bot owner.');
  return bot;
}
function context(services: BackendServices, actor: Principal, input: z.infer<typeof common>, sensitive: boolean): { bot: P.Bot; conversation: P.Conversation; target: Principal } {
  const bot = creationOwner(services, actor, input);
  if (actor.kind === 'bot' && actor.botId !== bot.id) fail('forbidden', 'Bot authority does not match.');
  const room = services.auth.conversation(actor, input.conversationId);
  if (!room.botIds.includes(bot.id)) fail('forbidden', 'Bot is not a participant.');
  const userId = bot.ownerUserId;
  const target = targetPrincipal(services, actor, userId);
  services.auth.bot(target, bot.id);
  if (input.runId) {
    const run = services.store.require<P.Run>('runs', input.runId);
    if (run.botId !== bot.id || run.conversationId !== room.id || run.initiatorUserId !== actor.userId || !['running', 'awaiting_input'].includes(run.status)) fail('forbidden', 'Gate invocation is not active.');
  }
  if (!sensitive || (room.kind !== 'group' && room.kind !== 'channel')) return { bot, conversation: room, target };
  let privateRoom = services.store.list<P.Conversation>('conversations', item => item.kind === 'dm' && item.botIds.length === 1 && item.botIds[0] === bot.id && item.ownerUserId === userId)[0];
  if (!privateRoom) {
    privateRoom = services.resource('conversation', { kind: 'dm' as const, name: bot.name, botIds: [bot.id], ownerUserId: userId, parentConversationId: null, leadBotId: bot.id, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] });
    services.store.put('conversations', privateRoom);
    services.events.emit('conversation.upserted', privateRoom, { userIds: [userId], conversationId: privateRoom.id });
  }
  services.entry(actor, room.id, { kind: 'notice', severity: 'info', text: 'Private input requested. The target member can continue in their private bot conversation.', requestId: null, actor: { kind: 'bot', id: bot.id, displayName: bot.name } });
  return { bot, conversation: privateRoom, target };
}
function conversationOf(services: BackendServices, resource: GateResource): string {
  return 'conversationId' in resource ? resource.conversationId : services.store.require<P.TranscriptEntry>('entries', resource.entryId).conversationId;
}
function cardFor(collection: Collection, resource: GateResource): P.Card {
  switch (collection) {
    case 'approvals': { const approval = resource as P.Approval; return { type: approval.category === 'shell' || approval.category === 'files' ? 'local_tool_permission' : approval.category === 'publish' ? 'publish_approval' : approval.policyMode === 'auto_review' ? 'auto_review_approval' : 'permission_request', approval }; }
    case 'questions': return { type: 'user_form', question: resource as P.Question };
    case 'humanSteps': return { type: 'human_step', step: resource as P.HumanStep };
    case 'secretRequests': return { type: 'secret_request', request: resource as P.SecretRequest };
  }
}
function emitGate(services: BackendServices, name: Collection, resource: GateResource): void {
  const audience = { userIds: [resource.gate.targetUserId], conversationId: conversationOf(services, resource) };
  switch (name) {
    case 'approvals': services.events.emit('approval.upserted', resource as P.Approval, audience); break;
    case 'questions': services.events.emit('question.upserted', resource as P.Question, audience); break;
    case 'humanSteps': services.events.emit('human_step.upserted', resource as P.HumanStep, audience); break;
    case 'secretRequests': services.events.emit('secret_request.upserted', resource as P.SecretRequest, audience); break;
  }
}
function persistGate<T extends GateResource>(services: BackendServices, name: Collection, resource: T): T {
  services.store.put(name, resource);
  const entry = services.store.require<P.TranscriptEntry>('entries', resource.entryId);
  if (entry.kind !== 'card') fail('internal_error', 'Gate transcript is unavailable.', false);
  const updatedEntry = services.update(entry, { card: cardFor(name, resource) });
  services.store.put('entries', updatedEntry);
  emitGate(services, name, resource);
  services.events.emit('entry.upserted', updatedEntry, { conversationId: entry.conversationId, userIds: [resource.gate.targetUserId] });
  return resource;
}
function transition<T extends GateResource>(services: BackendServices, name: Collection, resource: T, state: P.ResolutionState, userId: string | null, changes: Partial<T> = {}): T {
  return persistGate(services, name, services.update(resource, { ...changes, gate: { ...resource.gate, revision: resource.revision + 1, state, resolvedAtMs: state === 'submitted' ? null : services.now(), resolvedByUserId: userId } } as Partial<T>));
}
function validateFields(fields: P.Field[]): void {
  if (new Set(fields.map(item => item.id)).size !== fields.length) fail('invalid_request', 'Field IDs must be unique.');
  for (const item of fields) {
    const select = item.kind === 'single_select' || item.kind === 'multi_select';
    if (select !== (item.options !== undefined) || (item.options && new Set(item.options.map(value => value.value)).size !== item.options.length)) fail('invalid_request', 'Select options must be unique and present only on select fields.');
    if ((item.min !== undefined || item.max !== undefined) && item.kind !== 'number') fail('invalid_request', 'Only numeric fields accept bounds.');
    if (item.min !== undefined && item.max !== undefined && item.min > item.max) fail('invalid_request', 'Field bounds are reversed.');
  }
}
function validateAnswers(question: P.Question, answers: Record<string, P.JSONValue>): void {
  if (Object.keys(answers).some(key => !question.fields.some(field => field.id === key))) fail('invalid_request', 'Answer contains an unknown field.');
  for (const field of question.fields) {
    if (!Object.hasOwn(answers, field.id)) { if (field.required) fail('invalid_request', 'A required answer is missing.'); continue; }
    const value = answers[field.id];
    let valid = false;
    switch (field.kind) {
      case 'text': case 'multiline': valid = typeof value === 'string' && (!field.required || value.trim().length > 0); break;
      case 'number': valid = typeof value === 'number' && Number.isFinite(value) && (field.min === undefined || value >= field.min) && (field.max === undefined || value <= field.max); break;
      case 'boolean': valid = typeof value === 'boolean'; break;
      case 'single_select': valid = typeof value === 'string' && !!field.options?.some(option => option.value === value); break;
      case 'multi_select': valid = Array.isArray(value) && (!field.required || value.length > 0) && value.every(item => typeof item === 'string' && field.options?.some(option => option.value === item)) && new Set(value).size === value.length; break;
    }
    if (!valid) fail('invalid_request', 'Answer does not satisfy the field type, options or bounds.');
  }
}
function ownsGate(services: BackendServices, actor: Principal, resource: GateResource): boolean {
  const bot = services.store.get<P.Bot>('bots', resource.botId);
  const conversationId = 'conversationId' in resource ? resource.conversationId : services.store.get<P.TranscriptEntry>('entries', resource.entryId)?.conversationId;
  const room = conversationId ? services.store.get<P.Conversation>('conversations', conversationId) : null;
  return !!bot && actor.userId === bot.ownerUserId && resource.gate.targetUserId === bot.ownerUserId && ownsRoom(services, bot.ownerUserId, bot.id, room);
}
function visible(services: BackendServices, actor: Principal, name: Collection, resource: GateResource): void {
  if (!ownsGate(services, actor, resource) || !services.auth.canRead(actor, name, resource)) fail('not_found', 'Request not found.');
  services.auth.conversation(actor, conversationOf(services, resource));
}
function pending(services: BackendServices, actor: Principal, name: Collection, resource: GateResource, revision: number): void {
  visible(services, actor, name, resource);
  if (actor.kind !== 'user' || actor.userId !== resource.gate.targetUserId) fail('forbidden', 'Only the target member can resolve this request.');
  if (resource.gate.state === 'expired' || (resource.gate.state === 'pending' && services.now() >= resource.gate.expiresAtMs)) fail('expired', 'This request has expired.');
  services.mutations.checkRevision(resource, revision);
  services.mutations.checkRevision(resource.gate, revision);
  if (resource.gate.state !== 'pending') fail('conflict', 'This request has already been resolved.', false);
}
function nonceKey(actor: Principal, kind: string, clientNonce: string): string { return `gateCreate:${actor.workspaceId}:${actor.id}:${kind}:${clientNonce}`; }
function replay<T>(services: BackendServices, actor: Principal, kind: string, input: { clientNonce?: string }, digest: string): T | null {
  if (!input.clientNonce) return null;
  const receipt = services.store.metadata<{ digest: string; collection: string; id: string }>(nonceKey(actor, kind, input.clientNonce));
  if (!receipt) return null;
  if (receipt.digest !== digest) fail('nonce_conflict', 'Nonce belongs to a different request.');
  return services.store.require<T>(receipt.collection, receipt.id);
}
function recordCreate(services: BackendServices, actor: Principal, kind: string, input: { clientNonce?: string }, digest: string, name: string, resourceId: string): void {
  if (input.clientNonce) services.store.setMetadata(nonceKey(actor, kind, input.clientNonce), { digest, collection: name, id: resourceId });
}

const lifecycle = new WeakMap<BackendServices, { cancelBot(botId: string, expected: BotGateResourceScope[]): void; cancelGate(name: Collection, id: string): void; cancelConversation(id: string): void; acknowledge(event: unknown): boolean }>();
/** Call before removing a conversation's entries; possibly-sent drafts are never discarded. */
export function cancelConversationGates(services: BackendServices, conversationId: string): void {
  const hooks = lifecycle.get(services);
  if (!hooks) fail('internal_error', 'Gate lifecycle is not initialized.', false);
  hooks.cancelConversation(conversationId);
}
/** Applies only an exact execution source event without redispatching a mutation. */
export function acknowledgeExecutionApproval(services: BackendServices, event: unknown): boolean {
  return lifecycle.get(services)?.acknowledge(event) ?? false;
}
/** Cancels only a tracked MCP gate; it cannot recall an already submitted external mutation. */
export function cancelGate(services: BackendServices, name: string, resourceId: string): void {
  const hooks = lifecycle.get(services);
  if (!hooks) fail('internal_error', 'Gate lifecycle is not initialized.', false);
  hooks.cancelGate(collection(name), resourceId);
}
/** The caller must bind this exact opaque candidate snapshot in the confirmed Bot deletion scope. */
export function cancelBotResources(services: BackendServices, botId: string, expected: BotGateResourceScope[]): void {
  const hooks = lifecycle.get(services);
  if (!hooks) fail('internal_error', 'Gate lifecycle is not initialized.', false);
  hooks.cancelBot(botId, expected);
}

/** Durable lifecycle: shutdown cancels pending input, fences in-flight writes, and never grants permission. */
export function createGateService(services: BackendServices): GateService & { sweep(): void; close(): void } {
  const waiters = new Map<string, Set<(resource: GateResource) => void>>();
  let timer: NodeJS.Timeout | undefined;
  let closed = false;
  function wake(name: Collection, resource: GateResource): void {
    if (resource.gate.state === 'pending' || resource.gate.state === 'submitted') return;
    const key = `${name}:${resource.id}`;
    const listeners = waiters.get(key);
    waiters.delete(key);
    for (const listener of listeners ?? []) listener(resource);
  }
  function sweep(): void {
    services.store.transaction(() => {
      for (const name of collections) for (const resource of services.store.list<GateResource>(name)) {
        if (resource.gate.state === 'pending' && services.now() >= resource.gate.expiresAtMs) wake(name, transition(services, name, resource, 'expired', null));
      }
    });
    schedule();
  }
  function schedule(): void {
    clearTimeout(timer);
    timer = undefined;
    if (closed) return;
    let deadline = Infinity;
    for (const name of collections) for (const resource of services.store.list<GateResource>(name)) if (resource.gate.state === 'pending') deadline = Math.min(deadline, resource.gate.expiresAtMs);
    if (Number.isFinite(deadline)) { timer = setTimeout(sweep, Math.max(1, deadline - services.now())); timer.unref(); }
  }
  // An in-flight write/send cannot be replayed after a process restart.
  services.store.transaction(() => {
    for (const name of collections) for (const resource of services.store.list<GateResource>(name)) if (resource.gate.state === 'submitted') transition(services, name, resource, 'outcome_unknown', resource.gate.resolvedByUserId);
    for (const draft of services.store.list<P.Draft>('drafts')) if (draft.state === 'sending') persistDraft(services, services.update(draft, { state: 'outcome_unknown', error: 'Send acknowledgment was lost. Inspect the provider before another send.' }));
  });
  sweep();
  const hooks = {
    cancelBot(botId: string, expected: BotGateResourceScope[]): void {
      services.store.transaction(() => {
        const current = previewBotResources(services, botId);
        if (services.mutations.digest(current) !== services.mutations.digest(expected)) fail('revision_conflict', 'Bot gate deletion scope changed; repeat the preview.');
        if (current.some(item => item.state === 'submitted' || item.state === 'sending' || item.state === 'outcome_unknown')) fail('outcome_unknown', 'Resolve uncertain gate or send outcomes before deleting this bot.', false, { resourceIds: current.filter(item => item.state === 'submitted' || item.state === 'sending' || item.state === 'outcome_unknown').map(item => item.id) });
        for (const item of current) {
          const entry = services.store.require<P.TranscriptEntry>('entries', item.entryId);
          if (item.collection === 'drafts') {
            const draft = services.store.require<P.Draft>('drafts', item.id);
            if (draft.state === 'editable') persistDraft(services, services.update(draft, { state: 'discarded' }));
            services.store.setMetadata(`draftUnsent:${item.id}`, null);
          } else {
            const resource = services.store.require<GateResource>(item.collection, item.id);
            if (resource.gate.state === 'pending') wake(item.collection, transition(services, item.collection, resource, 'cancelled', null));
            if (item.collection === 'approvals') {
              services.store.remove('approvalSources', item.id);
              services.store.setMetadata(`approvalDecision:${item.id}`, null);
            }
          }
          services.store.remove(item.collection, item.id);
          services.store.remove('entries', item.entryId);
          services.events.emit('entry.deleted', { id: entry.id, conversationId: entry.conversationId }, { conversationId: entry.conversationId });
        }
      });
      schedule();
    },
    cancelGate(name: Collection, resourceId: string): void {
      services.store.transaction(() => {
        const resource = services.store.require<GateResource>(name, resourceId);
        if (resource.gate.state === 'pending') wake(name, transition(services, name, resource, 'cancelled', null));
      });
      schedule();
    },
    cancelConversation(conversationId: string): void {
      services.store.transaction(() => {
        for (const name of collections) for (const resource of services.store.list<GateResource>(name)) if (conversationOf(services, resource) === conversationId && resource.gate.state === 'pending') wake(name, transition(services, name, resource, 'cancelled', null));
        for (const draft of services.store.list<P.Draft>('drafts')) if (draft.conversationId === conversationId && draft.state === 'editable') persistDraft(services, services.update(draft, { state: 'discarded' }));
      });
      schedule();
    },
    acknowledge(event: unknown): boolean {
      const parsed = z.object({ approvalId: id, runId: id, sessionKey: boundedText(1024, 1), decision: z.string() }).passthrough().safeParse(event);
      if (!parsed.success) return false;
      const source = services.store.list<ApprovalSource & { id: string }>('approvalSources', item => item.approvalId === parsed.data.approvalId && item.runId === parsed.data.runId && item.sessionKey === parsed.data.sessionKey)[0];
      if (!source) return false;
      const resource = services.store.get<P.Approval>('approvals', source.id);
      if (!resource || !['pending', 'submitted', 'outcome_unknown'].includes(resource.gate.state)) return false;
      const decision = parsed.data.decision;
      // The bound RPC receipt owns an affirmative transition; an unsolicited grant is not product consent.
      if (resource.gate.state === 'submitted' && decision === 'approve_once') return false;
      const attempt = services.store.metadata<{ decision: string; userId: string }>(`approvalDecision:${resource.id}`);
      const affirmed = resource.gate.state === 'outcome_unknown' && decision === 'approve_once' && attempt?.decision === 'approve_once' && attempt.userId === resource.gate.targetUserId;
      const state: P.ResolutionState = affirmed ? 'approved' : decision === 'deny' ? 'denied' : decision === 'expired' ? 'expired' : 'cancelled';
      services.store.transaction(() => wake('approvals', transition(services, 'approvals', resource, state, affirmed ? attempt?.userId ?? null : null)));
      schedule();
      return true;
    },
  };
  lifecycle.set(services, hooks);
  const unsubscribe = services.lemon.onEvent((name, event) => { if (name === 'exec.approval.resolved') hooks.acknowledge(event); });
  return {
    sweep,
    close() {
      closed = true;
      clearTimeout(timer);
      unsubscribe();
      if (lifecycle.get(services) === hooks) lifecycle.delete(services);
      services.store.transaction(() => {
        for (const name of collections) for (const resource of services.store.list<GateResource>(name)) if (resource.gate.state === 'pending' || resource.gate.state === 'submitted') wake(name, transition(services, name, resource, resource.gate.state === 'pending' ? 'cancelled' : 'outcome_unknown', null));
      });
      waiters.clear();
    },
    async create<T>(actor: Principal, kind: keyof typeof collectionFor, raw: unknown): Promise<T> {
      if (closed) fail('upstream_unavailable', 'Gate service is closed.');
      if (!(kind in collectionFor)) fail('invalid_request', 'Unsupported gate kind.');
      const input = kind === 'approval' ? parse(approvalInput, raw) : kind === 'question' ? parse(questionInput, raw) : kind === 'human_step' ? parse(humanInput, raw) : parse(secretInput, raw);
      creationOwner(services, actor, input);
      const digest = services.mutations.digest(input);
      const previous = replay<T>(services, actor, kind, input, digest);
      if (previous) return previous;
      const policy = kind === 'approval' ? await services.integrations.effectivePolicy(actor, input.botId) : null;
      return services.store.transaction(() => {
        creationOwner(services, actor, input);
        const previous = replay<T>(services, actor, kind, input, digest);
        if (previous) return previous;
        const name = collectionFor[kind];
        const { bot, conversation, target } = context(services, actor, input, kind !== 'question');
        const expiresAtMs = services.now() + (input.expiresInMs ?? MAX_WAIT);
        const gate: P.Gate = { id: services.id('gate'), revision: 1, state: 'pending', targetUserId: target.userId, expiresAtMs, resolvedAtMs: null, resolvedByUserId: null };
        const entryId = services.id('entry');
        let resource: GateResource;
        if ('category' in input) {
          if (!policy?.productAccess || (['shell', 'files'].includes(input.category) && policy.localExecutionCeiling === 'deny')) fail('policy_denied', 'Effective policy prohibits this action.');
          const rules = policy.rules.filter(rule => rule.category === input.category && (rule.botId === null || rule.botId === bot.id) && (rule.machineId === null || rule.machineId === bot.machineId));
          const ask = input.forceHuman === true || rules.some(rule => rule.mode === 'ask_first') || (['shell', 'files'].includes(input.category) && policy.localExecutionCeiling === 'ask');
          const selected = rules.find(rule => rule.mode === 'ask_first') ?? rules.find(rule => rule.mode === 'auto_review') ?? rules.find(rule => rule.mode === 'allow');
          const mode = ask ? 'ask_first' : selected?.mode ?? 'ask_first';
          const machine = services.store.require<P.Machine>('machines', bot.machineId);
          const source = input.source ?? 'product';
          if ((source === 'lemon_exec') !== (input.upstream !== undefined)) fail('invalid_request', 'Execution approval requires its exact source binding.');
          if (input.upstream && (!input.runId || services.runtime.sessionKey(services.store.require<P.Conversation>('conversations', input.conversationId), bot) !== input.upstream.sessionKey || input.upstream.nodeId !== undefined && input.upstream.nodeId !== machine.nodeId)) fail('forbidden', 'Execution approval placement does not match.');
          const scope: P.ReviewScope = { kind: 'once', label: 'Allow once', machineId: machine.id, machineLabel: machine.name, botId: bot.id, runId: input.runId ?? null, origin: null, connectorId: null, consequences: [input.description], expiresAtMs };
          resource = services.resource('approval', { gate, entryId, conversationId: conversation.id, botId: bot.id, runId: input.runId ?? null, source, category: input.category, title: input.title, description: input.description, target: input.target, inputs: input.inputs, policyMode: mode, review: mode === 'auto_review' ? 'ask' as const : 'not_run' as const, ruleId: selected?.id ?? null, scope });
          if (input.upstream) services.store.put('approvalSources', { id: resource.id, ...input.upstream });
          // Auto review has no configured reviewer in this interface: fall back to human, never invent a verdict.
          if (source === 'product' && mode === 'allow' && !['external_message', 'purchase', 'permissions'].includes(input.category)) resource = { ...resource, gate: { ...gate, state: 'approved', resolvedAtMs: services.now() } };
        } else if ('fields' in input) {
          validateFields(input.fields);
          resource = services.resource('question', { gate, entryId, conversationId: conversation.id, botId: bot.id, title: input.title, fields: input.fields, answers: null });
        } else if ('instructions' in input) {
          resource = services.resource('human_step', { gate, entryId, conversationId: conversation.id, botId: bot.id, machineId: bot.machineId, title: input.title, instructions: input.instructions, reason: input.reason, externalUrl: input.externalUrl ?? null });
        } else {
          resource = services.resource('secret_request', { gate, entryId, botId: bot.id, machineId: bot.machineId, name: input.name, description: input.description, scope: input.scope });
        }
        services.store.put(name, resource);
        const entry = services.entry(target, conversation.id, { id: entryId, kind: 'card', card: cardFor(name, resource), actor: { kind: 'bot', id: bot.id, displayName: bot.name }, targetedUserId: target.userId, runId: input.runId ?? null });
        if (entry.id !== entryId) fail('internal_error', 'Entry ID reservation was not honored.', false);
        emitGate(services, name, resource);
        recordCreate(services, actor, kind, input, digest, name, resource.id);
        schedule();
        return resource as T;
      });
    },
    async resolve<T>(actor: Principal, rawCollection: string, resourceId: string, raw: unknown): Promise<T> {
      const name = collection(rawCollection);
      const input = name === 'approvals' ? parse(approvalResolve, raw) : name === 'questions' ? parse(questionResolve, raw) : name === 'humanSteps' ? parse(humanResolve, raw) : parse(secretResolve, raw);
      sweep();
      if (name === 'approvals' && input.decision === 'approve_once') {
        const proposal = services.store.require<P.Approval>('approvals', resourceId);
        pending(services, actor, name, proposal, input.revision);
        const policy = await services.integrations.effectivePolicy(actor, proposal.botId);
        if (!policy.productAccess || (['shell', 'files'].includes(proposal.category) && policy.localExecutionCeiling === 'deny')) fail('policy_denied', 'Effective policy now prohibits this action.');
      }
      let destination: P.Machine | null = null;
      let upstream: ApprovalSource | null = null;
      const resource = services.store.transaction(() => {
        const current = services.store.require<GateResource>(name, resourceId);
        pending(services, actor, name, current, input.revision);
        let state: P.ResolutionState;
        let changes: Partial<GateResource> = {};
        if (name === 'approvals') {
          const approval = current as P.Approval;
          state = input.decision === 'approve_once' ? 'approved' : 'denied';
          if (approval.source === 'lemon_exec') {
            upstream = services.store.require<ApprovalSource>('approvalSources', approval.id);
            if (!services.lemon.connected) fail('upstream_unavailable', 'Controller is unavailable.');
            state = 'submitted';
            services.store.setMetadata(`approvalDecision:${approval.id}`, { decision: input.decision, userId: actor.userId });
          }
        } else if (name === 'questions') {
          state = input.decision === 'answer' ? 'completed' : 'declined';
          if ('answers' in input && input.answers) { validateAnswers(current as P.Question, input.answers); changes = { answers: input.answers }; }
        } else if (name === 'humanSteps') state = input.decision === 'done' ? 'completed' : 'declined';
        else {
          state = input.decision === 'save' ? 'submitted' : 'declined';
          if (state === 'submitted') {
            const request = current as P.SecretRequest;
            destination = services.auth.machine(actor, request.machineId, true);
            if (destination.status !== 'online' || !destination.nodeId) fail('machine_offline', 'Destination is offline.');
            if (!services.lemon.connected || !services.lemon.methods.includes('node.secrets.set')) fail('capability_unavailable', 'Destination secret storage is unavailable.');
          }
        }
        return transition(services, name, current, state, actor.userId, changes);
      });
      if (resource.gate.state !== 'submitted') { wake(name, resource); schedule(); return resource as T; }
      let finalState: P.ResolutionState;
      try {
        if (name === 'secretRequests' && 'value' in input && input.value && destination) {
          const request = resource as P.SecretRequest;
          const ack = await services.lemon.call<unknown>('node.secrets.set', { nodeId: (destination as P.Machine).nodeId, name: request.name, value: input.value }, { mutation: true, resourceIds: [resource.id] });
          const result = z.object({ name: z.string(), set: z.literal(true) }).passthrough().safeParse(ack);
          finalState = result.success && result.data.name === request.name ? 'completed' : 'outcome_unknown';
        } else if (name === 'approvals' && upstream) {
          const source = upstream as ApprovalSource;
          const ack = await services.lemon.call<unknown>('exec.approval.resolve', { approvalId: source.approvalId, decision: input.decision, expectedSessionKey: source.sessionKey, expectedRunId: source.runId }, { mutation: true, resourceIds: [resource.id] });
          const result = z.object({ resolved: z.literal(true), approvalId: z.string(), decision: z.string(), sessionKey: z.string(), runId: z.string(), approved: z.boolean(), outcome: z.enum(['approved', 'denied']) }).passthrough().safeParse(ack);
          finalState = result.success && result.data.approvalId === source.approvalId && result.data.sessionKey === source.sessionKey && result.data.runId === source.runId && result.data.decision === input.decision && result.data.approved === (input.decision === 'approve_once') && result.data.outcome === (input.decision === 'approve_once' ? 'approved' : 'denied') ? input.decision === 'approve_once' ? 'approved' : 'denied' : 'outcome_unknown';
        } else finalState = 'outcome_unknown';
      } catch (error) { finalState = error instanceof ApiError && error.retrySafe && error.code !== 'outcome_unknown' ? 'failed' : 'outcome_unknown'; }
      const resolved = services.store.transaction(() => {
        const current = services.store.require<GateResource>(name, resourceId);
        return current.gate.state === 'submitted' ? transition(services, name, current, finalState, actor.userId) : current;
      });
      wake(name, resolved);
      schedule();
      return resolved as T;
    },
    async wait<T>(rawCollection: string, resourceId: string): Promise<T> {
      const name = collection(rawCollection);
      sweep();
      const resource = services.store.require<GateResource>(name, resourceId);
      if (resource.gate.state !== 'pending' && resource.gate.state !== 'submitted') return resource as T;
      if (closed) fail('upstream_unavailable', 'Gate service is closed.');
      const { promise, resolve } = Promise.withResolvers<T>();
      const key = `${name}:${resourceId}`;
      let listeners = waiters.get(key);
      if (!listeners) { listeners = new Set(); waiters.set(key, listeners); }
      listeners.add(value => resolve(value as T));
      return promise;
    },
    cancelUser(userId: string): void {
      services.store.transaction(() => {
        for (const name of collections) for (const resource of services.store.list<GateResource>(name)) if (resource.gate.targetUserId === userId && resource.gate.state === 'pending') wake(name, transition(services, name, resource, 'cancelled', null));
      });
      schedule();
    },
  };
}

function draftCard(draft: P.Draft): P.Card { return { type: draft.content.kind === 'email' ? 'email_draft' : draft.content.kind === 'slack' ? 'slack_draft' : 'message_draft', draft }; }
function persistDraft(services: BackendServices, draft: P.Draft): P.Draft {
  services.store.put('drafts', draft);
  const entry = services.store.require<P.TranscriptEntry>('entries', draft.entryId);
  if (entry.kind !== 'card') fail('internal_error', 'Draft transcript is unavailable.', false);
  const updatedEntry = services.update(entry, { card: draftCard(draft) });
  services.store.put('entries', updatedEntry);
  const audience = { userIds: [draft.ownerUserId], conversationId: draft.conversationId };
  services.events.emit('draft.upserted', draft, audience);
  services.events.emit('entry.upserted', updatedEntry, audience);
  return draft;
}
function contentAccess(services: BackendServices, actor: Principal, botId: string, content: P.DraftContent): void {
  ownedBot(services, actor, botId);
  for (const attachmentId of content.attachmentIds) {
    const attachment = services.auth.attachment(actor, attachmentId);
    if (attachment.state !== 'ready') fail('invalid_request', 'Draft attachment is not ready.');
  }
  if (content.kind === 'message') {
    const channel = services.store.require<P.ChannelBinding>('channelBindings', content.channelBindingId);
    if (channel.botId !== botId || channel.ownerUserId !== actor.userId || !channel.enabled) fail('forbidden', 'Channel is not authorized for this draft.');
  } else {
    const connector = services.store.require<P.Connector>('connectors', content.connectorId);
    if (connector.botId !== botId || connector.ownerUserId !== actor.userId) fail('forbidden', 'Connector is not authorized for this draft.');
  }
}
/** MCP creates an editable draft only. No provider dispatch occurs until the owner explicitly sends. */
export async function createDraft(services: BackendServices, actor: Principal, raw: unknown): Promise<P.Draft> {
  const input = parse(draftInput, raw);
  creationOwner(services, actor, input);
  const digest = services.mutations.digest(input);
  return services.store.transaction(() => {
    const previous = replay<P.Draft>(services, actor, 'draft', input, digest);
    if (previous) return previous;
    const { bot, conversation, target } = context(services, actor, input, true);
    contentAccess(services, target, bot.id, input.content);
    const draft: P.Draft = services.resource('draft', { entryId: services.id('entry'), conversationId: conversation.id, botId: bot.id, ownerUserId: target.userId, content: input.content, state: 'editable', sendRunId: null, providerMessageId: null, error: null });
    services.store.put('drafts', draft);
    const entry = services.entry(target, conversation.id, { id: draft.entryId, kind: 'card', card: draftCard(draft), actor: { kind: 'bot', id: bot.id, displayName: bot.name }, targetedUserId: target.userId, runId: input.runId ?? null });
    if (entry.id !== draft.entryId) fail('internal_error', 'Entry ID reservation was not honored.', false);
    services.events.emit('draft.upserted', draft, { userIds: [target.userId], conversationId: conversation.id });
    recordCreate(services, actor, 'draft', input, digest, 'drafts', draft.id);
    return draft;
  });
}
function ownDraft(services: BackendServices, actor: Principal, resourceId: string): P.Draft {
  const draft = services.store.require<P.Draft>('drafts', resourceId);
  const bot = services.store.get<P.Bot>('bots', draft.botId);
  if (actor.kind !== 'user' || !bot || actor.userId !== bot.ownerUserId || draft.ownerUserId !== bot.ownerUserId) fail('not_found', 'Draft not found.');
  const room = services.auth.conversation(actor, draft.conversationId);
  if (!ownsRoom(services, bot.ownerUserId, bot.id, room)) fail('not_found', 'Draft not found.');
  return draft;
}
function editable(services: BackendServices, draft: P.Draft, revision: number, allowConfirmedUnsent = false): void {
  services.mutations.checkRevision(draft, revision);
  const proof = services.store.metadata<{ revision: number }>(`draftUnsent:${draft.id}`);
  if (draft.state !== 'editable' && !(allowConfirmedUnsent && draft.state === 'failed' && proof?.revision === draft.revision)) fail(draft.state === 'outcome_unknown' || draft.state === 'sending' ? 'outcome_unknown' : 'conflict', 'Draft is no longer editable. A possibly-sent draft cannot be resent or discarded.', false, { resourceIds: [draft.id] });
}
export function createGateRoutes(services: BackendServices): Route[] {
  const routes: Route[] = [];
  for (const [path, name] of [['approvals', 'approvals'], ['questions', 'questions'], ['human-steps', 'humanSteps'], ['secret-requests', 'secretRequests']] as const) {
    routes.push({ method: 'GET', path: `/v1/${path}/:id`, auth: 'member', status: 200, handler(context) {
      const actor = principal(context.user);
      const resource = services.store.require<GateResource>(name, context.params.id);
      visible(services, actor, name, resource);
      return resource;
    } });
    routes.push({ method: 'POST', path: `/v1/${path}/:id/resolve`, auth: 'member', status: 200, handler(context) { return services.gates.resolve(principal(context.user), name, context.params.id, context.body); } });
  }
  for (const name of ['approvals', 'questions'] as const) routes.push({ method: 'GET', path: `/v1/${name}`, auth: 'member', status: 200, handler(context) {
    const actor = principal(context.user);
    const schema = z.object({ cursor: z.string().optional(), limit: z.coerce.number().int().min(1).max(200).optional(), state: states.optional(), ...(name === 'approvals' ? { botId: id.optional() } : {}) }).strict();
    const filter = parse(schema, queryObject(context.query));
    return services.page(context, services.store.list<GateResource>(name, value => ownsGate(services, actor, value) && services.auth.canRead(actor, name, value) && (!filter.state || value.gate.state === filter.state) && (!('botId' in filter) || !filter.botId || value.botId === filter.botId)));
  } });
  routes.push({ method: 'GET', path: '/v1/drafts', auth: 'member', status: 200, handler(context) {
    const actor = principal(context.user);
    const filter = parse(z.object({ cursor: z.string().optional(), limit: z.coerce.number().int().min(1).max(200).optional(), conversationId: id.optional(), state: z.enum(['editable', 'sending', 'sent', 'discarded', 'failed', 'outcome_unknown']).optional() }).strict(), queryObject(context.query));
    return services.page(context, services.store.list<P.Draft>('drafts', draft => draft.ownerUserId === actor.userId && services.store.get<P.Bot>('bots', draft.botId)?.ownerUserId === actor.userId && ownsRoom(services, actor.userId, draft.botId, services.store.get<P.Conversation>('conversations', draft.conversationId)) && services.auth.canRead(actor, 'drafts', draft) && (!filter.state || draft.state === filter.state) && (!filter.conversationId || draft.conversationId === filter.conversationId)));
  } });
  routes.push({ method: 'GET', path: '/v1/drafts/:id', auth: 'member', status: 200, handler(context) { return ownDraft(services, principal(context.user), context.params.id); } });
  routes.push({ method: 'PATCH', path: '/v1/drafts/:id', auth: 'member', status: 200, handler(context) {
    const actor = principal(context.user);
    const input = parse(draftEdit, context.body);
    return services.store.transaction(() => {
      const draft = ownDraft(services, actor, context.params.id);
      editable(services, draft, input.revision, true);
      contentAccess(services, actor, draft.botId, input.content);
      return persistDraft(services, services.update(draft, { content: input.content, state: 'editable', error: null }));
    });
  } });
  routes.push({ method: 'POST', path: '/v1/drafts/:id/discard', auth: 'member', status: 200, handler(context) {
    const actor = principal(context.user);
    const input = parse(update, context.body);
    return services.store.transaction(() => { const draft = ownDraft(services, actor, context.params.id); editable(services, draft, input.revision); return persistDraft(services, services.update(draft, { state: 'discarded' })); });
  } });
  routes.push({ method: 'POST', path: '/v1/drafts/:id/send', auth: 'member', status: 200, async handler(context: RequestContext) {
    const actor = principal(context.user);
    const input = parse(draftEdit, context.body);
    const frozen = services.store.transaction(() => {
      const draft = ownDraft(services, actor, context.params.id);
      editable(services, draft, input.revision);
      contentAccess(services, actor, draft.botId, input.content);
      context.nonceResourceIds.push(draft.id);
      return persistDraft(services, services.update(draft, { content: input.content, state: 'sending', error: null }));
    });
    let changes: Partial<P.Draft>;
    try {
      const receipt = await services.integrations.sendApprovedDraft(actor, frozen);
      const parsed = z.object({ providerMessageId: id.nullable(), runId: id.nullable() }).strict().safeParse(receipt);
      if (!parsed.success || !parsed.data.providerMessageId) changes = { state: 'outcome_unknown', sendRunId: parsed.success ? parsed.data.runId : null, error: 'Delivery is not confirmed. Inspect the provider before another send.' };
      else changes = { state: 'sent', providerMessageId: parsed.data.providerMessageId, sendRunId: parsed.data.runId, error: null };
    } catch (error) {
      const knownUnsent = error instanceof ApiError && error.retrySafe && error.code !== 'outcome_unknown';
      changes = { state: knownUnsent ? 'failed' : 'outcome_unknown', error: knownUnsent ? 'Provider rejected the send before delivery.' : 'Delivery is not confirmed. Inspect the provider before another send.' };
    }
    return services.store.transaction(() => {
      const current = services.store.require<P.Draft>('drafts', frozen.id);
      if (current.state !== 'sending') return current;
      const result = persistDraft(services, services.update(current, changes));
      if (result.state === 'failed') services.store.setMetadata(`draftUnsent:${result.id}`, { revision: result.revision });
      return result;
    });
  } });
  return routes;
}
