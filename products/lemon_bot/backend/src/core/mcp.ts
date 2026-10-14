import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from './services';
import { ApiError, errorEnvelope, fail } from './errors';
import { z, parse, principal, id, mutation, update, voice, boundedText } from './validation';
import { authorizedBot, authorizedConversation, authorizedEntry, createConversation, fenceContext, privateConversation, recentRoomContext, sendMessage, validateAttachments, type EntryAuthority } from './conversations';
import { cancelGate, createDraft } from './gates';
import { importMachineFile } from '../runtime/machines';
import { observeInvocation, type InvocationProofBinding, type InvocationContext, type RuntimeMapping } from '../runtime/runs';
import { effectiveBotGrants } from './experiences';

const text = boundedText(65536);
const files = z.array(id).max(6);
const contextSchema = mutation.extend({ conversationId: id.optional() });
const deadline = { expiresInMs: z.number().int().min(1000).max(600000).optional() };
const jsonValue: z.ZodType<P.JSONValue> = z.lazy(() => z.union([z.null(), z.boolean(), z.number().finite(), z.string(), z.array(jsonValue), z.record(z.string(), jsonValue)]));
const jsonObject = z.record(z.string(), jsonValue);
const fields = z.array(z.object({ id: boundedText(128, 1), label: boundedText(1024, 1), kind: z.enum(['text', 'multiline', 'number', 'boolean', 'single_select', 'multi_select']), required: z.boolean(), options: z.array(z.object({ value: boundedText(1024, 1), label: boundedText(1024, 1) }).strict()).min(1).max(100).optional(), min: z.number().finite().optional(), max: z.number().finite().optional() }).strict()).min(1).max(32);
const draftContent = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('email'), connectorId: id, from: boundedText(320, 1), to: z.array(boundedText(320, 1)).min(1).max(50), cc: z.array(boundedText(320, 1)).max(50), bcc: z.array(boundedText(320, 1)).max(50), subject: boundedText(1024), body: text, attachmentIds: files }).strict(),
  z.object({ kind: z.literal('slack'), connectorId: id, workspace: id, target: boundedText(512, 1), thread: boundedText(512).nullable(), body: text, attachmentIds: files }).strict(),
  z.object({ kind: z.literal('message'), channelBindingId: id, target: boundedText(512, 1), thread: boundedText(512).nullable(), body: text, attachmentIds: files }).strict(),
]);
const trigger = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('schedule'), cron: boundedText(256, 1), timezone: boundedText(128, 1) }).strict(),
  z.object({ kind: z.literal('webhook') }).strict(),
  z.object({ kind: z.literal('channel_event'), channelBindingId: id, event: z.enum(['mention', 'message', 'reaction', 'email_received']), channel: boundedText(512).optional(), phrase: boundedText(4096).optional(), reaction: boundedText(64).optional(), senders: z.array(boundedText(320)).max(100).optional(), noisyListenerConsent: z.boolean().optional() }).strict(),
  z.object({ kind: z.literal('external_event'), source: z.enum(['github', 'linear', 'sentry', 'pagerduty']), eventNames: z.array(boundedText(128, 1)).min(1).max(100), filters: jsonObject }).strict(),
]);
const botMessage = contextSchema.extend({ targetBotId: id, text, attachmentIds: files.optional(), replyConversationId: id.optional() });
const schemas: { [K in keyof P.MCPToolInputs]: z.ZodType<P.MCPToolInputs[K]> } = {
  message_bot: botMessage,
  handoff: botMessage.extend({ task: boundedText(4096, 1) }),
  create_draft: contextSchema.extend({ content: draftContent }),
  ask_user: contextSchema.extend({ title: boundedText(512, 1), fields, ...deadline }),
  request_approval: contextSchema.extend({ category: z.enum(['shell', 'files', 'external_message', 'calendar', 'publish', 'purchase', 'permissions', 'connector', 'handoff']), title: boundedText(512, 1), description: boundedText(8192, 1), target: boundedText(1024, 1), inputs: jsonObject, ...deadline }),
  request_human_step: contextSchema.extend({ title: boundedText(512, 1), instructions: boundedText(8192, 1), reason: z.enum(['login', 'mfa', 'captcha', 'payment', 'identity', 'other']), externalUrl: z.url().max(4096).optional(), ...deadline }),
  request_secret: contextSchema.extend({ name: z.string().min(1).max(256).regex(/^[A-Za-z0-9][A-Za-z0-9_.-]*$/), description: boundedText(4096), scope: z.enum(['machine', 'bot']), ...deadline }),
  send_voice_memo: contextSchema.extend({ text: boundedText(16384, 1), voice: voice.optional() }),
  share_file: contextSchema.extend({ path: boundedText(4096, 1), filename: boundedText(255, 1).optional(), caption: boundedText(4096).optional() }),
  create_routine: mutation.extend({ name: boundedText(120, 1), instruction: boundedText(32768, 1), trigger, enabled: z.boolean() }),
  update_routine: update.extend({ routineId: id, name: boundedText(120, 1).optional(), instruction: boundedText(32768, 1).optional(), trigger: trigger.optional(), enabled: z.boolean().optional() }),
  save_skill: mutation.extend({ name: boundedText(120, 1), description: boundedText(4096, 1), markdown: boundedText(262144, 1), scope: z.enum(['personal', 'team']) }),
  list_bots: z.object({ query: boundedText(512).optional(), limit: z.number().int().min(1).max(200).optional(), cursor: boundedText(4096, 1).optional() }).strict(),
  post_to_group: mutation.extend({ groupConversationId: id, text, attachmentIds: files.optional(), mentions: z.array(id).max(64).optional() }),
  remember: contextSchema.extend({ text: boundedText(32768, 1), kind: z.enum(['fact', 'preference', 'instruction', 'summary']), scope: z.enum(['personal', 'team', 'private_note']) }),
  create_bot: mutation.extend({ name: boundedText(120, 1), machineId: id, title: boundedText(140).optional(), job: boundedText(32768).optional(), instructions: boundedText(32768).optional(), avatar: z.object({ kind: z.enum(['character', 'image']), shape: boundedText(64, 1), color: boundedText(64, 1), attachmentId: id.nullable() }).strict().optional(), voice: voice.optional(), language: boundedText(64, 2).nullable().optional(), visibility: z.enum(['personal', 'team']).optional(), skillIds: z.array(id).max(100).optional(), templateId: id.optional() }),
  update_preferences: contextSchema.extend({ revision: z.number().int().positive(), changes: z.object({ job: boundedText(32768).optional(), instructions: boundedText(32768).optional(), voice: voice.optional(), language: boundedText(64, 2).nullable().optional() }).strict(), reason: boundedText(4096, 1), sourceEntryId: id }),
  create_reminder: contextSchema.extend({ text: boundedText(4096, 1), dueAtMs: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER), timezone: boundedText(128, 1) }),
};
const descriptions: Record<keyof P.MCPToolInputs, string> = {
  message_bot: 'Send an asynchronous specialist job under the current user authority.', handoff: 'Delegate a task and return results to the original authorized conversation.', create_draft: 'Prepare an editable private draft; does not send it.', ask_user: 'Ask non-secret structured questions and wait for explicit answers.', request_approval: 'Request permission for one exact proposal; does not execute it.', request_human_step: 'Ask the user to complete a step on the assigned machine.', request_secret: 'Request write-only destination secret storage; never returns its value.', send_voice_memo: 'Generate a real voice memo using configured speech.', share_file: 'Import an authorized destination-local file and share it.', create_routine: 'Persist a routine owned by the initiating user.', update_routine: 'Update an owned routine with revision fencing.', save_skill: 'Write a skill to the caller bot machine.', list_bots: 'List only bots visible to the authorized initiating user.', post_to_group: 'Post as this bot; only explicit mentions wake peers.', remember: 'Store a scoped fact or preference through the owning service.', create_bot: 'Create a helper only after explicit human approval.', update_preferences: 'Change durable preferences from explicit authorized user intent.', create_reminder: 'Persist a reminder owned by the initiating user.',
};

