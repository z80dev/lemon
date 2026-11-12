import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { ApiError, errorEnvelope, fail } from '../core/errors';
import { id, parse, z } from '../core/validation';
import { nativeBotToolPolicy } from '../core/experiences';
import { buildInvocationContext, buildMemoryContextKey, effectiveInvocationAudience, type InvocationContext, type RuntimeMapping } from './runs';
import { runOrigin } from '../core/approval-allowances';

export const nativeFollowupAdmissionPath = '/internal/runtime/followup/admission';
interface Issuer { botId: string; profileId: string; url: string; digest: string; encryptedToken: string; state: 'pending' | 'configured' | 'rejected' | 'outcome_unknown' }
const lineageSchema = z.object({
  runId: id, sourceRootRunId: id, parentRunId: id, sourceProfileId: id,
  sourceSessionKey: z.string().min(1).max(2048), sourceInvocationContextKey: id, sourceMemoryContextKey: id,
  targetProfileId: id, targetAgentId: id, targetSessionKey: z.string().min(1).max(2048), targetNodeId: id,
  sourceRestrictiveToolPolicy: z.record(z.string(), z.json()),
}).strict();
export type NativeFollowupLineage = z.infer<typeof lineageSchema>;
type AdmissionReply = { allow: false } | { allow: true; invocation: InvocationContext & { sharedMemoryGrant: false } };
interface Reservation { issuerDigest: string; fingerprint: string; encryptedLineage: string; runId: string | null; state: 'reserved' | 'approved' | 'denied' | 'outcome_unknown'; encryptedReply: string | null }
const finished: P.Run['status'][] = ['succeeded', 'failed', 'cancelled'];
const maxAdmissionBytes = 16_777_216;
function receipt<T>(schema: z.ZodType<T>, input: unknown): T { const result = schema.safeParse(input); if (!result.success) fail('upstream_unavailable', 'The controller returned an invalid private admission receipt.'); return result.data; }

