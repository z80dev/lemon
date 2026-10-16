import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, RequestContext, Route } from './services';
import { ApiError, fail } from './errors';
import { z, parse, principal, mutation, nonce, queryObject } from './validation';
import { hasProductAccess } from '../enterprise/policy';
import { authorizeProviderCompletion, definitiveProviderCompletionRejection, deviceChallengeSchema, deviceResultSchema, pinProviderLoginAuthority, providerAuthorityGeneration, providerCompletionCollection, settleProviderCompletions } from './provider_completion';
import type { ProviderCompletion } from './provider_completion';

const identifier = z.string().min(1).max(256).regex(/^[A-Za-z0-9_.:-]+$/);
const providerId = z.string().min(1).max(128).regex(/^[a-z0-9][a-z0-9_-]*$/);
const timestamp = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const listingSchema = z.object({
  target: z.object({ id: identifier, nodeId: identifier.nullable(), hostname: z.string().min(1).max(256) }).strict(),
  default: z.object({ providerId: providerId.nullable(), modelId: z.string().min(1).max(256).nullable() }).strict(),
  providers: z.array(z.object({
    id: providerId, displayName: z.string().min(1).max(128),
    methods: z.array(z.enum(['api_key', 'device_code', 'unsupported'])).max(3),
    configured: z.boolean(), status: z.enum(['ready', 'needs_login', 'expired', 'configured']),
    lastValidation: z.object({ atMs: timestamp, kind: z.literal('resolver'), ready: z.boolean() }).strict().nullable(),
    environmentOverrides: z.array(z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/).max(128)).max(32),
    configurationOverrides: z.array(z.enum(['project_configuration', 'credential_pool', 'external_secret_source'])).max(3),
  }).strict()).max(256),
}).strict();
const targetRequest = mutation.extend({ targetId: identifier });
const keyRequest = targetRequest.extend({ value: z.string().min(1).max(16_384).refine(value => value.trim().length > 0 && !value.includes('\0') && Buffer.byteLength(value, 'utf8') <= 16_384) });
const defaultRequest = targetRequest.extend({ providerId, modelId: z.string().min(1).max(256).refine(value => !/[\u0000-\u001f]/.test(value)) });

