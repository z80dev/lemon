import { timingSafeEqual } from 'node:crypto';
import type { BackendServices, MutationService } from './services';
import { opaqueToken } from './auth';
import { ApiError, fail } from './errors';

export type OwnerSetupServices = Pick<BackendServices, 'store' | 'now' | 'encrypt' | 'decrypt'> & { mutations: Pick<MutationService, 'digest'> };
export const ownerSetupLifetimeMs = 5 * 60 * 1000;
export const ownerSetupAttemptLimit = 10;
interface SetupState { expiresAtMs: number; attempts: number }

function emptyInstance(services: OwnerSetupServices): void {
  if (services.store.metadata('workspaceId') !== null) fail('conflict', 'Workspace is already configured. Sign in with the existing account.');
}
function state(services: OwnerSetupServices): SetupState | null {
  const value = services.store.metadata<SetupState>('setupCodeState');
  return value && Number.isSafeInteger(value.expiresAtMs) && value.expiresAtMs > 0
    && Number.isSafeInteger(value.attempts) && value.attempts >= 0 ? value : null;
}
function matches(services: OwnerSetupServices, code: string): boolean {
  const expected = services.store.metadata<string>('setupCodeDigest');
  const actual = services.mutations.digest(code);
  return typeof expected === 'string' && expected.length === actual.length
    && timingSafeEqual(Buffer.from(expected), Buffer.from(actual));
}

/** Trusted local operator only; never install an HTTP route for proof issuance/retrieval. */
export function issueOwnerSetupProof(services: OwnerSetupServices): { code: string; expiresAtMs: number } {
  return services.store.transaction(() => {
    emptyInstance(services);
    const current = state(services);
    const encrypted = services.store.metadata<string>('setupCode');
    if (current && current.expiresAtMs > services.now() && current.attempts < ownerSetupAttemptLimit && encrypted) {
      const code = services.decrypt<string>(encrypted);
      if (typeof code !== 'string' || !matches(services, code)) fail('internal_error', 'Private setup state could not be verified.', false);
      return { code, expiresAtMs: current.expiresAtMs };
    }
    // Legacy proofs without an absolute deadline are never accepted or extended.
    const code = opaqueToken();
    const expiresAtMs = services.now() + ownerSetupLifetimeMs;
    services.store.setMetadata('setupCode', services.encrypt(code));
    services.store.setMetadata('setupCodeDigest', services.mutations.digest(code));
    services.store.setMetadata('setupCodeState', { expiresAtMs, attempts: 0 } satisfies SetupState);
    return { code, expiresAtMs };
  });
}

/** Persist the attempt before password hashing; rejecting must not roll its increment back. */
export function beginOwnerSetupClaim(services: OwnerSetupServices, code: string): void {
  const error = services.store.transaction(() => {
    emptyInstance(services);
    const current = state(services);
    if (!current || current.expiresAtMs <= services.now()) return new ApiError('expired', 'Owner setup proof expired. Ask the local operator to run lemon-bot setup.');
    if (current.attempts >= ownerSetupAttemptLimit) return new ApiError('rate_limited', 'Owner setup attempt limit reached. Ask the local operator for a new proof.');
    services.store.setMetadata('setupCodeState', { ...current, attempts: current.attempts + 1 });
    if (!matches(services, code)) return new ApiError('unauthenticated', 'Invalid setup code.');
    return null;
  });
  if (error) throw error;
}

/** Call inside the same transaction that creates owner/workspace/session, after any async work. */
export function consumeOwnerSetupProof(services: OwnerSetupServices, code: string): void {
  emptyInstance(services);
  const current = state(services);
  if (!current || current.expiresAtMs <= services.now()) fail('expired', 'Owner setup proof expired. Ask the local operator to run lemon-bot setup.');
  if (!matches(services, code)) fail('unauthenticated', 'Invalid setup code.');
  services.store.setMetadata('setupCode', null);
  services.store.setMetadata('setupCodeDigest', null);
  services.store.setMetadata('setupCodeState', null);
}