export interface ToolInvocation { principal: Principal; bot: P.Bot; run: P.Run; conversation: P.Conversation }
/** Bot bearer identity is not human authority. Only a durable live product run supplies that authority. */
export function resolveToolInvocation(services: BackendServices, token: Principal, request: Request, conversationId?: string, allowTerminal = false): ToolInvocation {
  if (token.kind !== 'bot' || !token.botId) fail('unauthenticated', 'Bot tools require a bot bearer token.');
  const proofValue = request.headers.get('X-Lemon-Bot-Invocation');
  if (!proofValue || proofValue.length > 512) fail('forbidden', 'This tool request requires its authenticated invocation proof.');
  const binding = services.store.metadata<InvocationProofBinding>(`invocationProof:${services.mutations.digest(proofValue)}`);
  if (!binding || binding.botId !== token.botId || binding.principal.workspaceId !== token.workspaceId) fail('forbidden', 'Invocation authentication does not belong to this bot.');
  const run = services.store.require<P.Run>('runs', binding.runId);
  const snapshot = services.store.metadata<Principal>(`runPrincipal:${run.id}`);
  const mapping = services.store.metadata<RuntimeMapping>(`runtimeRun:${run.id}`);
  const execution = services.store.metadata<InvocationContext>(`runtimeInvocation:${binding.nativeRunId}`);
  if (!snapshot || snapshot.kind === 'bot' || run.botId !== token.botId || snapshot.userId !== run.initiatorUserId || snapshot.workspaceId !== token.workspaceId || binding.principal.kind !== snapshot.kind || binding.principal.id !== snapshot.id || binding.principal.userId !== snapshot.userId || binding.principal.workspaceId !== snapshot.workspaceId || !mapping || mapping.upstreamRunId !== binding.nativeRunId || mapping.botId !== run.botId || mapping.conversationId !== run.conversationId || mapping.nodeId !== binding.nodeId || !execution || execution.invocationContextKey !== binding.invocationContextKey || services.store.metadata<string>(`nativeRunProduct:${binding.nativeRunId}`) !== run.id) fail('forbidden', 'The proof is not bound to the retained native execution and initiating principal.');
  if (conversationId && conversationId !== run.conversationId) fail('forbidden', 'A tool context cannot select another invocation conversation.');
  const member = services.auth.member(snapshot.userId);
  if (!member.enabled) fail('forbidden', 'The initiating member is disabled.');
  const actor = { ...snapshot, role: member.role };
  const room = authorizedConversation(services, actor, run.conversationId);
  const bot = authorizedBot(services, actor, token.botId);
  const returnConversationId = services.store.metadata<string>(`runReturnConversation:${run.id}`);
  if (returnConversationId) authorizedConversation(services, actor, returnConversationId);
  const machine = services.store.require<P.Machine>('machines', bot.machineId);
  if (!room.botIds.includes(token.botId) || machine.nodeId !== binding.nodeId || mapping.profileId !== bot.profileId) fail('forbidden', 'The original bot membership or native placement is no longer authorized.');
  return { principal: actor, bot, run: allowTerminal ? run : observeInvocation(services, proofValue), conversation: room };
}
function boundJson(input: unknown): void {
  const pending = [{ value: input, depth: 0 }];
  let members = 0;
  while (pending.length) {
    const item = pending.pop()!;
    if (++members > 10000 || item.depth > 32) fail('too_large', 'Tool JSON exceeds its structural limits.');
    if (typeof item.value === 'object' && item.value !== null) for (const value of Object.values(item.value)) pending.push({ value, depth: item.depth + 1 });
  }
  if (new TextEncoder().encode(JSON.stringify(input)).length > 1048576) fail('too_large', 'Tool JSON exceeds 1 MiB.');
}
function recordGateWait(services: BackendServices, context: RequestContext, collection: string, gateId: string): void {
  if (!context.user || typeof context.body !== 'object' || context.body === null || !('clientNonce' in context.body) || typeof context.body.clientNonce !== 'string') fail('internal_error', 'Gate wait has no durable tool nonce.', false);
  const token = context.user;
  const invocation = resolveToolInvocation(services, token, context.request, undefined, true);
  services.store.setMetadata(`mcpGate:${token.id}:${invocation.run.id}:${context.route.path}:${context.body.clientNonce}`, { collection, id: gateId });
  context.nonceResourceIds.push(gateId);
}
async function boundedOperation<T>(operation: Promise<T>): Promise<T> {
  let cancelTimeout: (() => void) | undefined;
  try {
    return await Promise.race([operation, new Promise<never>((_, reject) => { const timer = setTimeout(() => reject(new ApiError('outcome_unknown', 'The operation did not acknowledge within 120 seconds; do not replay it.', false)), 120000); cancelTimeout = () => clearTimeout(timer); })]);
  } finally { cancelTimeout?.(); }
}
async function specialist(services: BackendServices, input: P.MessageBotInput | P.HandoffInput, invocation: ToolInvocation, context: RequestContext): Promise<P.MessageBotResult> {
  const { principal: actor, bot: source, run, conversation: origin } = invocation;
  if (services.store.metadata<boolean>(`runNoHandoff:${run.id}`) || source.id === input.targetBotId) fail('policy_denied', 'This invocation does not permit further handoffs.');
  const target = authorizedBot(services, actor, input.targetBotId);
  const originalReturn = services.store.metadata<string>(`runReturnConversation:${run.id}`) ?? origin.id;
  if (input.replyConversationId && input.replyConversationId !== originalReturn) fail('forbidden', 'A handoff cannot select a different output audience.');
  const returnRoom = authorizedConversation(services, actor, originalReturn);
  if (!returnRoom.botIds.includes(source.id)) fail('forbidden', 'The source bot must belong to the authorized return room.');
  if (origin.kind === 'channel' || returnRoom.kind === 'channel') {
    if (!services.integrations.assertChannelHandoff) fail('capability_unavailable', 'The channel has no configured handoff authority policy.');
    services.integrations.assertChannelHandoff(actor, origin, target, returnRoom.id);
  }
  validateAttachments(services, actor, origin, input.attachmentIds ?? []);
  if (origin.kind === 'group' && input.attachmentIds?.length) fail('invalid_request', 'Group handoffs are text-only; use direct authorized file sharing.');
  const sourceEntryId = services.store.metadata<string>(`runSourceEntry:${run.id}`);
  if (!sourceEntryId) fail('forbidden', 'The handoff has no verified original source entry.');
  authorizedEntry(services, actor, sourceEntryId);
  const parent = privateConversation(services, actor, target, input.clientNonce);
  const jobKey = `specialistJob:${run.id}:${input.clientNonce}`;
  const jobHash = services.mutations.digest(input);
  let job = services.store.metadata<{ hash: string; conversationId: string }>(jobKey);
  if (job && job.hash !== jobHash) fail('nonce_conflict', 'This handoff nonce belongs to another proposal.');
  if (!job) {
    const task = createConversation(services, actor, { clientNonce: input.clientNonce, kind: 'task', name: 'task' in input ? input.task.slice(0, 120) : `Message to ${target.name}`, botIds: [target.id], parentConversationId: parent.id });
    job = { hash: jobHash, conversationId: task.id }; services.store.setMetadata(jobKey, job);
    services.entry(actor, origin.id, { kind: 'event', actor: { kind: 'bot', id: source.id, displayName: source.name }, runId: run.id, clientNonce: input.clientNonce, event: { type: 'handoff', sourceBotId: source.id, targetBotId: target.id, targetConversationId: task.id, text: input.text } });
  }
  const task = authorizedConversation(services, actor, job.conversationId);
  const historyRoom = returnRoom.kind === 'group' || returnRoom.kind === 'channel' ? returnRoom : origin;
  const fenced = `Specialist job from ${source.name}; do not delegate again. Return only to the verified original conversation.\n${fenceContext(('task' in input ? input.task + '\n' : '') + input.text)}\nAuthorized destination transcript:\n${recentRoomContext(services, actor, historyRoom.id)}`;
  const receipt = await sendMessage(services, actor, task.id, { clientNonce: input.clientNonce, text: fenced, attachmentIds: input.attachmentIds }, context, undefined, { returnConversationId: returnRoom.id, sourceEntryId, noHandoff: true, parentRunId: run.id, sourceBotId: source.id, allowSourceAttachments: true, actor: { kind: 'bot', id: source.id, displayName: source.name } });
  return { receipt, conversationId: task.id };
}

