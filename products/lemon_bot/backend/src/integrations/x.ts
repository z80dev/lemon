import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { IntegrationError, assertActiveAccount, fetchJson, privateMetadata, safeSummary, savePrivateMetadata } from './common';
import { exchangeOAuth, markOAuthInstalled, oauthTokenClientDigest, startOAuth, takeOAuthState } from './oauth';
import type { OAuthCompletion, OAuthTokens } from './oauth';
import { providerRequest } from './channels';
import { dedupeIngress, hmac, id, ignored, jsonObject, nonce, parse, principalFor, providerResult, rawBody, requireUser, untrusted, updateBody, verifyIngress } from './channel-security';

interface XCredential { accessToken: string; refreshToken: string | null; expiresAtMs: number | null; scopes: string[]; tokenClientDigest: string }
interface XConfirmation { id: string; deliveryId: string; postId: string; text: string; startedAtMs: number; state: 'reserved' | 'confirmed' | 'outcome_unknown'; providerMessageId: string | null }
interface XRevocation { id: string; userId: string; providerId: string; resourceId: string; completionId: string | null; tokenType: 'access_token' | 'refresh_token'; tokenClientDigest: string; state: 'reserved' | 'revoked' | 'failed' | 'outcome_unknown' }
const connectBody = z.strictObject({ clientNonce: nonce, mainBotId: id, redirectUri: z.string().max(2048) });
const ingressBody = z.strictObject({ deliveryId: id, externalAccountId: id, mentionPostId: id, mentionedHandle: z.string().min(1).max(64), text: z.string().max(65536), repliedPost: jsonObject.optional(), quotedPosts: z.array(jsonObject).max(10).optional(), mediaAttachmentIds: z.array(id).max(6).optional() });
const tweet = z.object({ id, author_id: id, text: z.string().max(65536), created_at: z.string(), entities: z.object({ mentions: z.array(z.object({ username: z.string().max(64) })).max(100).optional() }).optional(), attachments: z.object({ media_keys: z.array(id).max(6) }).optional(), geo: z.object({ country_code: z.string().length(2).optional() }).optional(), withheld: z.object({ country_codes: z.array(z.string()) }).optional() });
function providerFor(services: BackendServices): NonNullable<P.OperatorConfiguration['xProvider']> {
  const provider = services.config.operator.xProvider;
  if (!provider) throw new IntegrationError('capability_unavailable', 'Configure X OAuth, verified mention gateway, media/moderation and the public Bot identity.');
  return provider;
}
async function xPolicy(services: BackendServices, principal: Principal, botId?: string): Promise<void> {
  assertActiveAccount(services, principal.userId);
  const governance = services.store.list<P.Governance>('governance')[0] ?? services.store.metadata<P.Governance>('governance');
  if (!governance?.xMentionsEnabled || !(await services.integrations.effectivePolicy(principal, botId)).productAccess) throw new IntegrationError('policy_denied', 'X mentions are disabled by workspace access policy.');
}
function ownedMainBot(services: BackendServices, principal: Principal, botId: string): P.Bot {
  const bot = services.auth.bot(principal, botId);
  if (bot.ownerUserId !== principal.userId || bot.visibility !== 'personal') throw new IntegrationError('forbidden', 'X main Bot must be your own personal Bot.');
  services.auth.conversation(principal, bot.mainConversationId);
  return bot;
}
async function publicAccount(services: BackendServices): Promise<string> {
  const ref = services.config.operator?.xPublicAccountSecretRef;
  if (typeof ref !== 'string' || !ref) throw new IntegrationError('capability_unavailable', 'Configure xPublicAccountSecretRef for the public confirmation Bot account, separate from user OAuth.');
  const provider = providerFor(services); const token = await services.secret(ref);
  const identity = parse(z.object({ data: z.object({ id, username: z.string().max(64) }) }), await providerRequest(services, provider.apiBaseUrl, '2/users/me', token));
  if (identity.data.username.toLowerCase() !== provider.publicHandle.replace(/^@/, '').toLowerCase()) throw new IntegrationError('capability_unavailable', 'Public confirmation credential does not belong to the configured Bot handle.');
  return token;
}
async function postPublic(services: BackendServices, postId: string, text: string, token: string): Promise<string> {
  const provider = providerFor(services);
  const result = providerResult(z.object({ data: z.object({ id }) }), await providerRequest(services, provider.apiBaseUrl, '2/tweets', token, 'POST', { text, reply: { in_reply_to_tweet_id: postId } }), true);
  return result.data.id;
}
async function revokeCredential(services: BackendServices, userId: string, resourceId: string, credential: XCredential, completionId: string | null = null): Promise<void> {
  const provider = providerFor(services); const base = new URL(provider.apiBaseUrl); const url = new URL('2/oauth2/revoke', base.href.endsWith('/') ? base.href : base.href + '/');
  if (credential.tokenClientDigest !== oauthTokenClientDigest(provider.oauth)) throw new IntegrationError('capability_unavailable', 'Restore the original X OAuth client before revoking its credential.');
  let failure: unknown = null;
  for (const [tokenType, token] of [['access_token', credential.accessToken], ['refresh_token', credential.refreshToken]] as const) {
    if (!token) continue;
    const operationId = services.mutations.digest(['x_revoke', resourceId, tokenType, services.mutations.digest(token)]);
    const previous = services.store.get<XRevocation>('xRevocations', operationId);
    if (previous?.state === 'revoked') continue;
    if (previous) { failure ??= new IntegrationError('outcome_unknown', 'X revocation is reserved; query its provider receipt without redispatch.', false); continue; }
    const operation: XRevocation = { id: operationId, userId, providerId: provider.oauth.id, resourceId, completionId, tokenType, tokenClientDigest: credential.tokenClientDigest, state: 'reserved' }; services.store.put('xRevocations', operation);
    try {
      const clientSecret = await services.secret(provider.oauth.clientSecretRef);
      providerResult(z.object({ revoked: z.literal(true) }), await fetchJson(url.href, { method: 'POST', headers: { authorization: `Basic ${Buffer.from(`${encodeURIComponent(provider.oauth.clientId)}:${encodeURIComponent(clientSecret)}`).toString('base64')}`, 'content-type': 'application/x-www-form-urlencoded', 'x-lemon-operation-id': operationId }, body: new URLSearchParams({ token, token_type_hint: tokenType, client_id: provider.oauth.clientId }) }, { allowedOrigins: [base.origin], mutation: true, fetch: services.http }), true);
      services.store.put('xRevocations', { ...operation, state: 'revoked' });
    } catch (error) { failure ??= error; services.store.put('xRevocations', { ...operation, state: error instanceof IntegrationError && error.retrySafe ? 'failed' : 'outcome_unknown' }); }
  }
  if (failure) throw failure;
}
async function revokeConnection(services: BackendServices, connection: P.XConnection): Promise<void> {
  const credential = privateMetadata<XCredential>(services, `xCredential:${connection.id}`);
  if (!credential) return;
  await revokeCredential(services, connection.userId, connection.id, credential); services.store.setMetadata(`xCredential:${connection.id}`, null);
}