function issuerKeys(botId: string) { return { active: `nativeFollowupIssuerConfig:${botId}`, pending: `nativeFollowupIssuerPending:${botId}` }; }
function activateIssuer(services: BackendServices, issuer: Issuer): void {
  const keys = issuerKeys(issuer.botId);
  services.store.transaction(() => {
    const old = services.store.metadata<Issuer>(keys.active);
    if (old && old.digest !== issuer.digest) services.store.setMetadata(`nativeFollowupIssuer:${old.digest}`, null);
    services.store.setMetadata(keys.active, { ...issuer, state: 'configured' } satisfies Issuer);
    services.store.setMetadata(`nativeFollowupIssuer:${issuer.digest}`, issuer.botId);
    services.store.setMetadata(keys.pending, null);
  });
}
/** A digest of the decrypted UTF-8 token, not the product's keyed JSON digest. */
function tokenSha256(services: BackendServices, issuer: Issuer): string {
  return createHash('sha256').update(services.decrypt<string>(issuer.encryptedToken), 'utf8').digest('hex');
}
async function issuerReceipt(services: BackendServices, bot: P.Bot) {
  if (!services.lemon.methods.includes('profile.followup.admission.get')) fail('outcome_unknown', 'The controller cannot resolve this admission receipt. Upgrade the controller before finishing setup; no configuration was retried.', false, { resourceIds: [bot.id] });
  return receipt(z.object({ profileId: z.literal(bot.profileId), configured: z.boolean(), url: z.string().optional(), tokenSha256: z.string().regex(/^[a-f0-9]{64}$/).optional() }).strict(), await services.lemon.call('profile.followup.admission.get', { profileId: bot.profileId }, { mutation: false }));
}
/** Read-only reconciliation may adopt a matching issuer, but never sends another setter. */
export async function reconcileNativeFollowupAdmission(services: BackendServices, bot: P.Bot): Promise<boolean> {
  const keys = issuerKeys(bot.id);
  const pending = services.store.metadata<Issuer>(keys.pending);
  const candidate = pending ?? services.store.metadata<Issuer>(keys.active);
  if (!candidate) return false;
  if (!pending && candidate.state === 'configured') return true;
  const actual = await issuerReceipt(services, bot);
  if (actual.configured && actual.url === candidate.url && actual.tokenSha256 === tokenSha256(services, candidate)) {
    activateIssuer(services, candidate); return true;
  }
  return false;
}
export function nativeAdmissionAddressChange(services: BackendServices, bot: P.Bot): string | null {
  const old = services.store.metadata<Issuer>(issuerKeys(bot.id).active);
  const url = new URL(nativeFollowupAdmissionPath, services.config.publicUrl).toString();
  return old && old.url !== url ? `Lemon Bot's address changed from ${new URL(old.url).origin} to ${new URL(url).origin}. Choose Update address to configure the new callback; add ${new URL(url).origin} to LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS on the controller first (see the Lemon Bot getting-started guide).` : null;
}
/** Re-addressing retains the old issuer until an exact controller acknowledgement. */
export async function configureNativeFollowupAdmission(services: BackendServices, bot: P.Bot, readdress = false): Promise<void> {
  bot = services.store.require<P.Bot>('bots', bot.id);
  const keys = issuerKeys(bot.id), url = new URL(nativeFollowupAdmissionPath, services.config.publicUrl).toString();
  let existing = services.store.metadata<Issuer>(keys.active);
  const change = nativeAdmissionAddressChange(services, bot);
  if (existing && existing.profileId !== bot.profileId) fail('conflict', 'The admission issuer belongs to a different profile; no configuration was changed.');
  if (change && !readdress) fail('conflict', change);
  if (!services.lemon.methods.includes('profile.followup.admission.set') || !services.lemon.methods.includes('runs.followup.lineage.get')) fail('capability_unavailable', 'This controller lacks authenticated native follow-up admission.');
  let candidate = services.store.metadata<Issuer>(keys.pending) ?? (change ? null : existing);
  if (candidate && (candidate.profileId !== bot.profileId || candidate.url !== url)) fail('conflict', 'Finish the pending admission address change before changing the public address again.');
  if (candidate?.state === 'configured') return;
  if (candidate && ['pending', 'outcome_unknown'].includes(candidate.state)) {
    const actual = await issuerReceipt(services, bot);
    if (actual.configured && actual.url === candidate.url && actual.tokenSha256 === tokenSha256(services, candidate)) {
      activateIssuer(services, candidate); return;
    }
    // Only no configuration, or the exact retained old issuer, proves the candidate is not active.
    const notApplied = !actual.configured || (change && existing && actual.url === existing.url && actual.tokenSha256 === tokenSha256(services, existing));
    if (!notApplied) fail('outcome_unknown', 'Native admission configuration is unresolved. Its receipt does not prove it was not applied; no configuration was retried.', false, { resourceIds: [bot.id] });
  }
  const token = candidate ? services.decrypt<string>(candidate.encryptedToken) : Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64url');
  const issuer: Issuer = { botId: bot.id, profileId: bot.profileId, url, digest: services.mutations.digest(token), encryptedToken: candidate?.encryptedToken ?? services.encrypt(token), state: 'pending' };
  const key = change ? keys.pending : keys.active;
  services.store.transaction(() => {
    services.store.setMetadata(key, issuer);
    if (!change) services.store.setMetadata(`nativeFollowupIssuer:${issuer.digest}`, bot.id);
  });
  try {
    receipt(z.object({ profileId: z.literal(bot.profileId), configured: z.literal(true) }).strict(), await services.lemon.call('profile.followup.admission.set', { profileId: bot.profileId, url, token }, { mutation: true, resourceIds: [bot.id] }));
    activateIssuer(services, issuer);
  } catch (error) {
    if (services.store.metadata<Issuer>(keys.active)?.digest === issuer.digest && services.store.metadata<Issuer>(keys.active)?.state === 'configured') return;
    const knownRejection = error instanceof ApiError && error.retrySafe && ['forbidden', 'not_found', 'invalid_request', 'capability_unavailable', 'policy_denied', 'callback_origin_not_allowed', 'callback_requires_https', 'invalid_callback_url'].includes(error.code);
    services.store.setMetadata(key, { ...issuer, state: knownRejection ? 'rejected' : 'outcome_unknown' } satisfies Issuer);
    if (!knownRejection) fail('outcome_unknown', 'Native admission configuration may have been installed. Finish setup will query its receipt before proceeding.', false, { resourceIds: [bot.id] });
    const origin = new URL(url).origin;
    if (error.code === 'callback_origin_not_allowed') fail(error.code, `Lemon isn't set to accept Lemon Bot at ${origin}. Add ${origin} to LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS on the controller, then choose Finish setup (see the Lemon Bot getting-started guide).`);
    if (error.code === 'callback_requires_https') fail(error.code, `Lemon Bot at ${origin} requires HTTPS. Set LEMON_BOT_PUBLIC_URL to a reachable HTTPS origin, add that origin to LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS, then choose Update address (see the Lemon Bot getting-started guide).`);
    if (error.code === 'invalid_callback_url') fail(error.code, `Lemon Bot's callback at ${origin} is invalid. Set LEMON_BOT_PUBLIC_URL to a credential-free HTTPS origin without a query or fragment; allow it in LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS (see the Lemon Bot getting-started guide).`);
    throw error;
  }
}