/** Dedicated target-local management, never product secret storage or generic config writes. */
export function createProviderRoutes(services: BackendServices): Route[] {
  // Reconnection settles durable uncertain completions without authorizing a write.
  services.lemon.onConnected(() => { void settleProviderCompletions(services).catch(() => {}); });
  function target(context: RequestContext): P.Machine | null {
    const actor = principal(context.user);
    services.auth.requireRole(actor, 'owner');
    if (!hasProductAccess(services, actor.userId)) fail('policy_denied', 'Workspace or directory policy denies provider management.');
    // Machine-management/admin access is NOT authority over somebody else's provider credentials.
    if (!context.params.id) return null;
    const machine = services.auth.machine(actor, context.params.id, true);
    if (machine.ownerUserId !== actor.userId) fail('forbidden', 'Only the actual machine owner may manage its model providers.');
    if (!machine.nodeId || machine.status !== 'online') fail('machine_offline', 'The selected execution machine is not online.');
    return machine;
  }
  function method(machine: P.Machine | null, action: string): string {
    const name = `${machine ? 'node.' : ''}providers.management.${action}`;
    if (!services.lemon.connected) fail('upstream_unavailable', 'The controller is not connected.');
    if (!services.lemon.methods.includes(name)) fail('capability_unavailable', 'Provider management is unavailable on this execution target. Upgrade its Lemon runtime.');
    return name;
  }
  function projection(raw: unknown, machine: P.Machine | null, mutating = false): P.ProviderManagement {
    const parsed = listingSchema.safeParse(raw);
    if (!parsed.success || parsed.data.target.nodeId !== (machine?.nodeId ?? null)) {
      fail(mutating ? 'outcome_unknown' : 'upstream_unavailable', 'The execution target returned an invalid provider status. Reload its status before another action.', false);
    }
    return parsed.data;
  }
  async function currentOwner(context: RequestContext) {
    const actor = await services.auth.authenticate(context.request, 'owner');
    if (!actor || actor.kind !== 'user' || !actor.sessionId || actor.userId !== context.user?.userId || actor.workspaceId !== context.user.workspaceId || actor.sessionId !== context.user.sessionId) {
      fail('unauthenticated', 'The owner session changed. Sign in again.');
    }
    return actor;
  }
  async function list(context: RequestContext): Promise<P.ProviderManagement> {
    parse(z.object({}).strict(), queryObject(context.query));
    const machine = target(context);
    const raw = await services.lemon.call(method(machine, 'list'), machine ? { nodeId: machine.nodeId! } : {});
    await currentOwner(context);
    target(context);
    return projection(raw, machine);
  }
  async function authorizeReplay(context: RequestContext): Promise<void> {
    const body = parse(targetRequest.passthrough(), context.body);
    const current = await list(context);
    if (current.target.id !== body.targetId) fail('conflict', 'The execution target changed. Reload provider settings before continuing.');
  }
  async function change(context: RequestContext, action: 'api_key.set' | 'disconnect' | 'default.set'): Promise<P.ProviderManagement> {
    // Body parsers and all errors are fixed messages; no raw credential-bearing terms escape.
    const key = action === 'api_key.set' ? parse(keyRequest, context.body) : null;
    const defaults = action === 'default.set' ? parse(defaultRequest, context.body) : null;
    const body = key ?? defaults ?? parse(targetRequest, context.body);
    const selectedProvider = defaults?.providerId ?? parse(providerId, context.params.providerId);
    const value = key?.value;
    const modelId = defaults?.modelId;
    const listing = await list(context);
    if (listing.target.id !== body.targetId) fail('conflict', 'The execution target changed. Reload provider settings before continuing.');
    const provider = listing.providers.find(value => value.id === selectedProvider);
    if (!provider || action === 'api_key.set' && !provider.methods.includes('api_key')) fail('invalid_request', 'This provider does not support the requested management method.');
    // list() reauthenticated the current bearer/device after its asynchronous read.
    const machine = target(context);
    if ((machine?.nodeId ?? null) !== listing.target.nodeId) fail('conflict', 'The execution target changed. Reload provider settings before continuing.');
    const params: Record<string, unknown> = { ...(machine ? { nodeId: machine.nodeId! } : {}), targetId: body.targetId, providerId: selectedProvider };
    if (value !== undefined) params.value = value;
    if (modelId !== undefined) params.modelId = modelId;
    const rpc = method(machine, action);
    let raw: unknown;
    try {
      raw = await services.lemon.call(rpc, params, { mutation: true, resourceIds: machine ? [machine.id] : [] });
    } catch (error) {
      // Defense in depth: even an unexpected target error cannot put a key in a nonce receipt.
      if (error instanceof ApiError) throw new ApiError(error.code, 'The execution target could not confirm this provider operation. Reload provider status before another action.', error.retrySafe);
      fail('outcome_unknown', 'The provider operation could not be confirmed. Reload provider status before another action.', false);
    }
    const result = projection(raw, machine, true);
    if (result.target.id !== body.targetId) fail('outcome_unknown', 'The provider receipt belongs to another execution target. Reload provider status before another action.', false);
    // A malformed target implementation must not turn the submitted key into a read-back channel.
    if (value !== undefined && JSON.stringify(result).includes(value)) fail('outcome_unknown', 'The target returned an unsafe provider receipt. Reload provider status before another action.', false);
    return result;
  }
  async function device(context: RequestContext, action: 'start' | 'poll' | 'cancel'): Promise<P.ProviderDeviceLogin> {
    const body = parse(targetRequest, context.body);
    const generation = providerAuthorityGeneration(services.store);
    await settleProviderCompletions(services);
    const selectedProvider = parse(z.literal('openai_codex'), context.params.providerId);
    const loginId = action === 'start' ? body.clientNonce : parse(nonce, context.params.loginId);
    if (action !== 'start' && body.clientNonce === loginId) fail('invalid_request', 'Use a separate fixed mutation nonce for this login action.');
    const listing = await list(context);
    if (listing.target.id !== body.targetId) fail('conflict', 'The execution target changed. Reload provider settings before continuing.');
    if (!listing.providers.some(value => value.id === selectedProvider && value.methods.includes('device_code'))) {
      fail('capability_unavailable', 'This execution target does not support Codex device sign-in.');
    }
    const actor = principal(context.user);
    if (actor.kind !== 'user' || !actor.sessionId) fail('unauthenticated', 'A current owner session is required.');
    const params = {
      targetId: body.targetId, providerId: selectedProvider, loginId,
      ownerId: createHash('sha256').update(JSON.stringify(['lemon_bot', 'provider_owner', actor.workspaceId, actor.userId])).digest('hex'),
      sessionId: createHash('sha256').update(JSON.stringify(['lemon_bot', 'provider_session', actor.sessionId])).digest('hex'),
    };
    // Journal only the bound intent and a safe admission marker, never OAuth state or
    // a cached pending snapshot. The target owns idempotence and fresh reconciliation.
    await services.mutations.execute({ ...context, body: { clientNonce: body.clientNonce, ...params } }, () => ({ ok: true }));
    await currentOwner(context);
    const machine = target(context);
    if ((machine?.nodeId ?? null) !== listing.target.nodeId) fail('conflict', 'The execution target changed. Reload provider settings before continuing.');
    method(machine, `device.${action}`);
    const rpc = method(machine, `device.${action === 'poll' ? 'complete' : action}`);
    const boundParams = { ...(machine ? { nodeId: machine.nodeId! } : {}), ...params };
    if (action !== 'cancel') pinProviderLoginAuthority(services, actor, machine, boundParams, generation);
    let completion: ProviderCompletion | null = null;
    if (action === 'poll') {
      let challengeRaw: unknown;
      try {
        challengeRaw = await services.lemon.call(method(machine, 'device.challenge'), boundParams, { resourceIds: machine ? [machine.id] : [] });
      } catch (error) {
        if (error instanceof ApiError) throw new ApiError(error.code, 'The execution target could not confirm this device login action. Reconcile this same login before starting another.', error.retrySafe);
        fail('outcome_unknown', 'The device login action could not be confirmed. Reconcile this same login before starting another.', false);
      }
      const challenge = deviceChallengeSchema.safeParse(challengeRaw);
      if (!challenge.success || challenge.data.loginId !== loginId || challenge.data.targetId !== body.targetId || challenge.data.providerId !== selectedProvider) {
        fail('outcome_unknown', 'The execution target returned an invalid device login receipt. Reconcile this same login before starting another.', false);
      }
      // A challenge is not authority. Reauthenticate after its asynchronous round
      // trip, then inspect revocation/generation inside the issuance transaction.
      const currentActor = await currentOwner(context);
      const currentMachine = target(context);
      if ((currentMachine?.nodeId ?? null) !== listing.target.nodeId) fail('conflict', 'The execution target changed. Reload provider settings before continuing.');
      pinProviderLoginAuthority(services, currentActor, currentMachine, boundParams, generation);
      if (challenge.data.challengeNonce === null) {
        const { challengeNonce: _, ...publicResult } = challenge.data;
        return publicResult;
      }
      completion = authorizeProviderCompletion(services, currentActor, currentMachine, boundParams, context.request, generation, challenge.data.challengeNonce);
    }
    const requestParams = completion?.params ?? boundParams;
    let raw: unknown;
    try {
      raw = await services.lemon.call(rpc, requestParams, { mutation: true, resourceIds: machine ? [machine.id] : [] });
    } catch (error) {
      if (completion && definitiveProviderCompletionRejection(error)) services.store.remove(providerCompletionCollection, completion.id);
      if (error instanceof ApiError) throw new ApiError(error.code, 'The execution target could not confirm this device login action. Reconcile this same login before starting another.', error.retrySafe);
      fail('outcome_unknown', 'The device login action could not be confirmed. Reconcile this same login before starting another.', false);
    }
    // Only the exact target acknowledgement settles the fixed completion.
    // Malformed/lost results retain the journal, but never obstruct revocation.
    const acknowledged = deviceResultSchema.safeParse(raw);
    if (acknowledged.success && acknowledged.data.loginId === loginId && acknowledged.data.targetId === body.targetId && acknowledged.data.providerId === selectedProvider && completion) {
      services.store.remove(providerCompletionCollection, completion.id);
    }
    await currentOwner(context);
    const currentMachine = target(context);
    if ((currentMachine?.nodeId ?? null) !== listing.target.nodeId) fail('conflict', 'The execution target changed. Reload provider settings before continuing.');
    if (!acknowledged.success || acknowledged.data.loginId !== loginId || acknowledged.data.targetId !== body.targetId || acknowledged.data.providerId !== selectedProvider) {
      fail('outcome_unknown', 'The execution target returned an invalid device login receipt. Reconcile this same login before starting another.', false);
    }
    return acknowledged.data;
  }
  return ['/instance', '/machines/:id'].flatMap(prefix => [
    { method: 'GET', path: `/v1${prefix}/providers`, auth: 'owner', handler: list },
    { method: 'PUT', path: `/v1${prefix}/providers/:providerId/api-key`, auth: 'owner', authorizeReplay, handler: context => change(context, 'api_key.set') },
    { method: 'POST', path: `/v1${prefix}/providers/:providerId/disconnect`, auth: 'owner', authorizeReplay, handler: context => change(context, 'disconnect') },
    { method: 'POST', path: `/v1${prefix}/providers/default`, auth: 'owner', authorizeReplay, handler: context => change(context, 'default.set') },
    { method: 'POST', path: `/v1${prefix}/providers/:providerId/device-login`, auth: 'owner', mutation: false, handler: context => device(context, 'start') },
    { method: 'POST', path: `/v1${prefix}/providers/:providerId/device-login/:loginId/poll`, auth: 'owner', mutation: false, handler: context => device(context, 'poll') },
    { method: 'POST', path: `/v1${prefix}/providers/:providerId/device-login/:loginId/cancel`, auth: 'owner', mutation: false, handler: context => device(context, 'cancel') },
  ] satisfies Route[]);
}
