import type * as P from '../../../contracts/protocol';
import type { BackendServices, EntityStore, Principal } from './services';
import { ApiError, fail } from './errors';
import { hasProductAccess } from '../enterprise/policy';
import { z } from 'zod';
import { nonce } from './validation';

/** Durable, nonsecret reconciliation journal, never a reservation of authority.
 * Unknown fixed completion IDs survive expiry/restart and are never retried.
 */
export interface ProviderCompletion {
  id: string;
  userId: string;
  sessionId: string;
  deviceId: string | null;
  workspaceId: string;
  machineId: string | null;
  authorityGeneration: number;
  params: Record<string, unknown>;
}
export const providerCompletionCollection = 'providerCompletions';
const authorityGenerationKey = 'providerAuthorityGeneration';
const deviceResultFields = z.object({
  loginId: nonce,
  targetId: z.string().min(1).max(256).regex(/^[A-Za-z0-9_.:-]+$/),
  providerId: z.literal('openai_codex'),
  status: z.enum(['starting', 'pending', 'completed', 'denied', 'expired', 'cancelled', 'lost', 'failed']),
  verificationUrl: z.literal('https://auth.openai.com/codex/device').nullable(),
  userCode: z.string().min(1).max(64).regex(/^[A-Za-z0-9-]+$/).nullable(),
  expiresAtMs: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).nullable(),
  pollIntervalMs: z.number().int().min(1000).max(60_000).nullable(),
}).strict();
const validDeviceFields = (value: z.infer<typeof deviceResultFields>) => value.status === 'pending'
  ? value.verificationUrl !== null && value.userCode !== null && value.expiresAtMs !== null && value.pollIntervalMs !== null
  : value.verificationUrl === null && value.userCode === null && value.expiresAtMs === null && value.pollIntervalMs === null;
export const deviceResultSchema = deviceResultFields.refine(validDeviceFields);
export const deviceChallengeSchema = deviceResultFields.extend({
  challengeNonce: z.string().regex(/^[A-Za-z0-9_-]{43}$/).nullable(),
}).strict().refine(value => validDeviceFields(value) && (value.challengeNonce === null || value.status === 'pending'));
const completionSchema = z.object({
  id: z.string().min(1), userId: z.string().min(1), sessionId: z.string().min(1),
  deviceId: z.string().min(1).nullable(), workspaceId: z.string().min(1),
  machineId: z.string().min(1).nullable(), authorityGeneration: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER),
  params: z.record(z.string(), z.unknown()),
}).strict();
const completionsIn = (store: EntityStore) => store.list(providerCompletionCollection).map(value => completionSchema.parse(value));

export const providerAuthorityGeneration = (store: EntityStore): number => store.metadata<number>(authorityGenerationKey) ?? 0;

export function definitiveProviderCompletionRejection(error: unknown): boolean {
  return error instanceof ApiError && error.code === 'forbidden' && error.retrySafe === false
    && error.details?.reason === 'provider_binding_rejected' && error.details.mutationMayHaveApplied === false;
}
const object = (value: unknown): Record<string, unknown> => value !== null && typeof value === 'object' ? value as Record<string, unknown> : {};
const fields = (value: unknown, keys: string[]) => { const row = object(value); return keys.map(key => row[key]); };

/** Advance durable issuance authority in the same transaction as each change.
 * This never reads the completion journal or waits for a controller/target:
 * revocation and re-pairing must work immediately, including while offline.
 */
export function recordProviderAuthorityChange(store: EntityStore, collection: string, id: string, next: unknown): void {
  let keys: string[] | null;
  switch (collection) {
    case 'users': keys = ['id']; break;
    case 'members': keys = ['id', 'userId', 'enabled', 'role']; break;
    case 'workspaces': keys = ['id', 'enabled', 'ownerUserId']; break;
    case 'authSessions': keys = ['id', 'userId', 'deviceId', 'expiresAtMs']; break;
    case 'sessionSecrets': keys = ['id', 'tokenDigest', 'revoked']; break;
    case 'devices': keys = ['id', 'userId']; break;
    case 'machines': keys = ['id', 'nodeId', 'ownerUserId', 'status']; break;
    case 'directoryGroups': case 'groupPolicies': keys = null; break;
    case '$metadata':
      if (id !== 'workspaceId' && id !== 'governance' && !id.startsWith('accountDeletion:')) return;
      keys = null; break;
    default: return;
  }
  const previous = collection === '$metadata' ? store.metadata(id) : store.get(collection, id);
  if (JSON.stringify(keys ? fields(previous, keys) : previous) !== JSON.stringify(keys ? fields(next, keys) : next)) {
    store.setMetadata(authorityGenerationKey, providerAuthorityGeneration(store) + 1);
    let scopes: string[];
    switch (collection) {
      case 'users': scopes = [`user:${id}`]; break;
      case 'members': scopes = [object(previous).userId, object(next).userId].filter((value): value is string => typeof value === 'string').map(value => `user:${value}`); break;
      case 'workspaces': scopes = [`workspace:${id}`]; break;
      case 'authSessions': case 'sessionSecrets': scopes = [`session:${id}`]; break;
      case 'devices': scopes = [`device:${id}`]; break;
      case 'machines': scopes = [`machine:${id}`]; break;
      case '$metadata': scopes = id.startsWith('accountDeletion:') ? [`user:${id.slice('accountDeletion:'.length)}`] : ['policy']; break;
      default: scopes = ['policy'];
    }
    const generation = providerAuthorityGeneration(store);
    for (const scope of new Set(scopes)) store.setMetadata(`providerAuthority:${scope}`, generation);
  }
}