function retained(services: BackendServices, nativeRunId: string) {
  const productId = services.store.metadata<string>(`nativeRunProduct:${nativeRunId}`);
  if (!productId) fail('forbidden', 'Native lineage has no retained product execution.');
  const run = services.store.require<P.Run>('runs', productId);
  const principal = services.store.metadata<Principal>(`runPrincipal:${productId}`);
  const mapping = services.store.metadata<RuntimeMapping>(`runtimeRun:${productId}`);
  const context = services.store.metadata<InvocationContext>(`runtimeInvocation:${nativeRunId}`);
  if (!principal || !mapping || !context || mapping.upstreamRunId !== nativeRunId) fail('forbidden', 'Native lineage has no bound product invocation.');
  return { run, principal, mapping, context };
}
function currentAuthority(services: BackendServices, issuer: Issuer, lineage: NativeFollowupLineage) {
  const root = retained(services, lineage.sourceRootRunId), parent = retained(services, lineage.parentRunId);
  if (root.run.botId !== issuer.botId || root.mapping.profileId !== issuer.profileId || lineage.sourceProfileId !== issuer.profileId || lineage.sourceSessionKey !== root.mapping.sessionKey || lineage.sourceInvocationContextKey !== root.context.invocationContextKey || lineage.sourceMemoryContextKey !== root.context.memoryContextKey) fail('forbidden', 'The native issuer does not match its original source context.');
  if (parent.principal.kind !== root.principal.kind || parent.principal.id !== root.principal.id || parent.principal.userId !== root.principal.userId || parent.principal.workspaceId !== root.principal.workspaceId || (services.store.metadata<string>(`nativeRootSource:${parent.run.id}`) ?? parent.mapping.upstreamRunId) !== lineage.sourceRootRunId) fail('forbidden', 'The native parent does not retain the original source authority.');
  if (root.run.status === 'cancelled' || parent.run.status === 'cancelled' || services.store.metadata(`runCancelAcknowledged:${root.run.id}`) !== null || services.store.metadata(`runCancelAcknowledged:${parent.run.id}`) !== null) fail('policy_denied', 'A stopped source cannot create a native continuation.');
  const member = services.auth.member(root.principal.userId);
  if (!member.enabled || root.principal.workspaceId !== services.store.metadata<string>('workspaceId')) fail('forbidden', 'The native source is no longer an enabled workspace member.');
  const actor: Principal = { ...root.principal, role: member.role };
  const sourceBot = services.store.require<P.Bot>('bots', root.run.botId);
  if (actor.kind !== 'user' || actor.id !== actor.userId || sourceBot.ownerUserId !== actor.userId || root.run.initiatorUserId !== actor.userId) fail('forbidden', 'Native continuation belongs to the actual Bot owner.');
  services.auth.bot(actor, sourceBot.id);
  const parentBot = services.store.require<P.Bot>('bots', parent.run.botId);
  if (parentBot.ownerUserId !== actor.userId || parent.run.initiatorUserId !== actor.userId) fail('forbidden', 'Native parent authority cannot cross human ownership.');
  services.auth.bot(actor, parentBot.id);
  const conversation = services.auth.conversation(actor, root.run.conversationId);
  effectiveInvocationAudience(services, actor, conversation, root.run.id);
  const targets = services.store.list<P.Bot>('bots', value => value.profileId === lineage.targetProfileId);
  if (targets.length !== 1 || lineage.targetAgentId !== lineage.targetProfileId) fail('forbidden', 'The native destination is not an unambiguous product Bot.');
  const targetBot = targets[0]!;
  if (targetBot.ownerUserId !== actor.userId) fail('forbidden', 'Native continuation cannot enter another owner’s Bot.');
  services.auth.bot(actor, targetBot.id);
  for (const bot of [sourceBot, parentBot, targetBot]) {
    const machine = services.store.require<P.Machine>('machines', bot.machineId);
    if (machine.ownerUserId !== actor.userId) fail('forbidden', 'Native continuation cannot use another owner’s host.');
    const policy = services.store.metadata<{ state: string }>(`botPolicySync:${bot.id}`);
    if (services.store.metadata(`botLifecycle:${bot.id}`) || services.store.metadata(`connectorRevocation:${bot.id}`) || services.store.metadata(`runtimePolicyFence:${bot.id}:${actor.userId}`) || services.store.metadata(`machineRuntimeFence:${machine.id}`) || (policy && policy.state !== 'acknowledged')) fail('policy_denied', 'Native continuation authority is fenced.');
  }
  const sourceMachine = services.store.require<P.Machine>('machines', sourceBot.machineId);
  const targetMachine = services.store.require<P.Machine>('machines', targetBot.machineId);
  if (sourceBot.profileId !== root.mapping.profileId || sourceMachine.nodeId !== root.mapping.nodeId || lineage.targetNodeId === 'local' || targetMachine.nodeId !== lineage.targetNodeId || targetMachine.status !== 'online' || !services.lemon.connected) fail('machine_offline', 'Native continuation placement is stale or unavailable.');
  if (services.runtime.sessionKey(conversation, targetBot) !== lineage.targetSessionKey) fail('forbidden', 'The native destination session is not the authorized source room.');
  return { root, parent, actor, sourceBot, targetBot, conversation };
}

