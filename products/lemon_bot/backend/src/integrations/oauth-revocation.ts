import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../core/services';
import { ApiError } from '../core/errors';
import { boundedBytes, fetchJson, providerRequest } from './common';
import { oauthTokenClientDigest, type OAuthCompletion, type OAuthTokens } from './oauth';
interface TokenReceipt { state: 'pending' | 'dispatching' | 'revoked' | 'failed' | 'outcome_unknown'; errorCode: P.ErrorCode | null }
export interface OAuthRevocationReceipt { id: string; userId: string; providerId: string; resourceId: string; callbackPath: string; updatedAtMs: number; access: TokenReceipt; refresh: TokenReceipt | null }
async function authenticatedForm(services: BackendServices, provider: P.OAuthProviderConfig, fields: Record<string, string>): Promise<{ headers: Record<string, string>; body: URLSearchParams }> {
  const secret = await services.secret(provider.clientSecretRef); const body = new URLSearchParams(fields);
  const headers: Record<string, string> = { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' };
  if (provider.clientAuthentication === 'basic') headers.Authorization = `Basic ${Buffer.from(`${encodeURIComponent(provider.clientId)}:${encodeURIComponent(secret)}`).toString('base64')}`;
  else { body.set('client_id', provider.clientId); body.set('client_secret', secret); }
  return { headers, body };
}
export async function revokeOAuthCompletion(services: BackendServices, provider: P.OAuthProviderConfig, completion: OAuthCompletion): Promise<OAuthRevocationReceipt> {
  if (provider.id !== completion.providerId || completion.tokenClientDigest !== oauthTokenClientDigest(provider)) throw new ApiError('forbidden', 'OAuth cleanup must use the exact original token issuer, client and approved credential association.');
  const tokens = services.decrypt<OAuthTokens>(completion.encryptedTokens);
  let receipt = services.store.get<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id);
  if (!receipt) receipt = services.store.put('oauthRevocationReceipts', { id: completion.id, userId: completion.userId, providerId: completion.providerId, resourceId: completion.resourceId, callbackPath: completion.callbackPath, updatedAtMs: services.now(), access: { state: 'pending', errorCode: null }, refresh: tokens.refresh_token ? { state: 'pending', errorCode: null } : null } satisfies OAuthRevocationReceipt);
  for (const kind of ['access', 'refresh'] as const) {
    const token = kind === 'access' ? tokens.access_token : tokens.refresh_token; if (!token) continue;
    const current = services.store.require<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id); const entry = current[kind];
    if (!entry || entry.state !== 'pending') continue;
    let dispatched = false;
    try {
      if (!provider.revocationUrl) throw new ApiError('capability_unavailable', 'Configure this OAuth provider revocationUrl; no revocation endpoint is inferred.');
      const request = await authenticatedForm(services, provider, { token, token_type_hint: kind === 'access' ? 'access_token' : 'refresh_token' });
      services.store.put('oauthRevocationReceipts', { ...current, [kind]: { state: 'dispatching', errorCode: null }, updatedAtMs: services.now() }); dispatched = true;
      const response = await providerRequest(provider.revocationUrl, { method: 'POST', ...request }, { allowedOrigins: provider.allowedOrigins, mutation: true });
      const bytes = await boundedBytes(response, 65536);
      if (response.status !== 200) throw new ApiError(response.status === 401 || response.status === 403 ? 'capability_unavailable' : 'upstream_unavailable', 'OAuth revocation was not acknowledged.', response.status < 500);
      if (bytes.length) { let value: unknown; try { value = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new ApiError('outcome_unknown', 'OAuth revocation acknowledgment is malformed.', false); } if (value && typeof value === 'object' && 'error' in value) throw new ApiError('outcome_unknown', 'OAuth provider returned an error instead of a revocation acknowledgment.', false); }
      const latest = services.store.require<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id);
      services.store.put('oauthRevocationReceipts', { ...latest, [kind]: { state: 'revoked', errorCode: null }, updatedAtMs: services.now() });
    } catch (error) {
      const latest = services.store.require<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id);
      services.store.put('oauthRevocationReceipts', { ...latest, [kind]: { state: dispatched ? 'outcome_unknown' : 'failed', errorCode: error instanceof ApiError ? error.code : 'upstream_unavailable' }, updatedAtMs: services.now() });
    }
  }
  receipt = services.store.require<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id);
  if (receipt.access.state === 'revoked' && (!receipt.refresh || receipt.refresh.state === 'revoked')) services.store.remove('oauthCompletions', completion.id);
  return receipt;
}
export async function reconcileOAuthRevocation(services: BackendServices, provider: P.OAuthProviderConfig, completion: OAuthCompletion): Promise<OAuthRevocationReceipt | null> {
  if (provider.id !== completion.providerId || completion.tokenClientDigest !== oauthTokenClientDigest(provider)) throw new ApiError('forbidden', 'OAuth observation must use the exact original token issuer, client and approved credential association.');
  let receipt = services.store.get<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id); if (!receipt || provider.id !== completion.providerId || !provider.introspectionUrl) return receipt;
  const tokens = services.decrypt<OAuthTokens>(completion.encryptedTokens);
  for (const kind of ['access', 'refresh'] as const) {
    const token = kind === 'access' ? tokens.access_token : tokens.refresh_token; const entry = receipt[kind];
    if (!token || !entry || entry.state === 'revoked') continue;
    const request = await authenticatedForm(services, provider, { token, token_type_hint: kind === 'access' ? 'access_token' : 'refresh_token' });
    const value = z.object({ active: z.boolean(), client_id: z.string().optional() }).passthrough().safeParse(await fetchJson(provider.introspectionUrl, { method: 'POST', ...request }, { allowedOrigins: provider.allowedOrigins }));
    if (!value.success || value.data.active && value.data.client_id !== undefined && value.data.client_id !== provider.clientId) throw new ApiError('upstream_unavailable', 'OAuth introspection returned an invalid credential scope.');
    if (!value.data.active) { receipt = { ...receipt, [kind]: { state: 'revoked', errorCode: null }, updatedAtMs: services.now() }; services.store.put('oauthRevocationReceipts', receipt); }
  }
  if (receipt.access.state === 'revoked' && (!receipt.refresh || receipt.refresh.state === 'revoked')) services.store.remove('oauthCompletions', completion.id);
  return receipt;
}
