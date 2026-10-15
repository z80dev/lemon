import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../core/services';
import { ApiError } from '../core/errors';
import { assertActiveAccount, fetchJson, pinnedUrl, randomToken, savePrivateMetadata, privateMetadata, sha256, secureEqual } from './common';

export interface OAuthState { id: string; providerId: string; userId: string; resourceId: string; state: string; verifier: string; redirectUri: string; clientRedirectUri: string | null; expiresAtMs: number; used: boolean }
export interface OAuthTokens { access_token: string; token_type: string; refresh_token?: string; expires_in?: number; scope?: string; providerData: unknown }
export interface OAuthCompletion { id: string; userId: string; providerId: string; resourceId: string; callbackPath: string; encryptedTokens: string; tokenClientDigest: string; createdAtMs: number; state: 'issued' | 'outcome_unknown' }
export interface OAuthExchangeOperation { id: string; userId: string; providerId: string; resourceId: string; callbackPath: string; tokenClientDigest: string; state: 'pending' | 'dispatching' | 'issued' | 'failed' | 'outcome_unknown'; refreshIssued?: boolean; createdAtMs: number }
const lateCleanup = new WeakMap<BackendServices, (completion: OAuthCompletion) => Promise<void>>();
export function registerOAuthLateCleanup(s: BackendServices, handler: (completion: OAuthCompletion) => Promise<void>): void { lateCleanup.set(s, handler); }
export function oauthTokenClientDigest(provider: P.OAuthProviderConfig): string { return sha256(JSON.stringify([provider.id, provider.clientId, provider.clientSecretRef, provider.tokenUrl])); }
const tokens = z.object({ access_token: z.string().min(1), token_type: z.string().min(1), refresh_token: z.string().min(1).optional(), expires_in: z.number().positive().optional(), scope: z.string().optional() });
export function startOAuth(services: BackendServices, provider: P.OAuthProviderConfig, input: { userId: string; resourceId: string; callbackPath: string; clientRedirectUri?: string; extra?: Record<string, string> }): { flow: OAuthState; authorizationUrl: string } {
  assertActiveAccount(services, input.userId);
  const redirectUri = new URL(input.callbackPath, services.config.publicUrl).href;
  if (!provider.redirectUris.includes(redirectUri)) throw new ApiError('capability_unavailable', 'Register the exact backend OAuth callback in the provider redirectUris configuration.');
  if (input.clientRedirectUri && !services.config.operator.oauthRedirectUris.includes(input.clientRedirectUri) && new URL(input.clientRedirectUri).origin !== new URL(services.config.publicUrl).origin) throw new ApiError('invalid_request', 'Client OAuth redirect is not allowlisted.');
  const authorize = pinnedUrl(provider.authorizeUrl, provider.allowedOrigins); pinnedUrl(provider.tokenUrl, provider.allowedOrigins);
  const flow: OAuthState = { id: services.id('oauth'), providerId: provider.id, userId: input.userId, resourceId: input.resourceId, state: randomToken(), verifier: randomToken(48), redirectUri, clientRedirectUri: input.clientRedirectUri ?? null, expiresAtMs: services.now() + 600000, used: false };
  for (const [key, value] of Object.entries(input.extra ?? {})) { if (['state', 'nonce', 'redirect_uri', 'client_id', 'code_challenge', 'code_challenge_method', 'response_type'].includes(key)) throw new ApiError('invalid_request', 'Reserved OAuth parameter cannot be replaced.'); authorize.searchParams.set(key, value); }
  authorize.searchParams.set('client_id', provider.clientId); authorize.searchParams.set('redirect_uri', redirectUri); authorize.searchParams.set('response_type', 'code'); authorize.searchParams.set('scope', provider.scopes.join(' ')); authorize.searchParams.set('state', flow.state); authorize.searchParams.set('code_challenge', sha256(flow.verifier)); authorize.searchParams.set('code_challenge_method', 'S256');
  services.store.transaction(() => {
    const key = `oauth:${sha256(flow.state)}`; savePrivateMetadata(services, key, flow);
    const keys = services.store.metadata<string[]>(`oauthStateKeys:${input.userId}`) ?? [];
    services.store.setMetadata(`oauthStateKeys:${input.userId}`, [...keys, key]);
  });
  return { flow, authorizationUrl: authorize.href };
}
export function takeOAuthState(services: BackendServices, state: string, providerId?: string): OAuthState {
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(state)) throw new ApiError('unauthenticated', 'OAuth state is invalid.');
  return services.store.transaction(() => {
    const key = `oauth:${sha256(state)}`; const flow = privateMetadata<OAuthState>(services, key);
    if (!flow || !secureEqual(flow.state, state) || providerId && flow.providerId !== providerId) throw new ApiError('unauthenticated', 'OAuth state is invalid.');
    if (flow.expiresAtMs <= services.now()) throw new ApiError('expired', 'OAuth authorization expired.');
    if (flow.used) throw new ApiError('conflict', 'OAuth callback was already consumed.');
    assertActiveAccount(services, flow.userId);
    flow.used = true; savePrivateMetadata(services, key, flow); return flow;
  });
}
export async function exchangeOAuth(services: BackendServices, provider: P.OAuthProviderConfig, flow: OAuthState, code: string, options: { tokenTypes?: string[]; clientAuthentication?: 'basic' | 'body' } = {}): Promise<OAuthTokens> {
  assertActiveAccount(services, flow.userId);
  if (flow.providerId !== provider.id || !flow.used || flow.expiresAtMs <= services.now() || !code || code.length > 8192) throw new ApiError('unauthenticated', 'OAuth authorization cannot be exchanged.');
  const operation: OAuthExchangeOperation = { id: flow.id, userId: flow.userId, providerId: flow.providerId, resourceId: flow.resourceId, callbackPath: new URL(flow.redirectUri).pathname, tokenClientDigest: oauthTokenClientDigest(provider), state: 'pending', createdAtMs: services.now() };
  services.store.put('oauthExchangeOperations', operation);
  let dispatched = false;
  try {
    const secret = await services.secret(provider.clientSecretRef);
    const form = new URLSearchParams({ grant_type: 'authorization_code', code, client_id: provider.clientId, redirect_uri: flow.redirectUri, code_verifier: flow.verifier });
    const headers: Record<string, string> = { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' };
    if ((options.clientAuthentication ?? provider.clientAuthentication) === 'basic') headers.Authorization = `Basic ${Buffer.from(`${encodeURIComponent(provider.clientId)}:${encodeURIComponent(secret)}`).toString('base64')}`;
    else form.set('client_secret', secret);
    const result = await fetchJson(provider.tokenUrl, { method: 'POST', headers, body: form }, { allowedOrigins: provider.allowedOrigins, mutation: true, beforeDispatch: () => { assertActiveAccount(services, flow.userId); dispatched = true; services.store.put('oauthExchangeOperations', { ...operation, state: 'dispatching' }); }, fetch: services.http });
    const parsed = tokens.safeParse(result);
    if (!parsed.success) throw new ApiError('upstream_unavailable', 'Provider did not return a supported bearer credential.', false);
    const completion: OAuthCompletion = { id: flow.id, userId: flow.userId, providerId: flow.providerId, resourceId: flow.resourceId, callbackPath: operation.callbackPath, encryptedTokens: services.encrypt({ ...parsed.data, providerData: result }), tokenClientDigest: operation.tokenClientDigest, createdAtMs: services.now(), state: 'issued' };
    services.store.put('oauthCompletions', completion);
    services.store.put('oauthExchangeOperations', { ...operation, state: 'issued', refreshIssued: !!parsed.data.refresh_token });
    if (services.store.metadata(`accountDeletion:${flow.userId}`)) {
      await lateCleanup.get(services)?.(completion);
      assertActiveAccount(services, flow.userId, true);
    }
    if (!(options.tokenTypes ?? ['bearer']).includes(parsed.data.token_type.toLowerCase())) throw new ApiError('upstream_unavailable', 'Provider did not return a supported bearer credential.', false);
    savePrivateMetadata(services, `oauth:${sha256(flow.state)}`, { ...flow, verifier: '' });
    return { ...parsed.data, providerData: result };
  } catch (error) {
    if (services.store.require<OAuthExchangeOperation>('oauthExchangeOperations', flow.id).state !== 'issued') services.store.put('oauthExchangeOperations', { ...operation, state: dispatched ? 'outcome_unknown' : 'failed' });
    throw error;
  }
}

export function clearOAuthUserState(services: BackendServices, userId: string): void {
  for (const key of services.store.metadata<string[]>(`oauthStateKeys:${userId}`) ?? []) services.store.setMetadata(key, null);
  services.store.setMetadata(`oauthStateKeys:${userId}`, null);
}

export function reconcileOAuthStates(services: BackendServices): void {
  for (const user of services.store.list<P.User>('users')) {
    const index = `oauthStateKeys:${user.id}`; const retained: string[] = [];
    for (const key of services.store.metadata<string[]>(index) ?? []) {
      const flow = privateMetadata<OAuthState>(services, key);
      if (!flow || flow.expiresAtMs <= services.now()) services.store.setMetadata(key, null);
      else retained.push(key);
    }
    services.store.setMetadata(index, retained);
  }
}

export function markOAuthInstalled(services: BackendServices, flowId: string): void {
  if (!services.store.get<OAuthCompletion>('oauthCompletions', flowId)) throw new ApiError('outcome_unknown', 'OAuth credential installation has no durable completion record.', false);
  services.store.remove('oauthCompletions', flowId);
  services.store.remove('oauthExchangeOperations', flowId);
}