type ToolHandlers = { [K in keyof P.MCPToolInputs]: (input: P.MCPToolInputs[K], invocation: ToolInvocation, context: RequestContext) => Promise<P.MCPToolResults[K]> };
function toolHandlers(services: BackendServices): ToolHandlers {
  return {
    message_bot: (input, invocation, context) => specialist(services, input, invocation, context),
    handoff: (input, invocation, context) => specialist(services, input, invocation, context),
    create_draft: async (input, invocation) => {
      validateAttachments(services, invocation.principal, invocation.conversation, input.content.attachmentIds);
      return createDraft(services, invocation.principal, { ...input, botId: invocation.bot.id, runId: invocation.run.id, targetUserId: invocation.principal.userId, conversationId: invocation.conversation.id });
    },
    ask_user: async (input, invocation, context) => {
      if (new Set(input.fields.map(field => field.id)).size !== input.fields.length) fail('invalid_request', 'Question field IDs must be distinct.');
      const question = await services.gates.create<P.Question>(invocation.principal, 'question', { ...input, botId: invocation.bot.id, runId: invocation.run.id, conversationId: invocation.conversation.id, targetUserId: invocation.principal.userId });
      recordGateWait(services, context, 'questions', question.id);
      const result = await services.gates.wait<P.Question>('questions', question.id);
      return { question: result, state: result.gate.state, answers: result.gate.state === 'completed' ? result.answers : null };
    },
    request_approval: async (input, invocation, context) => {
      const approval = await services.gates.create<P.Approval>(invocation.principal, 'approval', { ...input, botId: invocation.bot.id, runId: invocation.run.id, conversationId: invocation.conversation.id, targetUserId: invocation.principal.userId, source: 'product' });
      recordGateWait(services, context, 'approvals', approval.id);
      const result = await services.gates.wait<P.Approval>('approvals', approval.id);
      const decision = result.gate.state === 'approved' ? 'approved' : result.gate.state === 'expired' ? 'expired' : result.gate.state === 'cancelled' ? 'cancelled' : 'denied';
      return { approval: result, decision };
    },
    request_human_step: async (input, invocation, context) => {
      if (input.externalUrl && new URL(input.externalUrl).protocol !== 'https:') fail('invalid_request', 'Human-step links must use HTTPS.');
      const step = await services.gates.create<P.HumanStep>(invocation.principal, 'human_step', { ...input, botId: invocation.bot.id, runId: invocation.run.id, conversationId: invocation.conversation.id, targetUserId: invocation.principal.userId });
      recordGateWait(services, context, 'humanSteps', step.id);
      const result = await services.gates.wait<P.HumanStep>('humanSteps', step.id);
      return { step: result, decision: result.gate.state === 'completed' ? 'done' : result.gate.state === 'expired' ? 'expired' : result.gate.state === 'cancelled' ? 'cancelled' : 'skipped' };
    },
    request_secret: async (input, invocation, context) => {
      const request = await services.gates.create<P.SecretRequest>(invocation.principal, 'secret_request', { ...input, botId: invocation.bot.id, runId: invocation.run.id, conversationId: invocation.conversation.id, targetUserId: invocation.principal.userId });
      recordGateWait(services, context, 'secretRequests', request.id);
      const result = await services.gates.wait<P.SecretRequest>('secretRequests', request.id);
      return { request: result, name: result.name, saved: result.gate.state === 'completed' };
    },
    send_voice_memo: async (input, invocation, context) => {
      if (!services.integrations.speech) fail('capability_unavailable', 'Configure a real speech provider before sending a voice memo.');
      const sourceId = services.store.metadata<string>(`runSourceEntry:${invocation.run.id}`);
      const source = sourceId ? services.store.get<P.TranscriptEntry>('entries', sourceId) : null;
      const speech = await boundedOperation(services.integrations.speech(invocation.principal, { clientNonce: input.clientNonce, text: input.text, voice: input.voice ?? invocation.bot.voice, conversationId: invocation.conversation.id }, { botId: invocation.bot.id, runId: invocation.run.id, machineId: invocation.bot.machineId, sourceEntryId: source?.conversationId === invocation.conversation.id ? source.id : null, generatedAtMs: null }));
      context.nonceResourceIds.push(speech.attachment.id);
      if (speech.attachment.state !== 'ready' || !speech.attachment.mime.startsWith('audio/') || speech.attachment.durationMs === null) fail('upstream_unavailable', 'Speech provider did not return a ready measured audio file.', false);
      const entry = services.entry(invocation.principal, invocation.conversation.id, { kind: 'card', actor: { kind: 'bot', id: invocation.bot.id, displayName: invocation.bot.name }, runId: invocation.run.id, clientNonce: input.clientNonce, card: { type: 'voice_memo', attachmentId: speech.attachment.id, transcript: input.text, durationMs: speech.attachment.durationMs, peaks: [] } });
      return { entry };
    },
    share_file: async (input, invocation) => {
      const grant = (await effectiveBotGrants(services, invocation.principal, invocation.bot)).find(value => value.capabilityId === 'files');
      if (!grant || grant.effectiveLevel === 'off') fail('policy_denied', 'This bot is not authorized to read and share destination files.');
      const sourceId = services.store.metadata<string>(`runSourceEntry:${invocation.run.id}`);
      const source = sourceId ? services.store.get<P.TranscriptEntry>('entries', sourceId) : null;
      const attachment = await boundedOperation(importMachineFile(services, invocation.principal, invocation.bot.machineId, { clientNonce: input.clientNonce, path: input.path, conversationId: invocation.conversation.id, botId: invocation.bot.id }, { filename: input.filename, runId: invocation.run.id, sourceEntryId: source?.conversationId === invocation.conversation.id ? source.id : undefined }));
      if (attachment.state !== 'ready') fail('upstream_unavailable', 'File transfer did not produce a ready attachment.', false);
      const entry = services.entry(invocation.principal, invocation.conversation.id, { kind: 'card', actor: { kind: 'bot', id: invocation.bot.id, displayName: invocation.bot.name }, runId: invocation.run.id, clientNonce: input.clientNonce, card: { type: 'attachment', attachmentId: attachment.id, caption: input.caption ?? '' } });
      return { entry };
    },
    create_routine: async (input, invocation) => {
      if (input.trigger.kind === 'channel_event' && input.trigger.event === 'message' && !input.trigger.phrase?.trim()) fail('policy_denied', 'Broad message listeners require explicit human opt-in in the routine editor.');
      return services.invoke<P.Routine>(invocation.principal, 'POST', '/v1/routines', { ...input, botId: invocation.bot.id });
    },
    update_routine: async (input, invocation) => {
      const routine = services.store.require<P.Routine>('routines', input.routineId);
      if (routine.botId !== invocation.bot.id || routine.ownerUserId !== invocation.principal.userId) fail('forbidden', 'Only the originating user may update this bot routine.');
      const effectiveTrigger = input.trigger ?? routine.trigger;
      if (effectiveTrigger.kind === 'channel_event' && effectiveTrigger.event === 'message' && !effectiveTrigger.phrase?.trim() && (input.trigger || input.enabled === true && !routine.enabled)) fail('policy_denied', 'A bot cannot grant or re-enable broad message listening; use the human routine editor.');
      const { routineId, ...body } = input;
      return services.invoke<P.Routine>(invocation.principal, 'PATCH', `/v1/routines/${encodeURIComponent(routineId)}`, body);
    },
    save_skill: async (input, invocation) => {
      authorizedBot(services, invocation.principal, invocation.bot.id, true);
      const grant = (await effectiveBotGrants(services, invocation.principal, invocation.bot)).find(value => value.capabilityId === 'files');
      if (!grant || grant.effectiveLevel !== 'read_interact') fail('policy_denied', 'Saving a skill requires current read/interact file authorization.');
      return services.invoke<P.Skill>(invocation.principal, 'POST', '/v1/skills', { ...input, botId: invocation.bot.id, machineIds: [invocation.bot.machineId] });
    },
    list_bots: async (input, invocation) => {
      const query = new URLSearchParams();
      if (input.query !== undefined) query.set('query', input.query); if (input.limit !== undefined) query.set('limit', String(input.limit)); if (input.cursor !== undefined) query.set('cursor', input.cursor);
      return services.invoke<P.Page<P.Bot>>(invocation.principal, 'GET', `/v1/bots${query.size ? '?' + query : ''}`);
    },
    post_to_group: async (input, invocation, context) => {
      const room = authorizedConversation(services, invocation.principal, input.groupConversationId);
      if (room.kind !== 'group' || !room.botIds.includes(invocation.bot.id)) fail('forbidden', 'The bot must belong to this group.');
      if (input.mentions?.length && services.store.metadata<boolean>(`runNoHandoff:${invocation.run.id}`)) fail('policy_denied', 'This invocation does not permit waking more bots.');
      return sendMessage(services, invocation.principal, room.id, { clientNonce: input.clientNonce, text: input.text, attachmentIds: input.attachmentIds, mentions: input.mentions }, context, { bot: invocation.bot, run: invocation.run, noHandoff: true });
    },
    remember: async (input, invocation, context) => {
      const { conversationId, ...body } = input;
      if (body.scope === 'team') {
        authorizedBot(services, invocation.principal, invocation.bot.id, true);
        const approval = await services.gates.create<P.Approval>(invocation.principal, 'approval', { clientNonce: input.clientNonce, botId: invocation.bot.id, runId: invocation.run.id, conversationId: invocation.conversation.id, targetUserId: invocation.principal.userId, category: 'permissions', title: 'Share a memory with the team', description: 'Store this exact proposed fact in team-shared memory.', target: invocation.bot.id, inputs: { text: body.text, kind: body.kind, scope: body.scope }, source: 'product', forceHuman: true });
        recordGateWait(services, context, 'approvals', approval.id);
        const result = await services.gates.wait<P.Approval>('approvals', approval.id);
        if (result.gate.state !== 'approved' || result.gate.resolvedByUserId !== invocation.principal.userId) fail('policy_denied', 'Team memory sharing was not explicitly approved.');
        authorizedBot(services, invocation.principal, invocation.bot.id, true);
      }
      return services.invoke<P.Memory>(invocation.principal, 'POST', `/v1/bots/${encodeURIComponent(invocation.bot.id)}/memory`, body);
    },
    create_bot: async (input, invocation, context) => {
      services.auth.machine(invocation.principal, input.machineId);
      const approval = await services.gates.create<P.Approval>(invocation.principal, 'approval', { clientNonce: input.clientNonce, botId: invocation.bot.id, runId: invocation.run.id, conversationId: invocation.conversation.id, targetUserId: invocation.principal.userId, category: 'permissions', title: 'Create a helper bot', description: `Create ${input.name} on the selected machine with the exact proposed identity and job.`, target: input.machineId, inputs: JSON.parse(JSON.stringify(input)) as P.JSONObject, source: 'product', forceHuman: true });
      recordGateWait(services, context, 'approvals', approval.id);
      const result = await services.gates.wait<P.Approval>('approvals', approval.id);
      if (result.gate.state !== 'approved' || result.gate.resolvedByUserId !== invocation.principal.userId) fail('policy_denied', 'Helper creation was not explicitly approved by the initiating user.');
      // Recheck authority after a potentially long user wait, before provisioning.
      if (!services.auth.member(invocation.principal.userId).enabled) fail('forbidden', 'The initiating member is disabled.');
      services.auth.machine(invocation.principal, input.machineId);
      return services.invoke<P.Bot>(invocation.principal, 'POST', '/v1/bots', input);
    },
    update_preferences: async (input, invocation) => {
      const source = authorizedEntry(services, invocation.principal, input.sourceEntryId, invocation.conversation.id);
      const authority = services.store.metadata<EntryAuthority>(`entryAuthority:${source.id}`);
      if (!authority || authority.kind !== 'human' || authority.userId !== invocation.principal.userId || authority.conversationId !== invocation.conversation.id || invocation.run.routineRunId || services.store.metadata(`externalEntry:${source.id}`) !== null) fail('forbidden', 'Only verified first-party human text can authorize durable preferences.');
      if (source.kind !== 'message' || source.role !== 'user' || source.actor.kind !== 'user' || source.actor.id !== invocation.principal.userId || source.runId !== null || !source.text.trim()) fail('forbidden', 'Preferences require an explicit authenticated user message.');
      const inheritedSource = services.store.metadata<string>(`runSourceEntry:${invocation.run.id}`);
      if (inheritedSource !== source.id) fail('forbidden', 'Preferences must reference the actual initiating human source entry.');
      const { conversationId, ...body } = input;
      return services.invoke<P.PreferenceChange>(invocation.principal, 'POST', `/v1/bots/${encodeURIComponent(invocation.bot.id)}/preference-changes`, body);
    },
    create_reminder: async (input, invocation) => {
      const { conversationId, ...body } = input;
      return services.invoke<P.Reminder>(invocation.principal, 'POST', '/v1/reminders', { ...body, botId: invocation.bot.id, conversationId: invocation.conversation.id });
    },
  };
}