function cachedReply(services: BackendServices, issuer: Issuer, reservation: Reservation): AdmissionReply {
  if (reservation.issuerDigest !== issuer.digest) fail('forbidden', 'The fixed native reservation belongs to another issuer.');
  try {
    const lineage = receipt(lineageSchema, services.decrypt(reservation.encryptedLineage));
    const authority = currentAuthority(services, issuer, lineage);
    if (!reservation.encryptedReply) return { allow: false };
    const reply = services.decrypt<AdmissionReply>(reservation.encryptedReply);
    if (!reply.allow) return reply;
    if (!reservation.runId) return { allow: false };
    const actor = services.store.metadata<Principal>(`runPrincipal:${reservation.runId}`);
    const epochs = services.store.metadata<{ connectorId: string; epoch: number }[]>(`runConnectorEpochs:${reservation.runId}`);
    const audience = effectiveInvocationAudience(services, authority.actor, authority.conversation, reservation.runId);
    if (!actor || actor.role !== authority.actor.role || !epochs || epochs.some(value => (services.store.metadata<number>(`connectorEpoch:${value.connectorId}`) ?? 0) !== value.epoch) || buildMemoryContextKey(services, authority.actor, audience, authority.targetBot) !== reply.invocation.memoryContextKey) return { allow: false };
    return reply;
  } catch (error) { if (error instanceof ApiError) return { allow: false }; throw error; }
}

