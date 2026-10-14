import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../core/services';
import { ApiError } from '../core/errors';
import { fetchJson, pinnedUrl, randomToken, savePrivateMetadata, privateMetadata, sha256, secureEqual } from './common';

export interface OAuthState { id: string; providerId: string; userId: string; resourceId: string; state: string; verifier: string; redirectUri: string; clientRedirectUri: string | null; expiresAtMs: number; used: boolean }
export interface OAuthTokens { access_token: string; token_type: string; refresh_token?: string; expires_in?: number; scope?: string; providerData: unknown }
const tokens = z.object({ access_token: z.string().min(1), token_type: z.string().min(1), refresh_token: z.string().min(1).optional(), expires_in: z.number().positive().optional(), scope: z.string().optional() });
export function startOAuth(services: BackendServices, provider: P.OAuthProviderConfig, input: { userId: string; resourceId: string; callbackPath: string; clientRedirectUri?: string; extra?: Record<string, string> }): { flow: OAuthState; authorizationUrl: string } {
  const redirectUri = new URL(input.callbackPath, services.config.publicUrl).href;
  if (!provider.redirectUris.includes(redirectUri)) throw new ApiError('capability_unavailable', 'Register the exact backend OAuth callback in the provider redirectUris configuration.');
  if (input.clientRedirectUri && !services.config.operator.oauthRedirectUris.includes(input.clientRedirectUri) && new URL(input.clientRedirectUri).origin !== new URL(services.config.publicUrl).origin) throw new ApiError('invalid_request', 'Client OAuth redirect is not allowlisted.');
  const authorize = pinnedUrl(provider.authorizeUrl, provider.allowedOrigins); pinnedUrl(provider.tokenUrl, provider.allowedOrigins);
  const flow: OAuthState = { id: services.id('oauth'), providerId: provider.id, userId: input.userId, resourceId: input.resourceId, state: randomToken(), verifier: randomToken(48), redirectUri, clientRedirectUri: input.clientRedirectUri ?? null, expiresAtMs: services.now() + 600000, used: false };
  for (const [key, value] of Object.entries(input.extra ?? {})) { if (['state', 'nonce', 'redirect_uri', 'client_id', 'code_challenge', 'code_challenge_method', 'response_type'].includes(key)) throw new ApiError('invalid_request', 'Reserved OAuth parameter cannot be replaced.'); authorize.searchParams.set(key, value); }
  authorize.searchParams.set('client_id', provider.clientId); authorize.searchParams.set('redirect_uri', redirectUri); authorize.searchParams.set('response_type', 'code'); authorize.searchParams.set('scope', provider.scopes.join(' ')); authorize.searchParams.set('state', flow.state); authorize.searchParams.set('code_challenge', sha256(flow.verifier)); authorize.searchParams.set('code_challenge_method', 'S256');
  savePrivateMetadata(services, `oauth:${sha256(flow.state)}`, flow);
  return { flow, authorizationUrl: authorize.href };
}
export function takeOAuthState(services: BackendServices, state: string, providerId?: string): OAuthState {
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(state)) throw new ApiError('unauthenticated', 'OAuth state is invalid.');
  return services.store.transaction(() => {
    const key = `oauth:${sha256(state)}`; const flow = privateMetadata<OAuthState>(services, key);
    if (!flow || !secureEqual(flow.state, state) || providerId && flow.providerId !== providerId) throw new ApiError('unauthenticated', 'OAuth state is invalid.');
    if (flow.expiresAtMs <= services.now()) throw new ApiError('expired', 'OAuth authorization expired.');
    if (flow.used) throw new ApiError('conflict', 'OAuth callback was already consumed.');
    flow.used = true; savePrivateMetadata(services, key, flow); return flow;
  });
}
export async function exchangeOAuth(services: BackendServices, provider: P.OAuthProviderConfig, flow: OAuthState, code: string, options: { tokenTypes?: string[]; clientAuthentication?: 'basic' | 'body' } = {}): Promise<OAuthTokens> {
  if (flow.providerId !== provider.id || !flow.used || flow.expiresAtMs <= services.now() || !code || code.length > 8192) throw new ApiError('unauthenticated', 'OAuth authorization cannot be exchanged.');
  const secret = await services.secret(provider.clientSecretRef);
  const form = new URLSearchParams({ grant_type: 'authorization_code', code, client_id: provider.clientId, redirect_uri: flow.redirectUri, code_verifier: flow.verifier });
  const headers: Record<string, string> = { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' };
  if (options.clientAuthentication === 'basic') headers.Authorization = `Basic ${Buffer.from(`${encodeURIComponent(provider.clientId)}:${encodeURIComponent(secret)}`).toString('base64')}`;
  else form.set('client_secret', secret);
  const result = await fetchJson(provider.tokenUrl, { method: 'POST', headers, body: form }, { allowedOrigins: provider.allowedOrigins, mutation: true });
  const parsed = tokens.safeParse(result); if (!parsed.success || !(options.tokenTypes ?? ['bearer']).includes(parsed.data.token_type.toLowerCase())) throw new ApiError('upstream_unavailable', 'Provider did not return a supported bearer credential.', false);
  return { ...parsed.data, providerData: result };
}
