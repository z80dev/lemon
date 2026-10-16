import type * as P from '../../../contracts/protocol';
import type { BackendServices, RequestContext, Route } from './services';
import { ApiError, fail } from './errors';
import { z, parse, principal, mutation, queryObject } from './validation';
import { hasProductAccess } from '../enterprise/policy';

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
  async function list(context: RequestContext): Promise<P.ProviderManagement> {
    parse(z.object({}).strict(), queryObject(context.query));
    const machine = target(context);
    const raw = await services.lemon.call(method(machine, 'list'), machine ? { nodeId: machine.nodeId! } : {});
    const actor = await services.auth.authenticate(context.request, 'owner');
    if (!actor || actor.userId !== context.user?.userId || actor.workspaceId !== context.user.workspaceId) fail('unauthenticated', 'The owner session changed. Sign in again.');
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
  return ['/instance', '/machines/:id'].flatMap(prefix => [
    { method: 'GET', path: `/v1${prefix}/providers`, auth: 'owner', handler: list },
    { method: 'PUT', path: `/v1${prefix}/providers/:providerId/api-key`, auth: 'owner', authorizeReplay, handler: context => change(context, 'api_key.set') },
    { method: 'POST', path: `/v1${prefix}/providers/:providerId/disconnect`, auth: 'owner', authorizeReplay, handler: context => change(context, 'disconnect') },
    { method: 'POST', path: `/v1${prefix}/providers/default`, auth: 'owner', authorizeReplay, handler: context => change(context, 'default.set') },
  ] satisfies Route[]);
}