/** Pin this exact login binding to its durable revocation generations. A restored
 * role/session/device/target is a new authority, never revival of an old login.
 * Unrelated sessions and owners do not invalidate this binding.
 */
export function pinProviderLoginAuthority(services: BackendServices, actor: Principal, machine: P.Machine | null, params: Record<string, unknown>, generation: number): void {
  services.store.transaction(() => {
    if (providerAuthorityGeneration(services.store) !== generation) fail('conflict', 'Provider authority changed during this request. Reload provider settings before continuing.', false);
    const scopes = ['policy', `workspace:${actor.workspaceId}`, `user:${actor.userId}`, `session:${actor.sessionId}`, ...(actor.deviceId ? [`device:${actor.deviceId}`] : []), ...(machine ? [`machine:${machine.id}`] : [])];
    const authority = JSON.stringify(scopes.map(scope => services.store.metadata<number>(`providerAuthority:${scope}`) ?? 0));
    const id = services.mutations.digest(JSON.stringify([params.targetId, params.providerId, params.loginId, params.ownerId, params.sessionId]));
    const previous = services.store.get<{ id: string; authority: string }>('providerLoginAuthorities', id);
    if (previous && previous.authority !== authority) fail('forbidden', 'This provider login authority was revoked. Start a new device login.', false);
    if (!previous) services.store.put('providerLoginAuthorities', { id, authority });
  });
}

export function authorizeProviderCompletion(services: BackendServices, actor: Principal, machine: P.Machine | null, params: Record<string, unknown>, request: Request, generation: number, challengeNonce: string): ProviderCompletion {
  return services.store.transaction(() => {
    services.auth.requireRole(actor, 'owner');
    if (!hasProductAccess(services, actor.userId)) fail('policy_denied', 'Workspace or directory policy denies provider management.');
    const session = actor.sessionId ? services.store.get<P.AuthSession>('authSessions', actor.sessionId) : null;
    const secret = session ? services.store.get<{ revoked: boolean; tokenDigest: string }>('sessionSecrets', session.id) : null;
    const bearer = /^Bearer ([A-Za-z0-9_-]{16,512})$/i.exec(request.headers.get('authorization') ?? '');
    const now = services.now();
    if (actor.kind !== 'user' || !session || !secret || secret.revoked || !bearer || secret.tokenDigest !== services.mutations.digest(bearer[1]) || session.userId !== actor.userId || session.deviceId !== actor.deviceId || session.expiresAtMs === null && session.deviceId === null || session.expiresAtMs !== null && session.expiresAtMs <= now || session.deviceId !== null && services.store.get<P.Device>('devices', session.deviceId)?.userId !== actor.userId || !services.store.get('users', actor.userId)) fail('unauthenticated', 'The initiating owner session or device was revoked.');
    if (providerAuthorityGeneration(services.store) !== generation) fail('conflict', 'Provider authority changed during this request. Reload provider settings before continuing.', false);
    if (machine) {
      const current = services.auth.machine(actor, machine.id, true);
      if (current.ownerUserId !== actor.userId || current.status !== 'online' || current.nodeId !== params.nodeId) fail('conflict', 'The execution target authority changed.');
    }
    pinProviderLoginAuthority(services, actor, machine, params, generation);
    const pending = completionsIn(services.store);
    if (pending.some(value => value.params.targetId === params.targetId && value.params.providerId === params.providerId && value.params.loginId === params.loginId)) {
      fail('outcome_unknown', 'This login has an unresolved completion. Reconcile its fixed completion before authorizing another.', false);
    }
    if (pending.length >= 128) fail('conflict', 'Provider completion reconciliation capacity is full. Reconcile pending sign-ins first.', false);
    // The destination's existing monotonic challenge bounds this single use.
    // Revocation stops subsequent issuance, not a write already authorized in flight.
    const id = services.id('provider_completion');
    const completion: ProviderCompletion = {
      id, userId: actor.userId, sessionId: session.id, deviceId: actor.deviceId,
      workspaceId: actor.workspaceId, machineId: machine?.id ?? null, authorityGeneration: generation,
      params: { ...params, completionId: id, challengeNonce: '', commit: false },
    };
    // Persist only settlement identity: restart must never restore a challenge or
    // an authorization that could be replayed as a write.
    services.store.put(providerCompletionCollection, completion);
    return { ...completion, params: { ...completion.params, challengeNonce, commit: true } };
  });
}

/** Non-writing settlement consumes only the SAME completion ID and login binding.
 * It must remain reachable after session/device/generation revocation, and makes a
 * delayed write for that ID inert. No local timeout is proof of target settlement.
 */
export async function settleProviderCompletions(services: BackendServices): Promise<void> {
  for (const completion of completionsIn(services.store)) {
    const method = `${completion.machineId ? 'node.' : ''}providers.management.device.complete`;
    if (!services.lemon.connected || !services.lemon.methods.includes(method)) continue;
    try {
      const result = deviceResultSchema.safeParse(await services.lemon.call(method, { ...completion.params, commit: false }, { mutation: true, resourceIds: completion.machineId ? [completion.machineId] : [] }));
      if (result.success && result.data.loginId === completion.params.loginId && result.data.targetId === completion.params.targetId && result.data.providerId === completion.params.providerId) services.store.remove(providerCompletionCollection, completion.id);
    } catch (error) {
      // Only an immutable binding mismatch also proves the original request could
      // never match. Generic pre-dispatch rejection says nothing about that write.
      if (definitiveProviderCompletionRejection(error)) services.store.remove(providerCompletionCollection, completion.id);
    }
  }
}