async function retireXCompletion(services: BackendServices, completion: OAuthCompletion): Promise<void> {
  const provider = providerFor(services);
  if (completion.callbackPath !== '/v1/x/oauth/callback' || completion.providerId !== provider.oauth.id || completion.tokenClientDigest !== oauthTokenClientDigest(provider.oauth)) throw new IntegrationError('capability_unavailable', 'Restore the exact X OAuth client to revoke its pending grant.');
  const tokens = services.decrypt<OAuthTokens>(completion.encryptedTokens);
  await revokeCredential(services, completion.userId, completion.resourceId, { accessToken: tokens.access_token, refreshToken: tokens.refresh_token ?? null, expiresAtMs: null, scopes: tokens.scope?.split(/\s+/) ?? [], tokenClientDigest: completion.tokenClientDigest }, completion.id);
  services.store.remove('oauthCompletions', completion.id); services.store.setMetadata(`xCredential:${completion.resourceId}`, null);
}

export interface XServices {
  inventory(): P.XProviderInfo | null;
  retireOAuthCompletion(completion: OAuthCompletion): Promise<void>;
  reconcileUserCleanup(userId: string, completion?: OAuthCompletion): Promise<boolean>;
  canReadResource(principal: Principal, collection: string, value: unknown): boolean | undefined;
  reconcile(): Promise<void>;
  retireUser(userId: string): Promise<void>;
}
const xInstances = new WeakMap<BackendServices, XServices>();
export function createXServices(services: BackendServices): XServices {
  const existing = xInstances.get(services); if (existing) return existing;
  const integration: XServices = {
    inventory: (): P.XProviderInfo | null => { const provider = services.config.operator.xProvider; return provider ? { id: provider.oauth.id, kind: 'x', label: 'X mentions', configured: typeof services.config.operator?.xPublicAccountSecretRef === 'string', prerequisites: typeof services.config.operator?.xPublicAccountSecretRef === 'string' ? [] : ['Configure public confirmation account credentials.'], capabilities: ['oauth_identity', 'explicit_own_mentions', 'private_main_bot', 'verified_media', 'provider_moderation'], publicHandle: provider.publicHandle, oauthScopes: provider.oauth.scopes, allowedMedia: provider.allowedMedia, deniedCountries: provider.deniedCountries } : null; },
    retireOAuthCompletion: (completion: OAuthCompletion): Promise<void> => retireXCompletion(services, completion),
    reconcileUserCleanup: async (userId: string, completion?: OAuthCompletion): Promise<boolean> => {
      let complete = true; const provider = services.config.operator.xProvider;
      const matches = (item: XRevocation): boolean => item.userId === userId && (!completion || item.completionId === completion.id && item.resourceId === completion.resourceId && item.providerId === completion.providerId);
      for (const operation of services.store.list<XRevocation>('xRevocations', item => matches(item) && item.state !== 'revoked')) {
        if (!provider || operation.providerId !== provider.oauth.id || operation.tokenClientDigest !== oauthTokenClientDigest(provider.oauth)) { complete = false; continue; }
        const result = providerResult(z.strictObject({ state: z.enum(['pending', 'revoked', 'failed']), tokenType: z.enum(['access_token', 'refresh_token']) }), await providerRequest(services, provider.apiBaseUrl, `revocations/${encodeURIComponent(operation.id)}`, await publicAccount(services)));
        if (result.tokenType !== operation.tokenType) throw new IntegrationError('upstream_unavailable', 'X cleanup receipt belongs to a different credential scope.');
        if (result.state !== 'revoked') { complete = false; if (result.state === 'failed') services.store.put('xRevocations', { ...operation, state: 'failed' }); continue; }
        services.store.put('xRevocations', { ...operation, state: 'revoked' });
      }
      if (complete) {
        for (const operation of services.store.list<XRevocation>('xRevocations', matches)) { services.store.setMetadata(`xCredential:${operation.resourceId}`, null); services.store.setMetadata(`xCleanup:${operation.resourceId}`, null); if (operation.completionId) services.store.remove('oauthCompletions', operation.completionId); }
      }
      if (completion) {
        const tokens = services.decrypt<OAuthTokens>(completion.encryptedTokens);
        const revoked = services.store.list<XRevocation>('xRevocations', item => matches(item) && item.state === 'revoked');
        return complete && revoked.some(item => item.tokenType === 'access_token') && (!tokens.refresh_token || revoked.some(item => item.tokenType === 'refresh_token'));
      }
      return complete && services.store.list<OAuthCompletion>('oauthCompletions', item => item.userId === userId && item.callbackPath === '/v1/x/oauth/callback').length === 0;
    },
    canReadResource: (principal: Principal, collection: string, value: unknown): boolean | undefined => {
      if (collection !== 'xConnections') return undefined;
      const result = z.object({ id, userId: id }).passthrough().safeParse(value);
      return result.success && result.data.userId === principal.userId && services.auth.member(principal.userId).enabled;
    },
    reconcile: async (): Promise<void> => {
      const pending = services.store.list<XConfirmation>('xConfirmations', item => item.state !== 'confirmed');
      if (!pending.length) return;
      const provider = providerFor(services); const token = await publicAccount(services);
      const identity = parse(z.object({ data: z.object({ id, username: z.string() }) }), await providerRequest(services, provider.apiBaseUrl, '2/users/me', token));
      const timeline = parse(z.object({ data: z.array(z.object({ id, text: z.string(), created_at: z.string(), referenced_tweets: z.array(z.object({ type: z.string(), id })).optional() })).max(100).optional() }), await providerRequest(services, provider.apiBaseUrl, `2/users/${encodeURIComponent(identity.data.id)}/tweets?max_results=100&tweet.fields=created_at,referenced_tweets`, token));
      for (const confirmation of pending) {
        const post = timeline.data?.find(item => item.text === confirmation.text && Date.parse(item.created_at) >= confirmation.startedAtMs && item.referenced_tweets?.some(reference => reference.type === 'replied_to' && reference.id === confirmation.postId));
        if (!post) continue; // Absence is not proof of unsent; never redispatch an uncertain public effect.
        services.store.put('xConfirmations', { ...confirmation, state: 'confirmed', providerMessageId: post.id });
        const deliveryId = services.mutations.digest(['x', confirmation.deliveryId]);
        const delivery = services.store.get<{ id: string; digest: string; receipt: P.IntegrationIngressReceipt }>('integrationDeliveries', deliveryId);
        if (delivery?.receipt.accepted) services.store.put('integrationDeliveries', { ...delivery, receipt: { ...delivery.receipt, status: 'accepted', reason: null } });
      }
    },
    retireUser: async (userId: string): Promise<void> => {
      let failure: unknown = null;
      for (const completion of services.store.list<OAuthCompletion>('oauthCompletions', item => item.userId === userId && item.callbackPath === '/v1/x/oauth/callback')) {
        try { await retireXCompletion(services, completion); }
        catch (error) { failure ??= error; services.store.setMetadata(`xCleanup:${completion.resourceId}`, { required: true, state: 'outcome_unknown' }); }
      }
      for (const connection of services.store.list<P.XConnection>('xConnections', item => item.userId === userId)) {
        const disabled = services.update(connection, { enabled: false, state: 'needs_auth' as const }); services.store.put('xConnections', disabled);
        try { await revokeConnection(services, connection); services.store.remove('xConnections', connection.id); }
        catch (error) { failure ??= error; services.store.setMetadata(`xCleanup:${connection.id}`, { required: true, state: 'outcome_unknown' }); services.audit(null, 'x.revoke', connection.id, 'outcome_unknown', { cleanupRequired: true }); }
      }
      if (failure) throw failure;
    },
  };
  xInstances.set(services, integration); return integration;
}
export function createXRoutes(services: BackendServices): Route[] {
  return [
    { method: 'GET', path: '/v1/x/provider', auth: 'member', handler: () => createXServices(services).inventory() },
    { method: 'POST', path: '/v1/x/connections', auth: 'member', handler: async context => {
      const principal = requireUser(context); const body = parse(connectBody, context.body); await xPolicy(services, principal, body.mainBotId); ownedMainBot(services, principal, body.mainBotId); const provider = providerFor(services);
      if (!['tweet.read', 'users.read'].every(scope => provider.oauth.scopes.includes(scope)) || provider.oauth.scopes.some(scope => !['tweet.read', 'users.read', 'offline.access'].includes(scope))) throw new IntegrationError('capability_unavailable', 'Mention linking requires only explicit tweet.read/users.read and optional offline.access scopes; protected tools use separate consent.');
      if (services.store.list<P.XConnection>('xConnections', item => item.userId === principal.userId && ['pending', 'connected'].includes(item.state)).length) throw new IntegrationError('conflict', 'An X connection already exists; change its main Bot or reconnect after removing it.');
      await publicAccount(services);
      const connection: P.XConnection = services.resource('x_connection', { userId: principal.userId, externalAccountId: null, username: null, mainBotId: body.mainBotId, enabled: true, state: 'pending', lastError: null });
      const flow = startOAuth(services, provider.oauth, { userId: principal.userId, resourceId: connection.id, callbackPath: '/v1/x/oauth/callback', clientRedirectUri: body.redirectUri });
      services.store.put('xConnections', connection); services.events.emit('x_connection.upserted', connection, { userIds: [principal.userId] }); return { connection, authorizationUrl: flow.authorizationUrl };
    } },
    { method: 'GET', path: '/v1/x/connections', auth: 'member', handler: async context => { const principal = requireUser(context); await xPolicy(services, principal); return services.page(context, services.store.list<P.XConnection>('xConnections', item => item.userId === principal.userId)); } },
    { method: 'PATCH', path: '/v1/x/connections/:id', auth: 'member', handler: async context => {
      const principal = requireUser(context); const body = parse(updateBody.extend({ mainBotId: id.optional(), enabled: z.boolean().optional() }), context.body); const connection = services.store.require<P.XConnection>('xConnections', context.params.id!);
      if (connection.userId !== principal.userId) throw new IntegrationError('not_found', 'Own X connection was not found.');
      services.mutations.checkRevision(connection, body.revision); await xPolicy(services, principal, body.mainBotId ?? connection.mainBotId); if (body.mainBotId) ownedMainBot(services, principal, body.mainBotId);
      const updated = services.update(connection, { ...(body.mainBotId === undefined ? {} : { mainBotId: body.mainBotId }), ...(body.enabled === undefined ? {} : { enabled: body.enabled }) }); services.store.put('xConnections', updated); services.events.emit('x_connection.upserted', updated, { userIds: [principal.userId] }); return updated;
    } },
    { method: 'DELETE', path: '/v1/x/connections/:id', auth: 'member', handler: async context => {
      const principal = requireUser(context); const body = parse(updateBody, context.body); const connection = services.store.require<P.XConnection>('xConnections', context.params.id!);
      if (connection.userId !== principal.userId) throw new IntegrationError('not_found', 'Own X connection was not found.');
      services.mutations.checkRevision(connection, body.revision); const disabled = services.update(connection, { enabled: false, state: 'needs_auth' as const }); services.store.put('xConnections', disabled); services.events.emit('x_connection.upserted', disabled, { userIds: [principal.userId] });
      await revokeConnection(services, connection);
      services.store.setMetadata(`xCredential:${connection.id}`, null); services.store.remove('xConnections', connection.id); return { id: connection.id, deleted: true };
    } },
    { method: 'GET', path: '/v1/x/oauth/callback', auth: 'public', mutation: false, handler: async context => {
      const provider = providerFor(services); const flow = takeOAuthState(services, context.query.get('state') ?? '', provider.oauth.id); const principal = principalFor(services, flow.userId); const connection = services.store.require<P.XConnection>('xConnections', flow.resourceId);
      if (connection.userId !== principal.userId || connection.state !== 'pending') throw new IntegrationError('conflict', 'X connection is no longer pending.');
      let updated: P.XConnection;
      if (context.query.get('error')) updated = services.update(connection, { state: 'failed', enabled: false, lastError: 'X account authorization was denied.' });
      else {
        try {
          await xPolicy(services, principal, connection.mainBotId); ownedMainBot(services, principal, connection.mainBotId);
          const tokens = await exchangeOAuth(services, provider.oauth, flow, context.query.get('code') ?? '', { clientAuthentication: 'basic' }); const scopes = tokens.scope?.split(/\s+/) ?? provider.oauth.scopes;
          if (!['tweet.read', 'users.read'].every(scope => scopes.includes(scope)) || scopes.some(scope => !provider.oauth.scopes.includes(scope))) throw new IntegrationError('unauthenticated', 'X returned unexpected account permissions.');
          const identity = parse(z.object({ data: z.object({ id, username: z.string().min(1).max(64) }) }), await providerRequest(services, provider.apiBaseUrl, '2/users/me', tokens.access_token));
          if (services.store.list<P.XConnection>('xConnections', item => item.id !== connection.id && item.externalAccountId === identity.data.id).length) throw new IntegrationError('conflict', 'This X account is already linked to another product account.');
          await xPolicy(services, principal, connection.mainBotId); ownedMainBot(services, principal, connection.mainBotId);
          assertActiveAccount(services, principal.userId, true);
          const tokenClientDigest = services.store.require<OAuthCompletion>('oauthCompletions', flow.id).tokenClientDigest;
          if (tokenClientDigest !== oauthTokenClientDigest(provider.oauth)) throw new IntegrationError('capability_unavailable', 'X OAuth client changed while authorization was in flight.');
          savePrivateMetadata(services, `xCredential:${connection.id}`, { accessToken: tokens.access_token, refreshToken: tokens.refresh_token ?? null, expiresAtMs: tokens.expires_in ? services.now() + tokens.expires_in * 1000 : null, scopes, tokenClientDigest } satisfies XCredential);
          updated = services.update(connection, { externalAccountId: identity.data.id, username: identity.data.username, state: 'connected', enabled: true, lastError: null });
        } catch (error) { updated = services.update(connection, { state: 'failed', enabled: false, lastError: error instanceof IntegrationError ? error.message : 'X provider authorization failed.' }); }
      }
      assertActiveAccount(services, principal.userId, true);
      services.store.put('xConnections', updated); if (updated.state === 'connected') markOAuthInstalled(services, flow.id); services.events.emit('x_connection.upserted', updated, { userIds: [principal.userId] }); return updated;
    } },
    { method: 'GET', path: '/v1/integrations/x/mentions', auth: 'public', mutation: false, handler: async context => {
      const provider = providerFor(services); const challenge = context.query.get('crc_token');
      // CRC must not become a chosen-message MAC oracle for a raw JSON webhook body using the same key.
      if (!challenge || challenge.length > 1024 || /[{}\u0000-\u001f]/.test(challenge)) throw new IntegrationError('invalid_request', 'X webhook CRC requires an opaque non-JSON challenge.');
      return { response_token: `sha256=${hmac(await services.secret(provider.signingSecretRef), challenge, 'base64')}` };
    } },
    { method: 'POST', path: '/v1/integrations/x/mentions', auth: 'public', mutation: false, body: 'none', handler: async context => {
      const provider = providerFor(services); const raw = await rawBody(context.request); let value: unknown; try { value = JSON.parse(raw); } catch { throw new IntegrationError('invalid_request', 'Invalid X gateway event JSON.'); }
      await verifyIngress(services, context.request, raw, 'x', 'x', provider.signingSecretRef, 300000, value);
      const native = z.object({ tweet_create_events: z.array(z.object({ id_str: id, user: z.object({ id_str: id }), text: z.string().max(65536), entities: z.object({ user_mentions: z.array(z.object({ screen_name: z.string().max(64) })).max(100) }) })).max(100) }).safeParse(value);
      const inputs: P.XIngress[] = native.success ? native.data.tweet_create_events.filter(post => post.entities.user_mentions.some(mention => mention.screen_name.toLowerCase() === provider.publicHandle.replace(/^@/, '').toLowerCase())).map(post => ({ deliveryId: post.id_str, externalAccountId: post.user.id_str, mentionPostId: post.id_str, mentionedHandle: provider.publicHandle, text: post.text })) : [parse(ingressBody, value)];
      let outcome = ignored('No explicit public Bot mention was present.');
      for (const input of inputs) {
      const dispatched = await dedupeIngress(services, 'x', input.deliveryId, input, async () => {
        const publicToken = await publicAccount(services);
        // Fetch authoritative public post and context before either setup guidance or private dispatch.
        const inspected = parse(z.object({ data: tweet, includes: z.object({ media: z.array(z.object({ media_key: id, type: z.enum(['photo', 'video', 'animated_gif']) })).max(12).optional(), tweets: z.array(tweet).max(10).optional() }).optional() }), await providerRequest(services, provider.apiBaseUrl, `2/tweets/${encodeURIComponent(input.mentionPostId)}?tweet.fields=author_id,created_at,entities,attachments,geo,withheld&expansions=attachments.media_keys,referenced_tweets.id,referenced_tweets.id.attachments.media_keys&media.fields=type`, publicToken));
        const post = inspected.data; const handle = provider.publicHandle.replace(/^@/, '').toLowerCase();
        if (post.id !== input.mentionPostId || post.author_id !== input.externalAccountId || input.mentionedHandle.replace(/^@/, '').toLowerCase() !== handle || !post.entities?.mentions?.some(mention => mention.username.toLowerCase() === handle)) return ignored('Only the actual account’s own explicit mention is eligible.');
        const createdAtMs = Date.parse(post.created_at);
        if (!Number.isFinite(createdAtMs) || Math.abs(services.now() - createdAtMs) > 300000) return ignored('Old or undated X mentions are not backfilled.');
        const connection = services.store.list<P.XConnection>('xConnections', item => item.externalAccountId === post.author_id)[0];
        if (!connection) { await postPublic(services, input.mentionPostId, `Sign in and connect your own X account and personal Bot at ${services.config.publicUrl}. No work was started.`, publicToken); return ignored('Product sign-in and an owned main Bot are required.'); }
        if (!connection.enabled || connection.state !== 'connected') return ignored('X connection is disabled or requires authentication.');
        const principal = principalFor(services, connection.userId);
        try { await xPolicy(services, principal, connection.mainBotId); } catch (error) { if (error instanceof IntegrationError && error.code === 'policy_denied') return ignored('X mentions are disabled by policy.'); throw error; }
        let bot: P.Bot; try { bot = ownedMainBot(services, principal, connection.mainBotId); } catch { await postPublic(services, input.mentionPostId, `Choose your own personal main Bot in ${services.config.publicUrl}. No work was started.`, publicToken); return ignored('An owned personal main Bot is required.'); }
        const credential = privateMetadata<XCredential>(services, `xCredential:${connection.id}`);
        if (!credential || credential.expiresAtMs !== null && credential.expiresAtMs <= services.now()) { const expired = services.update(connection, { state: 'needs_auth' as const, lastError: 'X account authorization expired.' }); services.store.put('xConnections', expired); services.events.emit('x_connection.upserted', expired, { userIds: [principal.userId] }); return ignored('X OAuth authorization expired.'); }
        const contextPosts = inspected.includes?.tweets ?? [];
        const keys = [...new Set([...(post.attachments?.media_keys ?? []), ...contextPosts.flatMap(item => item.attachments?.media_keys ?? [])])];
        const moderation = parse(z.strictObject({ allowed: z.boolean(), reason: z.string().max(256).nullable(), country: z.string().length(2).nullable(), usageAllowed: z.boolean(), mediaAllowed: z.boolean() }), await providerRequest(services, provider.apiBaseUrl, 'moderation/check', publicToken, 'POST', { postId: post.id, accountId: post.author_id, mediaKeys: keys, contextPostIds: contextPosts.map(item => item.id) }));
        if (!moderation.allowed) return ignored(moderation.reason ? safeSummary(moderation.reason, 256) : 'Provider moderation refused this mention.');
        if (!moderation.usageAllowed) return ignored('Provider usage limit is exhausted.');
        if (!moderation.mediaAllowed) return ignored('Provider media policy refused the mention.');
        if (provider.deniedCountries.length && (!moderation.country || provider.deniedCountries.includes(moderation.country.toUpperCase()))) return ignored('Country is blocked or could not be verified.');
        if (post.withheld?.country_codes.length) return ignored('Provider withheld this content by region policy.');
        const media = (inspected.includes?.media ?? []).filter(file => keys.includes(file.media_key));
        if (keys.length > 6 || keys.some(key => !media.some(file => file.media_key === key)) || media.some(file => !provider.allowedMedia.includes(file.type === 'animated_gif' ? 'gif' : file.type))) return ignored('Media type is unavailable or not allowed.');
        try { await services.integrations.admission(principal, bot.id); } catch (error) { if (error instanceof IntegrationError && error.code === 'policy_denied') return ignored('New work is blocked by effective policy or spend limits.'); throw error; }
        const attachmentIds: string[] = [];
        for (const file of media) {
          const sourcePost = [post, ...contextPosts].find(item => item.attachments?.media_keys.includes(file.media_key));
          if (!sourcePost) return ignored('Media was not associated with verified provider context.');
          const content = parse(z.strictObject({ mediaKey: id, filename: z.string().min(1).max(256), mime: z.string().max(128), dataBase64: z.string().max(36 * 1024 * 1024) }), await providerRequest(services, provider.apiBaseUrl, `media/${encodeURIComponent(file.media_key)}?postId=${encodeURIComponent(sourcePost.id)}`, publicToken));
          if (content.mediaKey !== file.media_key) throw new IntegrationError('upstream_unavailable', 'Provider media identity did not match the verified post.');
          const bytes = Buffer.from(content.dataBase64, 'base64'); if (bytes.toString('base64') !== content.dataBase64 || bytes.length > 25 * 1024 * 1024) return ignored('Media exceeds configured supported size.');
          const attachment = await services.attachments.create(principal, bytes, { clientNonce: services.mutations.digest([input.deliveryId, file.media_key]), botId: bot.id, conversationId: bot.mainConversationId, purpose: 'message', filename: content.filename, mime: content.mime }); attachmentIds.push(attachment.id);
        }
        const clientNonce = services.mutations.digest(['x', input.deliveryId]);
        services.store.setMetadata(`externalSubmission:${principal.kind}:${principal.id}:${bot.mainConversationId}:${clientNonce}`, { provider: 'x' });
        const receipt = await services.runtime.send(principal, bot.mainConversationId, { clientNonce, text: untrusted({ source: 'x', post, contextPosts: inspected.includes?.tweets ?? [] }), attachmentIds });
        const run = receipt.runs[0]; if (!run) throw new IntegrationError('upstream_unavailable', 'X mention submission returned no run.');
        const result: P.IntegrationIngressReceipt = { accepted: receipt.status !== 'outcome_unknown', status: receipt.status === 'outcome_unknown' ? 'outcome_unknown' : 'accepted', reason: null, runId: run.id, conversationId: bot.mainConversationId };
        services.store.setMetadata(`xMentionRun:${input.deliveryId}`, result);
        if (result.accepted) {
          const confirmation: XConfirmation = { id: services.mutations.digest(['x', input.deliveryId]), deliveryId: input.deliveryId, postId: post.id, text: 'Accepted. Your connected personal Bot is working privately in Lemon Bot.', startedAtMs: services.now(), state: 'reserved', providerMessageId: null };
          services.store.put('xConfirmations', confirmation);
          try { const messageId = await postPublic(services, post.id, confirmation.text, publicToken); services.store.put('xConfirmations', { ...confirmation, state: 'confirmed', providerMessageId: messageId }); }
          catch { services.store.put('xConfirmations', { ...confirmation, state: 'outcome_unknown' }); return { ...result, status: 'outcome_unknown', reason: 'Work was accepted; public confirmation is not acknowledged. Do not redispatch.' }; }
        }
        return result;
      });
        if (dispatched.accepted || !outcome.accepted) outcome = dispatched;
      }
      return outcome;
    } },
  ];
}