const rpcSchema = z.object({ jsonrpc: z.literal('2.0'), id: z.union([z.string().max(128), z.number().finite(), z.null()]).optional(), method: z.string().min(1).max(128), params: z.unknown().optional() }).strict();
const callSchema = z.object({ name: z.enum(Object.keys(schemas) as [keyof P.MCPToolInputs, ...(keyof P.MCPToolInputs)[]]), arguments: z.unknown() }).strict();
const noParams = z.object({}).strict();

export function createMcpRoutes(services: BackendServices): Route[] {
  const handlers = toolHandlers(services);
  async function call<K extends keyof P.MCPToolInputs>(name: K, raw: unknown, context: RequestContext, rpcId: string | number | null): Promise<P.MCPCallResult<P.MCPToolResults[K]>> {
    boundJson(raw);
    const input = parse(schemas[name], raw);
    const token = principal(context.user);
    if (token.kind !== 'bot' || !token.botId) fail('unauthenticated', 'Bot tools require a bot bearer token.');
    if (name === 'list_bots') {
      const listInput = input as P.BotListInput;
      const actor = resolveToolInvocation(services, token, context.request).principal;
      const query = new URLSearchParams();
      if (listInput.query !== undefined) query.set('query', listInput.query); if (listInput.limit !== undefined) query.set('limit', String(listInput.limit)); if (listInput.cursor !== undefined) query.set('cursor', listInput.cursor);
      const result = await services.invoke<P.Page<P.Bot>>(actor, 'GET', `/v1/bots${query.size ? '?' + query : ''}`);
      return { content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result as P.MCPToolResults[K] };
    }
    const syntheticPath = `/mcp/tools/${name}`;
    if (!('clientNonce' in input) || typeof input.clientNonce !== 'string') fail('invalid_request', 'Mutating tools require a client nonce.');
    const requested = 'conversationId' in input && typeof input.conversationId === 'string' ? input.conversationId : undefined;
    // Proof determines the source before any model-supplied room is considered.
    const authenticated = resolveToolInvocation(services, token, context.request, requested, true);
    services.store.setMetadata(`mcpCall:${token.id}:${authenticated.run.id}:${JSON.stringify(rpcId)}`, { path: syntheticPath, nonce: input.clientNonce });
    const bindingKey = `mcpAuthority:${token.botId}:${name}:${input.clientNonce}`;
    const existing = services.store.metadata<{ runId: string; userId: string; conversationId: string; hash: string }>(bindingKey);
    if (existing && (existing.hash !== services.mutations.digest(input) || existing.runId !== authenticated.run.id || existing.userId !== authenticated.principal.userId || existing.conversationId !== authenticated.conversation.id)) fail('nonce_conflict', 'This tool nonce belongs to a different authenticated invocation or proposal.');
    const operation = async () => {
      const invocation = resolveToolInvocation(services, token, context.request, requested);
      services.store.setMetadata(bindingKey, { runId: invocation.run.id, userId: invocation.principal.userId, conversationId: invocation.conversation.id, hash: services.mutations.digest(input) });
      const result = await handlers[name](input, invocation, synthetic);
      return { content: [{ type: 'text' as const, text: JSON.stringify(result) }], structuredContent: result };
    };
    const synthetic: RequestContext = { ...context, request: new Request(new URL(syntheticPath, services.config.publicUrl), { method: 'POST', headers: context.request.headers }), params: {}, query: new URLSearchParams(), body: input, user: token, route: { method: 'POST', path: syntheticPath, auth: 'bot', status: 200, handler: operation }, nonceResourceIds: [] };
    synthetic.route.authorizeReplay = replayContext => {
      const invocation = resolveToolInvocation(services, token, context.request, requested, true);
      const binding = services.store.metadata<{ runId: string; userId: string; conversationId: string; hash: string }>(bindingKey);
      if (binding && (binding.runId !== invocation.run.id || binding.userId !== invocation.principal.userId)) fail('forbidden', 'A receipt cannot borrow a different native invocation.');
      // Immutable nonce scope is already the bot bearer; private resources use original run authority.
      replayContext.user = invocation.principal;
    };
    return services.mutations.execute(synthetic, operation);
  }
  const handler: Route['handler'] = async context => {
    const token = principal(context.user);
    if (token.kind !== 'bot' || !token.botId) fail('unauthenticated', 'This transport accepts only bot bearer tokens.');
    const rpc = rpcSchema.safeParse(context.body);
    if (!rpc.success) return Response.json({ jsonrpc: '2.0', id: null, error: { code: -32600, message: 'Invalid JSON-RPC request.' } });
    const message = rpc.data;
    const respond = (result: unknown) => ({ jsonrpc: '2.0', id: message.id ?? null, result });
    const invalid = (code: number, detail: string) => Response.json({ jsonrpc: '2.0', id: message.id ?? null, error: { code, message: detail } });
    if (message.method === 'notifications/initialized' || message.method === 'notifications/cancelled') {
      if (message.id !== undefined) return invalid(-32600, 'Notifications must not have an id.');
      try {
        if (message.method === 'notifications/initialized') parse(noParams, message.params ?? {});
        else {
          const input = parse(z.object({ requestId: z.union([z.string(), z.number()]), reason: boundedText(512).optional() }).strict(), message.params);
          const invocation = resolveToolInvocation(services, token, context.request, undefined, true);
          const call = services.store.metadata<{ path: string; nonce: string }>(`mcpCall:${token.id}:${invocation.run.id}:${JSON.stringify(input.requestId)}`);
          const waiting = call ? services.store.metadata<{ collection: string; id: string }>(`mcpGate:${token.id}:${invocation.run.id}:${call.path}:${call.nonce}`) : null;
          if (waiting) cancelGate(services, waiting.collection, waiting.id);
        }
      } catch (error) { if (error instanceof ApiError && error.code === 'invalid_request') return invalid(-32602, 'Invalid notification parameters.'); throw error; }
      return new Response(null, { status: 202 });
    }
    if (message.id === undefined) return invalid(-32600, 'Requests require an id.');
    try {
      if (message.method === 'initialize') {
        parse(z.object({ protocolVersion: boundedText(64, 1), capabilities: z.record(z.string(), z.unknown()), clientInfo: z.object({ name: boundedText(120, 1), version: boundedText(120, 1) }).strict() }).strict(), message.params);
        return Response.json(respond({ protocolVersion: '2025-03-26', capabilities: { tools: { listChanged: false } }, serverInfo: { name: 'lemon-bot', version: '1.0.0' } }), { headers: { 'MCP-Protocol-Version': '2025-03-26' } });
      }
      if (message.method === 'ping') { parse(noParams, message.params ?? {}); return Response.json(respond({})); }
      if (message.method === 'tools/list') {
        parse(noParams, message.params ?? {});
        const tools: P.MCPToolSchema[] = (Object.keys(schemas) as (keyof P.MCPToolInputs)[]).map(name => ({ name, description: descriptions[name], inputSchema: { $schema: 'https://json-schema.org/draft/2020-12/schema', $ref: `#/$defs/${name}`, $defs: toolDefinitions } }));
        return Response.json(respond({ tools }));
      }
      if (message.method !== 'tools/call') return invalid(-32601, 'Method not found.');
      const params = parse(callSchema, message.params);
      const execute = async () => {
        try { return respond(await call(params.name, params.arguments, context, message.id ?? null)); }
        catch (error) { const result = errorEnvelope(error, context.requestId); return respond({ content: [{ type: 'text', text: JSON.stringify(result) }], structuredContent: result, isError: true }); }
      };
      if (!(context.request.headers.get('accept') ?? '').includes('text/event-stream')) return Response.json(await execute());
      const encoder = new TextEncoder();
      let cancelStream: (() => void) | undefined;
      const stream = new ReadableStream<Uint8Array>({
        start(controller) {
          let closed = false;
          const progress = setInterval(() => { if (!closed) controller.enqueue(encoder.encode(': lemon-bot operation pending\n\n')); }, 15000);
          cancelStream = () => { closed = true; clearInterval(progress); };
          void execute().then(result => { if (!closed) { controller.enqueue(encoder.encode(`event: message\ndata: ${JSON.stringify(result)}\n\n`)); controller.close(); } }).finally(() => cancelStream?.());
          context.request.signal.addEventListener('abort', () => cancelStream?.(), { once: true });
        },
        cancel() { cancelStream?.(); },
      });
      return new Response(stream, { headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', 'MCP-Protocol-Version': '2025-03-26' } });
    } catch (error) {
      if (error instanceof ApiError && error.code === 'invalid_request') return invalid(-32602, 'Invalid method parameters.');
      throw error;
    }
  };
  return [{ method: 'POST', path: '/mcp', auth: 'bot', mutation: false, body: 'json', status: 200, handler }];
}

/** Materialized normative input dictionary; no documentation/network reads at runtime. */
const toolDefinitions: P.JSONObject = {"VoiceSettings":{"type":"object","properties":{"voiceId":{"type":"string"},"speed":{"type":"number","minimum":0.5,"maximum":2},"language":{"type":["string","null"]}},"required":["voiceId","speed","language"],"additionalProperties":false},"Field":{"type":"object","properties":{"id":{"type":"string"},"label":{"type":"string"},"kind":{"type":"string","enum":["text","multiline","number","boolean","single_select","multi_select"]},"required":{"type":"boolean"},"options":{"type":"array","items":{"type":"object","properties":{"value":{"type":"string"},"label":{"type":"string"}},"required":["value","label"],"additionalProperties":false}},"min":{"type":"number"},"max":{"type":"number"}},"required":["id","label","kind","required"],"additionalProperties":false},"DraftContent":{"oneOf":[{"type":"object","properties":{"kind":{"type":"string","enum":["email"]},"connectorId":{"type":"string","minLength":1,"maxLength":128},"from":{"type":"string"},"to":{"type":"array","items":{"type":"string"}},"cc":{"type":"array","items":{"type":"string"}},"bcc":{"type":"array","items":{"type":"string"}},"subject":{"type":"string"},"body":{"type":"string"},"attachmentIds":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}}},"required":["kind","connectorId","from","to","cc","bcc","subject","body","attachmentIds"],"additionalProperties":false},{"type":"object","properties":{"kind":{"type":"string","enum":["slack"]},"connectorId":{"type":"string","minLength":1,"maxLength":128},"workspace":{"type":"string"},"target":{"type":"string"},"thread":{"type":["string","null"]},"body":{"type":"string"},"attachmentIds":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}}},"required":["kind","connectorId","workspace","target","thread","body","attachmentIds"],"additionalProperties":false},{"type":"object","properties":{"kind":{"type":"string","enum":["message"]},"channelBindingId":{"type":"string","minLength":1,"maxLength":128},"target":{"type":"string"},"thread":{"type":["string","null"]},"body":{"type":"string"},"attachmentIds":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}}},"required":["kind","channelBindingId","target","thread","body","attachmentIds"],"additionalProperties":false}]},"RoutineTrigger":{"oneOf":[{"type":"object","properties":{"kind":{"type":"string","enum":["schedule"]},"cron":{"type":"string"},"timezone":{"type":"string"}},"required":["kind","cron","timezone"],"additionalProperties":false},{"type":"object","properties":{"kind":{"type":"string","enum":["webhook"]}},"required":["kind"],"additionalProperties":false},{"type":"object","properties":{"kind":{"type":"string","enum":["channel_event"]},"channelBindingId":{"type":"string","minLength":1,"maxLength":128},"event":{"type":"string","enum":["mention","message","reaction","email_received"]},"channel":{"type":"string"},"phrase":{"type":"string"},"reaction":{"type":"string"},"senders":{"type":"array","items":{"type":"string"}},"noisyListenerConsent":{"type":"boolean","default":false}},"required":["kind","channelBindingId","event"],"additionalProperties":false},{"type":"object","properties":{"kind":{"type":"string","enum":["external_event"]},"source":{"type":"string","enum":["github","linear","sentry","pagerduty"]},"eventNames":{"type":"array","items":{"type":"string"}},"filters":{"type":"object","additionalProperties":{"type":["null","boolean","number","string","array","object"]}}},"required":["kind","source","eventNames","filters"],"additionalProperties":false}]},"Avatar":{"type":"object","properties":{"kind":{"type":"string","enum":["character","image"]},"shape":{"type":"string"},"color":{"type":"string"},"attachmentId":{"type":["string","null"]}},"required":["kind","shape","color","attachmentId"],"additionalProperties":false},"message_bot":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"targetBotId":{"type":"string","minLength":1,"maxLength":128},"text":{"type":"string"},"attachmentIds":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}},"replyConversationId":{"type":"string","minLength":1,"maxLength":128}},"required":["clientNonce","targetBotId","text"],"additionalProperties":false},"handoff":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"targetBotId":{"type":"string","minLength":1,"maxLength":128},"text":{"type":"string"},"attachmentIds":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}},"replyConversationId":{"type":"string","minLength":1,"maxLength":128},"task":{"type":"string"}},"required":["clientNonce","targetBotId","text","task"],"additionalProperties":false},"create_draft":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"content":{"$ref":"#/$defs/DraftContent"}},"required":["clientNonce","content"],"additionalProperties":false},"ask_user":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"title":{"type":"string"},"fields":{"type":"array","items":{"$ref":"#/$defs/Field"}},"expiresInMs":{"type":"integer","minimum":1000,"maximum":600000}},"required":["clientNonce","title","fields"],"additionalProperties":false},"request_approval":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"category":{"type":"string","enum":["shell","files","external_message","calendar","publish","purchase","permissions","connector","handoff"]},"title":{"type":"string"},"description":{"type":"string"},"target":{"type":"string"},"inputs":{"type":"object","additionalProperties":{"type":["null","boolean","number","string","array","object"]}},"expiresInMs":{"type":"integer","minimum":1000,"maximum":600000}},"required":["clientNonce","category","title","description","target","inputs"],"additionalProperties":false},"request_human_step":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"title":{"type":"string"},"instructions":{"type":"string"},"reason":{"type":"string","enum":["login","mfa","captcha","payment","identity","other"]},"externalUrl":{"type":"string"},"expiresInMs":{"type":"integer","minimum":1000,"maximum":600000}},"required":["clientNonce","title","instructions","reason"],"additionalProperties":false},"request_secret":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"name":{"type":"string"},"description":{"type":"string"},"scope":{"type":"string","enum":["machine","bot"]},"expiresInMs":{"type":"integer","minimum":1000,"maximum":600000}},"required":["clientNonce","name","description","scope"],"additionalProperties":false},"send_voice_memo":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"text":{"type":"string"},"voice":{"$ref":"#/$defs/VoiceSettings"}},"required":["clientNonce","text"],"additionalProperties":false},"share_file":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"path":{"type":"string"},"filename":{"type":"string"},"caption":{"type":"string"}},"required":["clientNonce","path"],"additionalProperties":false},"create_routine":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"name":{"type":"string"},"instruction":{"type":"string"},"trigger":{"$ref":"#/$defs/RoutineTrigger"},"enabled":{"type":"boolean"}},"required":["clientNonce","name","instruction","trigger","enabled"],"additionalProperties":false},"update_routine":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"routineId":{"type":"string","minLength":1,"maxLength":128},"revision":{"type":"integer"},"name":{"type":"string"},"instruction":{"type":"string"},"trigger":{"$ref":"#/$defs/RoutineTrigger"},"enabled":{"type":"boolean"}},"required":["clientNonce","routineId","revision"],"additionalProperties":false},"save_skill":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"name":{"type":"string"},"description":{"type":"string"},"markdown":{"type":"string"},"scope":{"type":"string","enum":["personal","team"]}},"required":["clientNonce","name","description","markdown","scope"],"additionalProperties":false},"list_bots":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":200},"cursor":{"type":"string"}},"required":[],"additionalProperties":false},"post_to_group":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"groupConversationId":{"type":"string","minLength":1,"maxLength":128},"text":{"type":"string"},"attachmentIds":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}},"mentions":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}}},"required":["clientNonce","groupConversationId","text"],"additionalProperties":false},"remember":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string","minLength":1,"maxLength":128},"text":{"type":"string"},"kind":{"type":"string","enum":["fact","preference","instruction","summary"]},"scope":{"type":"string","enum":["personal","team","private_note"]}},"required":["clientNonce","text","kind","scope"],"additionalProperties":false},"create_bot":{"type":"object","properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"name":{"type":"string"},"machineId":{"type":"string","minLength":1,"maxLength":128},"title":{"type":"string"},"job":{"type":"string"},"instructions":{"type":"string"},"avatar":{"$ref":"#/$defs/Avatar"},"voice":{"$ref":"#/$defs/VoiceSettings"},"language":{"type":["string","null"]},"visibility":{"type":"string","enum":["personal","team"]},"skillIds":{"type":"array","items":{"type":"string","minLength":1,"maxLength":128}},"templateId":{"type":"string","minLength":1,"maxLength":128}},"required":["clientNonce","name","machineId"],"additionalProperties":false},"update_preferences":{"type":"object","additionalProperties":false,"required":["clientNonce","revision","changes","reason","sourceEntryId"],"properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string"},"revision":{"type":"integer","minimum":1},"sourceEntryId":{"type":"string"},"reason":{"type":"string"},"changes":{"type":"object","additionalProperties":false,"properties":{"job":{"type":"string"},"instructions":{"type":"string"},"voice":{"type":"object","additionalProperties":false,"required":["voiceId","speed","language"],"properties":{"voiceId":{"type":"string"},"speed":{"type":"number","minimum":0.5,"maximum":2},"language":{"type":["string","null"]}}},"language":{"type":["string","null"]}}}}},"create_reminder":{"type":"object","additionalProperties":false,"required":["clientNonce","text","dueAtMs","timezone"],"properties":{"clientNonce":{"type":"string","minLength":16,"maxLength":128,"pattern":"^[A-Za-z0-9_-]+$"},"conversationId":{"type":"string"},"text":{"type":"string"},"dueAtMs":{"type":"integer","minimum":0},"timezone":{"type":"string"}}}};