export function createRuntimeAdmissionRoutes(services: BackendServices): Route[] {
  return [{ method: 'POST', path: nativeFollowupAdmissionPath, auth: 'public', mutation: false, body: 'json', status: 200, async handler(context) {
    if (context.query.size) fail('invalid_request', 'Native admission does not accept query parameters.');
    const match = /^Bearer ([A-Za-z0-9_-]{43})$/.exec(context.request.headers.get('authorization') ?? '');
    if (!match) fail('unauthenticated', 'A private native issuer credential is required.');
    const digest = services.mutations.digest(match[1]!);
    const botId = services.store.metadata<string>(`nativeFollowupIssuer:${digest}`);
    const issuer = botId ? services.store.metadata<Issuer>(`nativeFollowupIssuerConfig:${botId}`) : null;
    if (!issuer || issuer.digest !== digest || issuer.state === 'rejected') fail('unauthenticated', 'The native issuer credential is not recognized.');
    const { runId } = parse(z.object({ runId: id }).strict(), context.body);
    const key = `nativeFollowupReservation:${runId}`;
    const previous = services.store.metadata<Reservation>(key);
    if (previous) return cachedReply(services, issuer, previous);
    const lineage = receipt(lineageSchema, await services.lemon.call('runs.followup.lineage.get', { runId }, { timeoutMs: 2000 }));
    if (lineage.runId !== runId || lineage.sourceProfileId !== issuer.profileId) fail('forbidden', 'The controller lineage is not bound to this issuer.');
    const concurrent = services.store.metadata<Reservation>(key);
    if (concurrent) return cachedReply(services, issuer, concurrent);
    const reservation: Reservation = { issuerDigest: digest, fingerprint: services.mutations.digest(lineage), encryptedLineage: services.encrypt(lineage), runId: null, state: 'reserved', encryptedReply: null };
    let fresh: P.Run | null = null;
    try {
      const authority = currentAuthority(services, issuer, lineage);
      if (services.store.metadata<string>(`nativeRunProduct:${runId}`) || services.store.get('runs', runId)) fail('nonce_conflict', 'This fixed native identity is already reserved by another operation.');
      fresh = { ...services.resource('run', { conversationId: authority.conversation.id, botId: authority.targetBot.id, initiatorUserId: authority.actor.userId, clientNonce: services.mutations.digest({ kind: 'native_followup_nonce', runId }), status: 'reserved' as const, error: null, startedAtMs: null, completedAtMs: null, routineRunId: null }), id: runId };
      const bound: RuntimeMapping = { upstreamRunId: runId, executionRunId: runId, sessionKey: lineage.targetSessionKey, profileId: lineage.targetProfileId, nodeId: lineage.targetNodeId, conversationId: fresh.conversationId, botId: fresh.botId, assistantEntryId: null, deltaSeq: 0, deltaGap: false, dispatched: false };
      const resource = fresh;
      services.store.transaction(() => {
        services.store.put('runs', resource); services.store.setMetadata(`nativeRunProduct:${runId}`, resource.id); services.store.setMetadata(`runtimeRun:${resource.id}`, bound); services.store.setMetadata(`runPrincipal:${resource.id}`, authority.actor);
        const origins = [runOrigin(services, authority.root.run.id), runOrigin(services, authority.parent.run.id)];
        services.store.setMetadata(`runApprovalOrigin:${resource.id}`, origins.find(origin => !['owner_chat', 'routine', 'native_followup'].includes(origin)) ?? 'native_followup');
        services.store.setMetadata(`runParent:${resource.id}`, authority.parent.run.id); services.store.setMetadata(`nativeRootSource:${resource.id}`, lineage.sourceRootRunId); services.store.setMetadata(`runIntent:${resource.id}`, reservation.fingerprint);
        for (const prefix of ['runReturnConversation', 'runSourceEntry', 'runNoHandoff']) { const value = services.store.metadata(`${prefix}:${authority.root.run.id}`); if (value !== null) services.store.setMetadata(`${prefix}:${resource.id}`, value); }
        reservation.runId = resource.id; services.store.setMetadata(key, reservation); services.events.emit('run.upserted', resource, { conversationId: resource.conversationId, botId: resource.botId });
      });
      // The actual authenticated callback proves installation even if its setter ACK was lost.
      if (issuer.state !== 'configured') services.store.setMetadata(`nativeFollowupIssuerConfig:${issuer.botId}`, { ...issuer, state: 'configured' } satisfies Issuer);
      await services.integrations.admission(authority.actor, authority.targetBot.id);
      const floors: P.JSONObject[] = [lineage.sourceRestrictiveToolPolicy];
      if (authority.sourceBot.id !== authority.targetBot.id) floors.push(await nativeBotToolPolicy(services, authority.actor, authority.sourceBot));
      const invocation = await buildInvocationContext(services, authority.actor, authority.conversation, authority.targetBot, runId, floors);
      const current = currentAuthority(services, issuer, lineage);
      if (current.actor.role !== authority.actor.role) fail('policy_denied', 'Source membership changed during native admission.');
      const epochs = services.store.metadata<{ connectorId: string; epoch: number }[]>(`runConnectorEpochs:${resource.id}`) ?? [];
      if (epochs.some(value => (services.store.metadata<number>(`connectorEpoch:${value.connectorId}`) ?? 0) !== value.epoch)) fail('policy_denied', 'Connector authority changed during native admission.');
      const reply: AdmissionReply = { allow: true, invocation: { ...invocation, sharedMemoryGrant: false } };
      if (Buffer.byteLength(JSON.stringify(reply)) > maxAdmissionBytes) fail('too_large', 'The complete native admission policy exceeds the controller response bound.');
      services.store.transaction(() => { services.store.setMetadata(key, { ...reservation, state: 'approved', encryptedReply: services.encrypt(reply) } satisfies Reservation); services.store.setMetadata(`nativeFollowupAdmissionReceipt:${runId}`, { allow: true }); });
      return reply;
    } catch (error) {
      const reply: AdmissionReply = { allow: false };
      const uncertain = error instanceof ApiError && !error.retrySafe;
      services.store.setMetadata(key, { ...reservation, state: uncertain ? 'outcome_unknown' : 'denied', encryptedReply: services.encrypt(reply) } satisfies Reservation);
      services.store.setMetadata(`nativeFollowupAdmissionReceipt:${runId}`, { allow: false });
      if (fresh) {
        const failure = error instanceof ApiError ? error : new ApiError('upstream_unavailable', 'Native admission failed.');
        const failed = services.update(fresh, { status: uncertain ? 'outcome_unknown' as const : 'failed' as const, error: errorEnvelope(failure, services.id('req')).error, completedAtMs: uncertain ? null : services.now() });
        services.store.put('runs', failed); services.events.emit('run.upserted', failed, { conversationId: failed.conversationId, botId: failed.botId });
      }
      return reply;
    }
  } }];
}
