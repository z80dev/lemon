import { randomBytes, createHash } from 'node:crypto';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../core/services';
import { IntegrationError, assertActiveAccount, fetchJson, providerRequest as pinnedRequest } from './common';
import { startOAuth, takeOAuthState, exchangeOAuth, markOAuthInstalled, oauthTokenClientDigest } from './oauth';
import type { OAuthCompletion, OAuthTokens } from './oauth';
import { dedupeIngress, id, ignored, nonce, parse, principalFor, providerResult, rawBody, requireUser, untrusted, updateBody, verifyIngress } from './channel-security';

export async function providerRequest(services: BackendServices, baseUrl: string, path: string, token: string, method = 'GET', body?: unknown): Promise<unknown> {
  const base = new URL(baseUrl); const url = new URL(path.replace(/^\//, ''), base.href.endsWith('/') ? base.href : base.href + '/');
  if (base.protocol !== 'https:' || url.origin !== base.origin || base.username || base.password) throw new IntegrationError('capability_unavailable', 'Provider requires a configured pinned HTTPS origin.');
  const configured = [...services.config.operator.channelProviders.map(provider => new URL(provider.apiBaseUrl).origin), ...services.config.operator.emailProviders.map(provider => new URL(provider.provisioningBaseUrl).origin), ...(services.config.operator.xProvider ? [new URL(services.config.operator.xProvider.apiBaseUrl).origin] : [])];
  if (!configured.includes(base.origin)) throw new IntegrationError('policy_denied', 'Provider origin is not configured for this deployment.');
  return fetchJson(url.href, { method, headers: { authorization: `Bearer ${token}`, accept: 'application/json', ...(body === undefined ? {} : { 'content-type': 'application/json' }) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }, { allowedOrigins: [base.origin], timeoutMs: 20000, maxBytes: 40 * 1024 * 1024, mutation: method !== 'GET' });
}
const slackResult = z.object({ ok: z.boolean(), error: z.string().optional() }).passthrough();
interface ChannelAccount { id: string; providerId: string; teamId: string; botUserId: string; appId: string | null; token: string; installerUserId: string; productUserId: string; botId: string }
interface SetupState { id: string; flowId: string; providerId: string; userId: string; expiresAtMs: number }
interface LinkProof { id: string; flowId: string; used: boolean }
interface ChannelThread { id: string; channelBindingId: string; externalThreadId: string; userId: string; conversationId: string; externalTarget: string }
interface ChannelReturn { id: string; conversationId: string; userId: string; channelBindingId: string; target: string; thread: string | null; text: string; sourceRunId: string; startedAtMs: number; state: 'reserved' | 'sent'; providerMessageId: string | null }
interface SlackCleanup { id: string; userId: string; providerId: string; resourceId: string; completionId: string | null; encryptedToken: string; hasRefreshToken: boolean; state: 'reserved' | 'revoked' | 'failed' | 'outcome_unknown' }
function slackMessageKey(operationId: string): string {
  const digest = createHash('sha256').update(operationId).digest('hex');
  return `${digest.slice(0, 8)}-${digest.slice(8, 12)}-4${digest.slice(13, 16)}-8${digest.slice(17, 20)}-${digest.slice(20, 32)}`;
}
const adapters = z.enum(['email', 'slack', 'telegram', 'discord', 'whatsapp']);
const createBody = z.strictObject({ clientNonce: nonce, botId: id, adapter: adapters, accountId: id, target: z.string().min(1).max(256), enabled: z.boolean() });
const setupBody = z.strictObject({ clientNonce: nonce, botId: id, adapter: adapters, providerId: id, accountLabel: z.string().min(1).max(120), redirectUri: z.string().max(2048) });
const linkBody = z.strictObject({ clientNonce: nonce, channelBindingId: id, externalUserId: id, verificationCode: z.string().min(16).max(128) });
export function channelProvider(services: BackendServices, binding: P.ChannelBinding): P.ChannelProviderConfig {
  const account = services.store.get<ChannelAccount>('channelAccounts', binding.accountId);
  const provider = services.config.operator.channelProviders.find(item => item.id === (account?.providerId ?? binding.accountId) && item.adapter === binding.adapter);
  if (!provider) throw new IntegrationError('capability_unavailable', 'Configure the channel provider and account credentials.');
  return provider;
}
async function channelPolicy(services: BackendServices, principal: Principal, botId: string, adapter: P.ChannelBinding['adapter'], manage = false): Promise<P.Bot> {
  assertActiveAccount(services, principal.userId);
  const bot = services.auth.bot(principal, botId, manage);
  const governance = services.store.list<P.Governance>('governance')[0] ?? services.store.metadata<P.Governance>('governance');
  if (adapter === 'email' ? !governance?.emailEnabled : !governance?.allowedChannelAdapters.includes(adapter)) throw new IntegrationError('policy_denied', 'This channel adapter is not enabled by workspace policy.');
  const policy = await services.integrations.effectivePolicy(principal, botId);
  if (!policy.productAccess) throw new IntegrationError('policy_denied', 'Product access is disabled for this principal.');
  return bot;
}
export async function slackCall(services: BackendServices, binding: P.ChannelBinding, method: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
  const provider = channelProvider(services, binding); const account = services.store.get<ChannelAccount>('channelAccounts', binding.accountId);
  const token = account ? services.decrypt<string>(account.token) : provider.accountSecretRef ? await services.secret(provider.accountSecretRef) : null;
  if (!token) throw new IntegrationError('capability_unavailable', 'Install the configured Slack app before using its API.');
  const form = new URLSearchParams();
  for (const [key, value] of Object.entries(body)) if (value !== undefined && value !== null) form.set(key, typeof value === 'object' ? JSON.stringify(value) : String(value));
  const base = new URL(provider.apiBaseUrl);
  const endpoint = new URL(method, base.href.endsWith('/') ? base.href : base.href + '/');
  const reads: Record<string, true> = { 'auth.test': true, 'users.info': true, 'conversations.info': true, 'conversations.history': true, 'conversations.replies': true };
  const result = providerResult(slackResult, await fetchJson(endpoint.href, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/x-www-form-urlencoded' }, body: form }, { allowedOrigins: [base.origin], mutation: !reads[method] }), !reads[method]);
  if (!result.ok) {
    if (result.error === 'admin_required' || result.error === 'restricted_action' || result.error === 'not_allowed_token_type') throw new IntegrationError('policy_denied', 'Slack workspace administrator approval is required.');
    if (result.error === 'fatal_error' || result.error === 'internal_error') throw new IntegrationError('outcome_unknown', 'Slack could not confirm the operation outcome.', false);
    throw new IntegrationError('upstream_unavailable', 'Slack API refused the operation.');
  }
  return result;
}
async function sendLinkInstructions(services: BackendServices, binding: P.ChannelBinding, externalUserId: string): Promise<void> {
  const opened = parse(z.object({ channel: z.object({ id }) }), await slackCall(services, binding, 'conversations.open', { users: externalUserId }));
  await slackCall(services, binding, 'chat.postMessage', { channel: opened.channel.id, text: `Welcome. Sign in to ${services.config.publicUrl} with your own enabled account and start channel identity linking. Send the displayed link code here in this DM, then complete the verified link in the app. No work or owner budget is used before linking.`, unfurl_links: false, unfurl_media: false });
}
async function bindingForCreate(services: BackendServices, principal: Principal, body: P.ChannelCreate): Promise<P.ChannelBinding> {
  await channelPolicy(services, principal, body.botId, body.adapter, true);
  if (body.adapter === 'email') {
    const account = services.store.get<P.EmailAccount>('emailAccounts', body.accountId);
    if (!account || account.userId !== principal.userId || account.state !== 'active' || body.target !== account.address) throw new IntegrationError('forbidden', 'Email channel requires your exact active account-owned mailbox.');
    if (account.channelBindingId && services.store.get('channelBindings', account.channelBindingId)) throw new IntegrationError('conflict', 'This mailbox already has a Bot channel.');
    const provider = services.config.operator.emailProviders.find(item => item.id === account.provider);
    if (!provider) throw new IntegrationError('capability_unavailable', 'Restore the configured mailbox provider.');
    providerResult(z.object({ messages: z.array(z.unknown()) }), await providerRequest(services, provider.provisioningBaseUrl, `mailboxes/${encodeURIComponent(account.address)}/messages?limit=1`, await services.secret(provider.provisioningSecretRef)));
    assertActiveAccount(services, principal.userId);
    const binding: P.ChannelBinding = services.resource('channel', { botId: body.botId, ownerUserId: principal.userId, adapter: 'email', accountId: account.id, target: account.address, enabled: body.enabled, state: 'connected', capabilities: { inbound: true, outbound: true, events: ['email_received'] }, lastError: null });
    services.store.transaction(() => { services.store.put('channelBindings', binding); services.store.put('emailAccounts', services.update(account, { channelBindingId: binding.id })); });
    services.events.emit('channel.upserted', binding, { userIds: [principal.userId] });
    return binding;
  }
  const provider = services.config.operator.channelProviders.find(item => item.id === body.accountId && item.adapter === body.adapter);
  if (!provider) throw new IntegrationError('capability_unavailable', 'Select an operator-configured channel account.');
  if (body.adapter === 'slack' && provider.supportsBotAppInstall) throw new IntegrationError('conflict', 'Use the verified Slack app installation flow.');
  if (!provider.accountSecretRef) throw new IntegrationError('capability_unavailable', 'Configure account authentication for this adapter.');
  const token = await services.secret(provider.accountSecretRef);
  let accountId = body.accountId;
  if (body.adapter === 'slack') {
    const auth = parse(z.object({ ok: z.literal(true), team_id: id, user_id: id }), await providerRequest(services, provider.apiBaseUrl, 'auth.test', token, 'POST', {}));
    const account: ChannelAccount = { id: services.id('channel_account'), providerId: provider.id, teamId: auth.team_id, botUserId: auth.user_id, appId: null, token: services.encrypt(token), installerUserId: '', productUserId: principal.userId, botId: body.botId };
    services.store.put('channelAccounts', account); accountId = account.id;
  } else {
    const checked = parse(z.strictObject({ accountId: id, authenticated: z.literal(true), targetAllowed: z.literal(true) }), await providerRequest(services, provider.apiBaseUrl, 'accounts/verify', token, 'POST', { accountId: body.accountId, target: body.target, botId: body.botId }));
    if (checked.accountId !== body.accountId) throw new IntegrationError('upstream_unavailable', 'Adapter account identity did not match configuration.');
    await providerRequest(services, provider.apiBaseUrl, 'bindings', token, 'POST', { botId: body.botId, target: body.target, enabled: body.enabled, clientNonce: body.clientNonce });
  }
  const binding: P.ChannelBinding = services.resource('channel', { botId: body.botId, ownerUserId: principal.userId, adapter: body.adapter, accountId, target: body.target, enabled: body.enabled, state: 'connected', capabilities: provider.capabilities, lastError: null });
  if (body.adapter === 'slack' && !body.target.startsWith('D')) await slackCall(services, binding, 'conversations.join', { channel: body.target });
  services.store.put('channelBindings', binding); services.events.emit('channel.upserted', binding, { botId: binding.botId, userIds: [principal.userId] });
  return binding;
}
function recordChannelProof(services: BackendServices, flow: P.ChannelLinkFlow, externalUserId: string, externalDisplayName: string | null): P.ChannelLinkFlow {
  const verificationCode = randomBytes(24).toString('base64url');
  const verified = services.update(flow, { state: 'verified' as const, externalUserId, externalDisplayName, linkCode: null, verificationCode: null });
  services.store.transaction(() => {
    services.store.put('channelLinkFlows', verified); services.store.put('channelLinkProofs', { id: services.mutations.digest(verificationCode), flowId: flow.id, used: false } satisfies LinkProof);
    services.store.setMetadata(`channelLinkVerification:${flow.id}`, services.encrypt(verificationCode));
  });
  return verified;
}

function applicationPrincipal(services: BackendServices, binding: P.ChannelBinding, externalAppId: string): Principal | null {
  const configured = services.config.operatorExtras?.channelApplicationPrincipals;
  const grants = parse(z.array(z.strictObject({ providerId: id, channelBindingId: id, externalAppId: id, userId: id })).max(1000), configured ?? []);
  const provider = channelProvider(services, binding);
  const grant = grants.find(item => item.providerId === provider.id && item.channelBindingId === binding.id && item.externalAppId === externalAppId);
  if (!grant) return null;
  return { ...principalFor(services, grant.userId), scopes: [`channel_application:${binding.id}:${externalAppId}`] };
}

export async function channelGatewayIngress(services: BackendServices, context: RequestContext): Promise<P.IntegrationIngressReceipt> {
  const provider = services.config.operator.channelProviders.find(item => item.id === context.params.providerId);
  if (!provider?.signingSecretRef) throw new IntegrationError('capability_unavailable', 'Configure a signed adapter ingress provider.');
  const raw = await rawBody(context.request); let value: unknown;
  try { value = JSON.parse(raw); } catch { throw new IntegrationError('invalid_request', 'Invalid channel adapter event JSON.'); }
  await verifyIngress(services, context.request, raw, provider.id, provider.adapter, provider.signingSecretRef, 300000, value);
  const input = parse(z.strictObject({ deliveryId: id, event: z.enum(['message', 'mention']), payload: z.strictObject({ channelBindingId: id, externalUserId: id.optional(), externalAppId: id.optional(), externalThreadId: z.string().min(1).max(512), text: z.string().max(65536), direct: z.boolean(), timestampMs: z.number().int().nonnegative() }) }), value);
  return dedupeIngress(services, provider.id, input.deliveryId, input, async () => {
    const binding = services.store.require<P.ChannelBinding>('channelBindings', input.payload.channelBindingId);
    if (channelProvider(services, binding).id !== provider.id || !binding.enabled || binding.state !== 'connected') return ignored('Adapter binding is disabled or belongs to a different provider.');
    if (Math.abs(services.now() - input.payload.timestampMs) > 300000 || input.payload.timestampMs < binding.createdAtMs) return ignored('Old adapter events are not backfilled.');
    let principal: Principal | null = input.payload.externalAppId ? applicationPrincipal(services, binding, input.payload.externalAppId) : null;
    if (!principal && input.payload.externalUserId && !input.payload.externalAppId) {
      const link = services.store.list<P.ChannelPrincipalLink>('channelPrincipalLinks', item => item.channelBindingId === binding.id && item.externalUserId === input.payload.externalUserId && item.verified)[0];
      if (link) principal = principalFor(services, link.userId);
    }
    if (!principal) return ignored('Own verified channel identity or an explicit fixed application grant is required.');
    const actor = principal;
    const prior = services.store.list<ChannelThread>('channelThreads', item => item.channelBindingId === binding.id && item.externalThreadId === input.payload.externalThreadId && item.userId === actor.userId)[0];
    if (!input.payload.direct && input.event !== 'mention' && !prior) return ignored('Channel participation requires an explicit mention or an existing own thread.');
    const result = await createChannelServices(services).channelIngress({ principal: actor, botId: binding.botId, channelBindingId: binding.id, externalThreadId: input.payload.externalThreadId, text: input.payload.text, clientNonce: services.mutations.digest([provider.id, input.deliveryId]) });
    const run = result.runs[0]; if (!run) throw new IntegrationError('upstream_unavailable', 'Adapter dispatch returned no actual run.');
    return { accepted: result.status !== 'outcome_unknown', status: result.status === 'outcome_unknown' ? 'outcome_unknown' : 'accepted', reason: null, runId: run.id, conversationId: run.conversationId };
  });
}

async function retireSlackGrant(services: BackendServices, provider: P.ChannelProviderConfig, userId: string, resourceId: string, accessToken: string, refreshToken: string | null, completionId: string | null): Promise<void> {
  const operationId = services.mutations.digest(['slack_cleanup', resourceId, services.mutations.digest(accessToken)]);
  const previous = services.store.get<SlackCleanup>('slackCleanups', operationId);
  if (previous?.state === 'revoked') return;
  if (previous) throw new IntegrationError('outcome_unknown', 'Slack grant cleanup is reserved; inspect its provider receipt without redispatch.', false);
  const operation: SlackCleanup = { id: operationId, userId, providerId: provider.id, resourceId, completionId, encryptedToken: services.encrypt(accessToken), hasRefreshToken: refreshToken !== null, state: 'reserved' };
  services.store.put('slackCleanups', operation);
  try {
    if (refreshToken) {
      if (!provider.accountSecretRef) throw new IntegrationError('capability_unavailable', 'Rotating Slack grant cleanup requires an authenticated provider cleanup gateway.');
      const result = providerResult(z.strictObject({ revoked: z.literal(true), resourceId: id }), await providerRequest(services, provider.apiBaseUrl, 'oauth/cleanup', await services.secret(provider.accountSecretRef), 'POST', { operationId, resourceId, accessToken, refreshToken }), true);
      if (result.resourceId !== resourceId) throw new IntegrationError('outcome_unknown', 'Slack cleanup acknowledgment did not match the exact grant.', false);
    } else {
      const base = new URL(provider.apiBaseUrl); const endpoint = new URL('auth.revoke', base.href.endsWith('/') ? base.href : base.href + '/');
      providerResult(z.object({ ok: z.literal(true), revoked: z.literal(true) }), await fetchJson(endpoint.href, { method: 'POST', headers: { authorization: `Bearer ${accessToken}`, 'content-type': 'application/x-www-form-urlencoded', 'x-lemon-operation-id': operationId }, body: new URLSearchParams() }, { allowedOrigins: [base.origin], mutation: true }), true);
    }
    services.store.put('slackCleanups', { ...operation, state: 'revoked' });
  } catch (error) { services.store.put('slackCleanups', { ...operation, state: error instanceof IntegrationError && error.retrySafe ? 'failed' : 'outcome_unknown' }); throw error; }
}
async function retireSlackCompletion(services: BackendServices, completion: OAuthCompletion): Promise<void> {
  const provider = services.config.operator.channelProviders.find(item => item.oauth?.id === completion.providerId);
  if (!provider?.oauth || completion.callbackPath !== '/v1/channels/oauth/callback' || oauthTokenClientDigest(provider.oauth) !== completion.tokenClientDigest) throw new IntegrationError('capability_unavailable', 'Restore the exact Slack OAuth client to revoke its pending grant.');
  const tokens = services.decrypt<OAuthTokens>(completion.encryptedTokens);
  await retireSlackGrant(services, provider, completion.userId, completion.resourceId, tokens.access_token, tokens.refresh_token ?? null, completion.id);
  services.store.remove('oauthCompletions', completion.id);
  for (const account of services.store.list<ChannelAccount>('channelAccounts', item => item.productUserId === completion.userId && item.providerId === provider.id)) {
    if (services.decrypt<string>(account.token) === tokens.access_token && !services.store.list<P.ChannelBinding>('channelBindings', item => item.accountId === account.id).length) services.store.remove('channelAccounts', account.id);
  }
}


export interface ChannelServices {
  inventory(): P.ChannelProviderInfo[];
  canReadResource(principal: Principal, collection: string, value: unknown): boolean | undefined;
  retireOAuthCompletion(completion: OAuthCompletion): Promise<void>;
  retireUser(userId: string): Promise<void>;
  reconcileUserCleanup(userId: string, completion?: OAuthCompletion): Promise<boolean>;
  reconcile(): Promise<void>;
  channelIngress(input: { principal: Principal; botId: string; channelBindingId: string; externalThreadId: string; text: string; attachmentIds?: string[]; clientNonce: string }): Promise<P.MessageReceipt>;
  assertChannelHandoff(principal: Principal, source: P.Conversation, target: P.Bot, returnConversationId: string): void;
  returnChannelHandoff(principal: Principal, conversationId: string, text: string, sourceRunId?: string): Promise<void>;
  sendApprovedDraft(principal: Principal, draft: P.Draft): Promise<{ providerMessageId: string | null; runId: string | null }>;
}
const channelInstances = new WeakMap<BackendServices, ChannelServices>();
export function createChannelServices(services: BackendServices): ChannelServices {
  const existing = channelInstances.get(services); if (existing) return existing;
  const integration: ChannelServices = {
    inventory: (): P.ChannelProviderInfo[] => services.config.operator.channelProviders.map(provider => ({ id: provider.id, kind: 'channel', label: `${provider.adapter} — ${provider.id}`, adapter: provider.adapter, configured: !!(provider.oauth || provider.accountSecretRef), prerequisites: provider.oauth || provider.accountSecretRef ? [] : ['Configure OAuth installation or adapter account credentials.'], capabilities: [...provider.capabilities.events, ...(provider.capabilities.inbound ? ['inbound'] : []), ...(provider.capabilities.outbound ? ['outbound'] : [])], supportsBotAppInstall: provider.supportsBotAppInstall })),
    canReadResource: (principal: Principal, collection: string, value: unknown): boolean | undefined => {
      if (!['channelBindings', 'channelSetups', 'channelPrincipalLinks', 'channelLinkFlows'].includes(collection)) return undefined;
      const result = z.object({ id }).passthrough().safeParse(value);
      if (!result.success || !services.auth.member(principal.userId).enabled) return false;
      if (collection === 'channelBindings') { const binding = z.object({ botId: id, adapter: adapters, ownerUserId: id }).passthrough().safeParse(value); if (!binding.success || binding.data.adapter === 'email' && binding.data.ownerUserId !== principal.userId) return false; try { services.auth.bot(principal, binding.data.botId); return true; } catch { return false; } }
      if (collection === 'channelSetups') {
        const setup = z.object({ botId: id }).passthrough().safeParse(value); if (!setup.success) return false;
        const state = services.store.list<SetupState>('channelSetupStates', item => item.flowId === result.data.id)[0];
        if (state?.userId !== principal.userId) return false;
        try { services.auth.bot(principal, setup.data.botId, true); return true; } catch { return false; }
      }
      const owned = z.object({ userId: id, channelBindingId: id }).passthrough().safeParse(value);
      if (!owned.success || owned.data.userId !== principal.userId) return false;
      const binding = services.store.get<P.ChannelBinding>('channelBindings', owned.data.channelBindingId);
      if (!binding) return false;
      try { services.auth.bot(principal, binding.botId); return true; } catch { return false; }
    },
    retireOAuthCompletion: (completion: OAuthCompletion): Promise<void> => retireSlackCompletion(services, completion),
    retireUser: async (userId: string): Promise<void> => {
      let failure: unknown = null;
      for (const completion of services.store.list<OAuthCompletion>('oauthCompletions', item => item.userId === userId && item.callbackPath === '/v1/channels/oauth/callback')) {
        try { await retireSlackCompletion(services, completion); } catch (error) { failure ??= error; }
      }
      for (const account of services.store.list<ChannelAccount>('channelAccounts', item => item.productUserId === userId)) {
        if (services.store.list<P.ChannelBinding>('channelBindings', item => item.accountId === account.id).length) continue;
        const provider = services.config.operator.channelProviders.find(item => item.id === account.providerId);
        if (!provider) { failure ??= new IntegrationError('capability_unavailable', 'Restore the configured Slack provider to revoke its orphaned grant.'); continue; }
        try { await retireSlackGrant(services, provider, userId, account.id, services.decrypt<string>(account.token), null, null); services.store.remove('channelAccounts', account.id); } catch (error) { failure ??= error; }
      }
      for (const collection of ['channelPrincipalLinks', 'channelLinkFlows', 'channelThreads', 'channelReturns']) for (const value of services.store.list<{ id: string; userId: string }>(collection, item => item.userId === userId)) services.store.remove(collection, value.id);
      for (const state of services.store.list<SetupState>('channelSetupStates', item => item.userId === userId)) { services.store.remove('channelSetups', state.flowId); services.store.remove('channelSetupStates', state.id); }
      if (failure) throw failure;
    },
    reconcileUserCleanup: async (userId: string, completion?: OAuthCompletion): Promise<boolean> => {
      let complete = true;
      const matches = (item: SlackCleanup): boolean => item.userId === userId && (!completion || item.completionId === completion.id && item.resourceId === completion.resourceId);
      for (const operation of services.store.list<SlackCleanup>('slackCleanups', item => matches(item) && item.state !== 'revoked')) {
        const provider = services.config.operator.channelProviders.find(item => item.id === operation.providerId); if (!provider) { complete = false; continue; }
        let revoked = false;
        if (!operation.hasRefreshToken) {
          const base = new URL(provider.apiBaseUrl); const endpoint = new URL('auth.test', base.href.endsWith('/') ? base.href : base.href + '/');
          const result = providerResult(slackResult, await fetchJson(endpoint.href, { headers: { authorization: `Bearer ${services.decrypt<string>(operation.encryptedToken)}` } }, { allowedOrigins: [base.origin], mutation: false }));
          revoked = !result.ok && ['token_revoked', 'account_inactive'].includes(result.error ?? '');
        }
        if (!revoked && provider.accountSecretRef) {
          const result = providerResult(z.strictObject({ state: z.enum(['pending', 'revoked', 'failed']), resourceId: id, scope: z.literal('grant') }), await providerRequest(services, provider.apiBaseUrl, `oauth/cleanup/${encodeURIComponent(operation.id)}`, await services.secret(provider.accountSecretRef)));
          if (result.resourceId !== operation.resourceId) throw new IntegrationError('upstream_unavailable', 'Slack cleanup receipt belongs to a different grant.');
          revoked = result.state === 'revoked';
        }
        if (revoked) { services.store.put('slackCleanups', { ...operation, state: 'revoked' }); if (operation.completionId) services.store.remove('oauthCompletions', operation.completionId); }
        else complete = false;
      }
      if (completion) return complete && services.store.list<SlackCleanup>('slackCleanups', item => matches(item) && item.state === 'revoked').length > 0;
      return complete && services.store.list<OAuthCompletion>('oauthCompletions', item => item.userId === userId && item.callbackPath === '/v1/channels/oauth/callback').length === 0;
    },
    reconcile: async (): Promise<void> => {
      const pending: { operationId: string; binding: P.ChannelBinding; target: string; thread: string | null; startedAtMs: number; draft?: P.Draft; reply?: ChannelReturn }[] = [];
      for (const draft of services.store.list<P.Draft>('drafts', item => item.content.kind !== 'email' && ['sending', 'outcome_unknown'].includes(item.state))) {
        if (!services.store.metadata<boolean>(`channelDraftReserved:${draft.id}`) || services.store.metadata(`channelDraftSent:${draft.id}`)) continue;
        const content = draft.content; if (content.kind === 'email') continue;
        const binding = services.store.get<P.ChannelBinding>('channelBindings', content.kind === 'message' ? content.channelBindingId : content.connectorId);
        if (binding) pending.push({ operationId: draft.id, binding, target: content.target, thread: content.thread, startedAtMs: draft.updatedAtMs, draft });
      }
      for (const reply of services.store.list<ChannelReturn>('channelReturns', item => item.state === 'reserved')) {
        const binding = services.store.get<P.ChannelBinding>('channelBindings', reply.channelBindingId);
        if (binding) pending.push({ operationId: reply.id, binding, target: reply.target, thread: reply.thread, startedAtMs: reply.startedAtMs, reply });
      }
      for (const item of pending) {
        let messageId: string | null = null;
        if (item.binding.adapter === 'slack') {
          const account = services.store.require<ChannelAccount>('channelAccounts', item.binding.accountId);
          const result = providerResult(z.object({ messages: z.array(z.object({ ts: id, user: id.optional(), client_msg_id: z.string().optional() })).max(100) }), await slackCall(services, item.binding, item.thread ? 'conversations.replies' : 'conversations.history', { channel: item.target, ...(item.thread ? { ts: item.thread } : { oldest: String(item.startedAtMs / 1000) }), limit: 100 }));
          messageId = result.messages.find(message => message.client_msg_id === slackMessageKey(item.operationId) && message.user === account.botUserId)?.ts ?? null;
        } else if (item.draft) {
          const provider = channelProvider(services, item.binding); if (!provider.accountSecretRef) continue;
          const result = providerResult(z.strictObject({ state: z.enum(['pending', 'sent', 'rejected']), messageId: id.nullable() }), await providerRequest(services, provider.apiBaseUrl, `messages/status/${encodeURIComponent(item.operationId)}`, await services.secret(provider.accountSecretRef)));
          if (result.state === 'sent') messageId = result.messageId;
          if (result.state === 'rejected') { services.store.setMetadata(`channelDraftReserved:${item.operationId}`, false); const failed = services.update(item.draft, { state: 'failed' as const, error: 'Adapter confirmed this message was not delivered; review a new explicit send.' }); services.store.put('drafts', failed); services.events.emit('draft.upserted', failed, { userIds: [failed.ownerUserId] }); }
        }
        if (!messageId) continue;
        if (item.reply) services.store.put('channelReturns', { ...item.reply, state: 'sent', providerMessageId: messageId });
        if (item.draft) { const receipt = { providerMessageId: messageId, runId: null }; services.store.setMetadata(`channelDraftSent:${item.operationId}`, receipt); const sent = services.update(item.draft, { state: 'sent' as const, providerMessageId: messageId, error: null }); services.store.put('drafts', sent); services.events.emit('draft.upserted', sent, { userIds: [sent.ownerUserId] }); }
      }
    },
    channelIngress: async (input: { principal: Principal; botId: string; channelBindingId: string; externalThreadId: string; text: string; attachmentIds?: string[]; clientNonce: string }): Promise<P.MessageReceipt> => {
      const binding = services.store.require<P.ChannelBinding>('channelBindings', input.channelBindingId);
      if (!binding.enabled || binding.state !== 'connected' || !binding.capabilities.inbound || binding.botId !== input.botId) throw new IntegrationError('policy_denied', 'Channel ingress is disabled or target does not match.');
      const bot = await channelPolicy(services, input.principal, binding.botId, binding.adapter);
      const links = services.store.list<P.ChannelPrincipalLink>('channelPrincipalLinks', link => link.channelBindingId === binding.id && link.verified && link.userId === input.principal.userId);
      const application = input.principal.scopes?.some(scope => scope.startsWith(`channel_application:${binding.id}:`));
      if (binding.adapter !== 'email' && !links.length && !application) throw new IntegrationError('forbidden', 'A verified own channel identity is required.');
      if (binding.adapter === 'email' && binding.ownerUserId !== input.principal.userId) throw new IntegrationError('forbidden', 'Mailbox principal must own the channel.');
      await services.integrations.admission(input.principal, bot.id);
      for (const attachmentId of input.attachmentIds ?? []) services.auth.attachment(input.principal, attachmentId);
      const key = services.mutations.digest([binding.id, input.externalThreadId, input.principal.userId]);
      let thread = services.store.get<ChannelThread>('channelThreads', key);
      if (!thread) {
        // Per-principal thread rooms deliberately never import another member's private Team DM/notes.
        const conversation: P.Conversation = services.resource('conversation', { kind: 'channel', name: `${binding.adapter} thread`, botIds: [bot.id], humanUserIds: [input.principal.userId], ownerUserId: input.principal.userId, parentConversationId: null, leadBotId: bot.id, channelBindingId: binding.id, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] });
        services.store.put('conversations', conversation);
        thread = { id: key, channelBindingId: binding.id, externalThreadId: input.externalThreadId, userId: input.principal.userId, conversationId: conversation.id, externalTarget: input.externalThreadId.split(':')[0] ?? binding.target };
        services.store.put('channelThreads', thread);
        services.events.emit('conversation.upserted', conversation, { userIds: [input.principal.userId], conversationId: conversation.id });
      }
      services.store.setMetadata(`externalSubmission:${input.principal.kind}:${input.principal.id}:${thread.conversationId}:${input.clientNonce}`, { provider: binding.adapter, ...(binding.adapter === 'slack' && !application && links.length ? { humanText: input.text } : {}) });
      return services.runtime.send(input.principal, thread.conversationId, { clientNonce: input.clientNonce, text: untrusted({ adapter: binding.adapter, externalThreadId: input.externalThreadId, text: input.text }), attachmentIds: input.attachmentIds });
    },
    assertChannelHandoff: (principal: Principal, source: P.Conversation, target: P.Bot, returnConversationId: string): void => {
      services.auth.bot(principal, target.id); const returned = services.auth.conversation(principal, returnConversationId);
      if (source.kind !== 'channel') { if (returned.kind === 'channel') throw new IntegrationError('forbidden', 'Private context cannot be returned through an unrelated channel thread.'); return; }
      const thread = services.store.list<ChannelThread>('channelThreads', item => item.conversationId === source.id && item.userId === principal.userId)[0];
      if (!thread || target.visibility === 'personal' && !thread.externalTarget.startsWith('D')) throw new IntegrationError('forbidden', 'Shared channel handoff cannot expose a personal Bot’s private context.');
      if (source.ownerUserId !== principal.userId || returnConversationId !== source.id || target.visibility === 'personal' && target.ownerUserId !== principal.userId || target.visibility === 'team' && !target.published) throw new IntegrationError('forbidden', 'Channel handoff must preserve the verified actor and originating thread.');
    },
    returnChannelHandoff: async (principal: Principal, conversationId: string, text: string, sourceRunId?: string): Promise<void> => {
      const conversation = services.auth.conversation(principal, conversationId);
      const thread = services.store.list<ChannelThread>('channelThreads', item => item.conversationId === conversation.id && item.userId === principal.userId)[0];
      if (!thread || conversation.ownerUserId !== principal.userId) throw new IntegrationError('forbidden', 'Only the originating actor may return this handoff.');
      const binding = services.store.require<P.ChannelBinding>('channelBindings', thread.channelBindingId);
      await channelPolicy(services, principal, binding.botId, binding.adapter);
      if (!binding.enabled || binding.state !== 'connected' || binding.adapter !== 'slack') throw new IntegrationError('policy_denied', 'Originating Slack binding is not active.');
      if (!sourceRunId) throw new IntegrationError('conflict', 'A verified specialist run is required for channel return.');
      const run = services.store.require<P.Run>('runs', sourceRunId);
      if (run.initiatorUserId !== principal.userId) throw new IntegrationError('forbidden', 'Handoff return cannot change the initiating principal.');
      const key = services.mutations.digest([conversation.id, sourceRunId]); const prior = services.store.get<ChannelReturn>('channelReturns', key);
      if (prior?.state === 'sent') return;
      if (prior) throw new IntegrationError('outcome_unknown', 'Origin thread return is awaiting provider reconciliation.', false);
      const reply: ChannelReturn = { id: key, conversationId: conversation.id, userId: principal.userId, channelBindingId: binding.id, target: thread.externalTarget, thread: thread.externalThreadId.split(':')[1] ?? null, text, sourceRunId, startedAtMs: services.now(), state: 'reserved', providerMessageId: null };
      services.store.put('channelReturns', reply);
      const result = providerResult(z.object({ ts: id }), await slackCall(services, binding, 'chat.postMessage', { channel: reply.target, thread_ts: reply.thread ?? undefined, text, client_msg_id: slackMessageKey(key), unfurl_links: false, unfurl_media: false }), true);
      services.store.put('channelReturns', { ...reply, state: 'sent', providerMessageId: result.ts });
    },
    sendApprovedDraft: async (principal: Principal, draft: P.Draft): Promise<{ providerMessageId: string | null; runId: string | null }> => {
      if (draft.ownerUserId !== principal.userId || draft.state !== 'sending' || draft.content.kind === 'email') throw new IntegrationError('forbidden', 'Only an explicitly approved sending draft may be delivered.');
      const persisted = services.store.require<P.Draft>('drafts', draft.id);
      if (persisted.state !== 'sending' || persisted.revision !== draft.revision || services.mutations.digest(persisted.content) !== services.mutations.digest(draft.content)) throw new IntegrationError('conflict', 'Approved channel draft content changed.');
      const delivery = services.store.metadata<{ providerMessageId: string | null; runId: string | null }>(`channelDraftSent:${draft.id}`);
      if (delivery) return delivery;
      if (services.store.metadata<boolean>(`channelDraftReserved:${draft.id}`)) throw new IntegrationError('outcome_unknown', 'Channel draft delivery is already reserved; do not redispatch.', false);
      services.auth.conversation(principal, draft.conversationId); services.auth.bot(principal, draft.botId);
      const content = draft.content;
      const binding = content.kind === 'message' ? services.store.require<P.ChannelBinding>('channelBindings', content.channelBindingId) : services.store.get<P.ChannelBinding>('channelBindings', content.connectorId);
      if (!binding || binding.botId !== draft.botId || !binding.enabled || binding.state !== 'connected' || !binding.capabilities.outbound) throw new IntegrationError('policy_denied', 'Approved channel identity is not available.');
      await channelPolicy(services, principal, binding.botId, binding.adapter);
      if (content.kind === 'slack' && binding.adapter !== 'slack') throw new IntegrationError('forbidden', 'Slack draft requires its exact installed Slack identity.');
      const thread = services.store.list<ChannelThread>('channelThreads', item => item.conversationId === draft.conversationId)[0];
      if (thread && (thread.userId !== principal.userId || content.target !== thread.externalTarget || content.thread !== (thread.externalThreadId.split(':')[1] ?? null))) throw new IntegrationError('forbidden', 'Channel return cannot change its verified actor or originating thread.');
      if (content.attachmentIds.length > 6) throw new IntegrationError('too_large', 'Channel messages support at most six attachments.');
      for (const attachmentId of content.attachmentIds) services.auth.attachment(principal, attachmentId);
      if (binding.adapter === 'slack') {
        const account = services.store.require<ChannelAccount>('channelAccounts', binding.accountId);
        if (content.kind === 'slack' && content.workspace !== account.teamId) throw new IntegrationError('forbidden', 'Slack workspace does not match the approved app account.');
        services.store.transaction(() => {
          if (services.store.metadata<boolean>(`channelDraftReserved:${draft.id}`)) throw new IntegrationError('outcome_unknown', 'Channel draft is already reserved.', false);
          services.store.setMetadata(`channelDraftReserved:${draft.id}`, true);
        });
        const uploads: { id: string; title: string }[] = [];
        for (const attachmentId of content.attachmentIds) {
          const attachment = services.auth.attachment(principal, attachmentId);
          const upload = parse(z.object({ upload_url: z.string().url(), file_id: id }), await slackCall(services, binding, 'files.getUploadURLExternal', { filename: attachment.filename, length: attachment.size }));
          const destination = new URL(upload.upload_url);
          if (destination.protocol !== 'https:' || destination.hostname !== 'files.slack.com') throw new IntegrationError('upstream_unavailable', 'Slack returned an unsupported file upload origin.');
          try {
            const response = await pinnedRequest(destination.href, { method: 'POST', body: Buffer.from(await services.attachments.bytes(attachment.id)) }, { allowedOrigins: ['https://files.slack.com'], mutation: true });
            if (!response.ok) throw new Error('Upload failed');
          } catch { throw new IntegrationError('outcome_unknown', 'Slack file upload acknowledgment was lost.', false); }
          uploads.push({ id: upload.file_id, title: attachment.filename });
        }
        if (uploads.length) await slackCall(services, binding, 'files.completeUploadExternal', { files: uploads, channel_id: content.target, thread_ts: content.thread ?? undefined });
        let posted: { ts: string };
        try { posted = providerResult(z.object({ ts: id }), await slackCall(services, binding, 'chat.postMessage', { channel: content.target, thread_ts: content.thread ?? undefined, text: content.body, client_msg_id: slackMessageKey(draft.id), unfurl_links: false, unfurl_media: false }), true); }
        catch (error) { if (uploads.length) throw new IntegrationError('outcome_unknown', 'Slack attachments may already be delivered; text acknowledgment is not confirmed.', false); if (error instanceof IntegrationError && error.retrySafe) services.store.setMetadata(`channelDraftReserved:${draft.id}`, false); throw error; }
        const receipt = { providerMessageId: posted.ts, runId: null };
        services.store.setMetadata(`channelDraftSent:${draft.id}`, receipt); return receipt;
      }
      const provider = channelProvider(services, binding);
      if (!provider.accountSecretRef) throw new IntegrationError('capability_unavailable', 'Configure outbound adapter account credentials.');
      const attachments = [];
      for (const attachmentId of content.attachmentIds) { const attachment = services.auth.attachment(principal, attachmentId); attachments.push({ filename: attachment.filename, mime: attachment.mime, dataBase64: Buffer.from(await services.attachments.bytes(attachment.id)).toString('base64') }); }
      services.store.transaction(() => {
        if (services.store.metadata<boolean>(`channelDraftReserved:${draft.id}`)) throw new IntegrationError('outcome_unknown', 'Channel draft is already reserved.', false);
        services.store.setMetadata(`channelDraftReserved:${draft.id}`, true);
      });
      const result = providerResult(z.strictObject({ accepted: z.literal(true), messageId: id }), await providerRequest(services, provider.apiBaseUrl, 'messages', await services.secret(provider.accountSecretRef), 'POST', { accountId: binding.accountId, target: content.target, thread: content.thread, text: content.body, attachments, idempotencyKey: draft.id }), true);
      const receipt = { providerMessageId: result.messageId, runId: null };
      services.store.setMetadata(`channelDraftSent:${draft.id}`, receipt); return receipt;
    },
  };
  channelInstances.set(services, integration); return integration;
}
export function createChannelRoutes(services: BackendServices): Route[] {
  return [
    { method: 'GET', path: '/v1/channels/providers', auth: 'member', handler: () => createChannelServices(services).inventory() },
    { method: 'GET', path: '/v1/channels', auth: 'member', handler: context => { const principal = requireUser(context); return services.page(context, services.store.list<P.ChannelBinding>('channelBindings', binding => (!context.query.get('botId') || binding.botId === context.query.get('botId')) && services.auth.canRead(principal, 'channelBindings', binding))); } },
    { method: 'POST', path: '/v1/channels', auth: 'member', handler: context => bindingForCreate(services, requireUser(context), parse(createBody, context.body)) },
    { method: 'PATCH', path: '/v1/channels/:id', auth: 'member', handler: async context => {
      const principal = requireUser(context); const body = parse(updateBody.extend({ target: z.string().min(1).max(256).optional(), enabled: z.boolean().optional() }), context.body); const binding = services.store.require<P.ChannelBinding>('channelBindings', context.params.id!);
      await channelPolicy(services, principal, binding.botId, binding.adapter, true); services.mutations.checkRevision(binding, body.revision);
      if (binding.adapter === 'email' && (binding.ownerUserId !== principal.userId || body.target !== undefined && body.target !== binding.target)) throw new IntegrationError('forbidden', 'Mailbox channel management is owner-only; the account-owned address cannot be renamed.');
      if (body.target && body.target !== binding.target && binding.adapter === 'slack') { await slackCall(services, binding, 'conversations.join', { channel: body.target }); await slackCall(services, binding, 'chat.postMessage', { channel: body.target, text: 'Lemon Bot joined. Mention the app to start a thread. Each participant must link their own product account.', unfurl_links: false }); }
      const updated = services.update(binding, { ...(body.target === undefined ? {} : { target: body.target }), ...(body.enabled === undefined ? {} : { enabled: body.enabled }) });
      if (binding.adapter !== 'slack' && binding.adapter !== 'email') { const provider = channelProvider(services, binding); if (!provider.accountSecretRef) throw new IntegrationError('capability_unavailable', 'Configure adapter credentials.'); await providerRequest(services, provider.apiBaseUrl, `bindings/${encodeURIComponent(binding.id)}`, await services.secret(provider.accountSecretRef), 'PATCH', { target: updated.target, enabled: updated.enabled, idempotencyKey: body.clientNonce }); }
      services.store.put('channelBindings', updated); services.events.emit('channel.upserted', updated, { botId: binding.botId, userIds: [binding.ownerUserId] }); return updated;
    } },
    { method: 'DELETE', path: '/v1/channels/:id', auth: 'member', handler: async context => {
      const principal = requireUser(context); const body = parse(updateBody, context.body); const binding = services.store.require<P.ChannelBinding>('channelBindings', context.params.id!);
      const lifecycle = context.internalBotLifecycle;
      if (lifecycle) {
        const bot = services.store.require<P.Bot>('bots', binding.botId);
        const operation = services.store.metadata<{ action: string; userId: string; revision: number; status: string }>(`botLifecycle:${bot.id}`);
        if (lifecycle.botId !== bot.id || lifecycle.userId !== principal.userId || lifecycle.action !== 'delete' || operation?.action !== 'delete' || operation.userId !== principal.userId || operation.revision !== bot.revision || operation.status !== 'running') throw new IntegrationError('forbidden', 'Confirmed Bot lifecycle authority does not match this binding.');
        if (bot.ownerUserId !== principal.userId) { if (bot.visibility !== 'team') throw new IntegrationError('forbidden', 'Private Bot cleanup is owner-only.'); services.auth.requireRole(principal, 'admin'); }
      } else services.auth.bot(principal, binding.botId, true);
      services.mutations.checkRevision(binding, body.revision);
      if (binding.adapter === 'email' && !lifecycle && binding.ownerUserId !== principal.userId) throw new IntegrationError('not_found', 'Own mailbox channel was not found.');
      const disabled = services.update(binding, { enabled: false, state: 'disconnected' as const }); services.store.put('channelBindings', disabled);
      services.events.emit('channel.upserted', disabled, { botId: binding.botId, userIds: [binding.ownerUserId] });
      try {
        if (binding.adapter === 'email') {
          const account = services.store.get<P.EmailAccount>('emailAccounts', binding.accountId);
          if (account?.channelBindingId === binding.id) { const detached = services.update(account, { channelBindingId: null }); services.store.put('emailAccounts', detached); services.events.emit('email_account.upserted', detached, { userIds: [account.userId] }); }
        } else {
        const provider = channelProvider(services, binding);
        if (binding.adapter === 'slack') {
          const account = services.store.require<ChannelAccount>('channelAccounts', binding.accountId);
          if (account.appId && provider.oauth) await slackCall(services, binding, 'apps.uninstall', { client_id: provider.oauth.clientId, client_secret: await services.secret(provider.oauth.clientSecretRef) });
          else await slackCall(services, binding, 'auth.revoke', {});
          services.store.remove('channelAccounts', binding.accountId);
        } else { if (!provider.accountSecretRef) throw new IntegrationError('capability_unavailable', 'Configure adapter cleanup credentials.'); await providerRequest(services, provider.apiBaseUrl, `bindings/${encodeURIComponent(binding.id)}`, await services.secret(provider.accountSecretRef), 'DELETE', { idempotencyKey: body.clientNonce }); }
        }
      } catch (error) {
        const failed = services.update(disabled, { state: 'failed' as const, lastError: 'Provider-admin cleanup is required; ingress is disabled.' }); services.store.put('channelBindings', failed); services.events.emit('channel.upserted', failed, { userIds: [binding.ownerUserId] });
        services.audit(principal, 'channel.remove', binding.id, 'outcome_unknown', { cleanupRequired: true }); throw error;
      }
      for (const link of services.store.list<P.ChannelPrincipalLink>('channelPrincipalLinks', item => item.channelBindingId === binding.id)) services.store.remove('channelPrincipalLinks', link.id);
      for (const flow of services.store.list<P.ChannelLinkFlow>('channelLinkFlows', item => item.channelBindingId === binding.id)) { services.store.put('channelLinkFlows', services.update(flow, { state: 'cancelled', linkCode: null, verificationCode: null })); services.store.setMetadata(`channelLinkVerification:${flow.id}`, null); }
      services.store.remove('channelBindings', binding.id); const deleted: P.Deleted = { id: binding.id, deleted: true }; services.events.emit('channel.deleted', deleted, { botId: binding.botId, userIds: [binding.ownerUserId] }); return deleted;
    } },
    { method: 'POST', path: '/v1/channels/setup', auth: 'member', handler: async context => {
      const principal = requireUser(context); const body = parse(setupBody, context.body); const bot = await channelPolicy(services, principal, body.botId, body.adapter, true);
      const provider = services.config.operator.channelProviders.find(item => item.id === body.providerId && item.adapter === body.adapter);
      if (body.adapter !== 'slack' || !provider?.oauth || !provider.supportsBotAppInstall) throw new IntegrationError('capability_unavailable', 'Configure the per-Bot Slack OAuth app installation provider.');
      if (!bot.published || bot.visibility !== 'team') throw new IntegrationError('policy_denied', 'Publish the Team Bot before installing its app.');
      if (services.store.list<ChannelAccount>('channelAccounts', account => account.providerId === provider.id && account.botId !== bot.id).length) throw new IntegrationError('conflict', 'A per-Bot app provider cannot be shared with another Bot.');
      const flow: P.ChannelSetupFlow = services.resource('channel_setup', { botId: bot.id, adapter: body.adapter, authorizationUrl: null, state: 'pending', channelBindingId: null, error: null });
      const authorization = startOAuth(services, provider.oauth, { userId: principal.userId, resourceId: flow.id, callbackPath: '/v1/channels/oauth/callback', clientRedirectUri: body.redirectUri });
      // Slack's installation endpoint uses comma-separated bot scopes.
      const authorizationUrl = new URL(authorization.authorizationUrl); authorizationUrl.searchParams.set('scope', provider.oauth.scopes.join(','));
      flow.authorizationUrl = authorizationUrl.href;
      const record: SetupState = { id: authorization.flow.id, flowId: flow.id, providerId: provider.id, userId: principal.userId, expiresAtMs: authorization.flow.expiresAtMs };
      services.store.put('channelSetupStates', record); services.store.put('channelSetups', flow); services.events.emit('channel_setup.upserted', flow, { userIds: [principal.userId] }); return flow;
    } },
    { method: 'GET', path: '/v1/channels/setup/:id', auth: 'member', handler: context => { const principal = requireUser(context); const flow = services.store.require<P.ChannelSetupFlow>('channelSetups', context.params.id!); services.auth.bot(principal, flow.botId, true); const state = services.store.list<SetupState>('channelSetupStates', item => item.flowId === flow.id)[0]; if (state?.userId !== principal.userId) throw new IntegrationError('not_found', 'Channel setup was not found.'); if (state.expiresAtMs <= services.now() && flow.state === 'pending') throw new IntegrationError('expired', 'Channel setup expired.'); return flow; } },
    { method: 'GET', path: '/v1/channels/oauth/callback', auth: 'public', mutation: false, handler: async context => {
      const oauth = takeOAuthState(services, context.query.get('state') ?? '');
      const state = services.store.require<SetupState>('channelSetupStates', oauth.id);
      const principal = principalFor(services, state.userId); const flow = services.store.require<P.ChannelSetupFlow>('channelSetups', state.flowId); await channelPolicy(services, principal, flow.botId, flow.adapter, true);
      const provider = services.config.operator.channelProviders.find(item => item.id === state.providerId && item.oauth?.id === oauth.providerId);
      if (!provider?.oauth) throw new IntegrationError('capability_unavailable', 'Channel OAuth provider is no longer configured.');
      let updated: P.ChannelSetupFlow;
      if (context.query.get('error')) updated = services.update(flow, { state: context.query.get('error') === 'access_denied' ? 'denied' : 'awaiting_admin', error: 'Provider denied installation or requires workspace administrator approval.' });
      else {
        const code = context.query.get('code'); if (!code) throw new IntegrationError('invalid_request', 'OAuth authorization code is required.');
        try {
          const tokens = await exchangeOAuth(services, provider.oauth, oauth, code, { tokenTypes: ['bot', 'bearer'] });
          const token = parse(z.object({ ok: z.literal(true), access_token: z.string().min(1), team: z.object({ id }), authed_user: z.object({ id }), bot_user_id: id, app_id: id.optional() }), tokens.providerData);
          const account: ChannelAccount = { id: services.id('channel_account'), providerId: provider.id, teamId: token.team.id, botUserId: token.bot_user_id, appId: token.app_id ?? null, token: services.encrypt(token.access_token), installerUserId: token.authed_user.id, productUserId: principal.userId, botId: flow.botId };
          assertActiveAccount(services, principal.userId, true);
          services.store.put('channelAccounts', account);
          const binding: P.ChannelBinding = services.resource('channel', { botId: flow.botId, ownerUserId: principal.userId, adapter: flow.adapter, accountId: account.id, target: token.team.id, enabled: true, state: 'configured', capabilities: provider.capabilities, lastError: null });
          const identity = parse(z.object({ team_id: id, user_id: id }), await slackCall(services, binding, 'auth.test', {}));
          if (identity.team_id !== token.team.id || identity.user_id !== token.bot_user_id) throw new IntegrationError('unauthenticated', 'Slack installation identity did not match OAuth.');
          const installer = parse(z.object({ user: z.object({ id, is_admin: z.boolean().optional(), is_owner: z.boolean().optional(), deleted: z.boolean().optional() }) }), await slackCall(services, binding, 'users.info', { user: token.authed_user.id }));
          if (installer.user.deleted || installer.user.id !== token.authed_user.id) throw new IntegrationError('unauthenticated', 'Slack installer identity is disabled.');
          if (!installer.user.is_admin && !installer.user.is_owner) { await slackCall(services, binding, 'auth.revoke', {}); services.store.remove('channelAccounts', account.id); markOAuthInstalled(services, oauth.id); updated = services.update(flow, { state: 'awaiting_admin', error: 'An actual Slack workspace administrator must approve installation.' }); }
          else {
            assertActiveAccount(services, principal.userId, true);
            const active = services.update(binding, { state: 'connected' as const }); services.store.put('channelBindings', active);
            markOAuthInstalled(services, oauth.id);
            await sendLinkInstructions(services, active, token.authed_user.id);
            updated = services.update(flow, { state: 'connected', channelBindingId: active.id, error: null }); services.events.emit('channel.upserted', active, { botId: active.botId, userIds: [principal.userId] });
          }
        } catch (error) { updated = services.update(flow, { state: 'failed', error: error instanceof IntegrationError ? error.message : 'Channel installation failed; check provider-admin installation state.' }); }
      }
      assertActiveAccount(services, principal.userId, true);
      services.store.put('channelSetups', updated); services.events.emit('channel_setup.upserted', updated, { userIds: [principal.userId] }); return updated;
    } },
    { method: 'POST', path: '/v1/channels/principal-links/start', auth: 'member', handler: async context => {
      const principal = requireUser(context); const body = parse(z.strictObject({ clientNonce: nonce, channelBindingId: id }), context.body);
      const binding = services.store.require<P.ChannelBinding>('channelBindings', body.channelBindingId); await channelPolicy(services, principal, binding.botId, binding.adapter);
      if (!binding.enabled || binding.state !== 'connected' || binding.adapter === 'email') throw new IntegrationError('policy_denied', 'Linking requires an active externally authenticated channel.');
      const linkCode = randomBytes(24).toString('base64url');
      const flow: P.ChannelLinkFlow = services.resource('channel_link_flow', { userId: principal.userId, channelBindingId: binding.id, state: 'awaiting_external', linkCode: null, instructions: 'Send the displayed link code in your own DM to this channel app, then return here to complete the verified identity link.', externalUserId: null, externalDisplayName: null, verificationCode: null, expiresAtMs: services.now() + 600000 });
      services.store.put('channelLinkFlows', flow); services.store.setMetadata(`channelLinkCode:${services.mutations.digest(linkCode)}`, flow.id);
      if (binding.adapter !== 'slack') {
        const provider = channelProvider(services, binding); if (!provider.accountSecretRef) throw new IntegrationError('capability_unavailable', 'Configure adapter identity verification credentials.');
        parse(z.strictObject({ registered: z.literal(true) }), await providerRequest(services, provider.apiBaseUrl, 'identity-links', await services.secret(provider.accountSecretRef), 'POST', { flowId: flow.id, accountId: binding.accountId, linkCode, expiresAtMs: flow.expiresAtMs }));
      }
      return { ...flow, linkCode };
    } },
    { method: 'GET', path: '/v1/channels/principal-links/flows/:id', auth: 'member', handler: async context => {
      const principal = requireUser(context); let flow = services.store.require<P.ChannelLinkFlow>('channelLinkFlows', context.params.id!);
      if (flow.userId !== principal.userId) throw new IntegrationError('not_found', 'Own channel link flow was not found.');
      if (flow.expiresAtMs <= services.now() && !['completed', 'cancelled'].includes(flow.state)) { flow = services.update(flow, { state: 'expired', linkCode: null, verificationCode: null }); services.store.put('channelLinkFlows', flow); return flow; }
      const binding = services.store.require<P.ChannelBinding>('channelBindings', flow.channelBindingId); services.auth.bot(principal, binding.botId);
      if (binding.adapter !== 'slack' && flow.state === 'awaiting_external') {
        const provider = channelProvider(services, binding); if (!provider.accountSecretRef) throw new IntegrationError('capability_unavailable', 'Configure adapter identity proof credentials.');
        const proof = parse(z.strictObject({ verified: z.boolean(), externalUserId: id.nullable(), externalDisplayName: z.string().max(120).nullable() }), await providerRequest(services, provider.apiBaseUrl, `identity-links/${encodeURIComponent(flow.id)}`, await services.secret(provider.accountSecretRef)));
        if (proof.verified && proof.externalUserId) flow = recordChannelProof(services, flow, proof.externalUserId, proof.externalDisplayName);
      }
      const encrypted = services.store.metadata<string>(`channelLinkVerification:${flow.id}`);
      return { ...flow, verificationCode: flow.state === 'verified' && encrypted ? services.decrypt<string>(encrypted) : null };
    } },
    { method: 'POST', path: '/v1/channels/principal-links', auth: 'member', handler: context => {
      const principal = requireUser(context); principalFor(services, principal.userId); const body = parse(linkBody, context.body); const binding = services.store.require<P.ChannelBinding>('channelBindings', body.channelBindingId); services.auth.bot(principal, binding.botId);
      const proof = services.store.get<LinkProof>('channelLinkProofs', services.mutations.digest(body.verificationCode));
      const flow = proof ? services.store.get<P.ChannelLinkFlow>('channelLinkFlows', proof.flowId) : null;
      if (!proof || proof.used || !flow || flow.state !== 'verified' || flow.userId !== principal.userId || flow.channelBindingId !== binding.id || flow.externalUserId !== body.externalUserId) throw new IntegrationError('unauthenticated', 'Complete your own signed channel DM challenge before linking.');
      if (flow.expiresAtMs <= services.now()) throw new IntegrationError('expired', 'Channel identity challenge expired.');
      const existing = services.store.list<P.ChannelPrincipalLink>('channelPrincipalLinks', item => item.channelBindingId === binding.id && item.externalUserId === body.externalUserId)[0];
      if (existing && existing.userId !== principal.userId) throw new IntegrationError('conflict', 'Channel identity is already linked to a different product account.');
      return services.store.transaction(() => { services.store.put('channelLinkProofs', { ...proof, used: true }); services.store.put('channelLinkFlows', services.update(flow, { state: 'completed', verificationCode: null, linkCode: null })); services.store.setMetadata(`channelLinkVerification:${flow.id}`, null); const link: P.ChannelPrincipalLink = existing ?? services.resource('channel_link', { channelBindingId: binding.id, externalUserId: body.externalUserId, userId: principal.userId, verified: true }); services.store.put('channelPrincipalLinks', link); services.audit(principal, 'channel.link', binding.id, 'succeeded'); return link; });
    } },
    { method: 'GET', path: '/v1/channels/principal-links', auth: 'member', handler: context => { const principal = requireUser(context); return services.page(context, services.store.list<P.ChannelPrincipalLink>('channelPrincipalLinks', item => item.userId === principal.userId)); } },
    { method: 'DELETE', path: '/v1/channels/principal-links/:id', auth: 'member', handler: context => { const principal = requireUser(context); const body = parse(updateBody, context.body); const link = services.store.require<P.ChannelPrincipalLink>('channelPrincipalLinks', context.params.id!); if (link.userId !== principal.userId) throw new IntegrationError('not_found', 'Own channel identity link was not found.'); services.mutations.checkRevision(link, body.revision); services.store.remove('channelPrincipalLinks', link.id); return { id: link.id, deleted: true }; } },
    { method: 'POST', path: '/v1/integrations/slack/events', auth: 'public', mutation: false, body: 'none', handler: async context => {
      const raw = await rawBody(context.request); let decoded: unknown; try { decoded = JSON.parse(raw); } catch { throw new IntegrationError('invalid_request', 'Invalid Slack event JSON.'); }
      const envelope = parse(z.object({ type: z.string(), team_id: id.optional(), api_app_id: id.optional(), event_id: id.optional(), challenge: z.string().optional(), event: z.object({ type: z.string(), user: id.optional(), channel: id.optional(), channel_type: z.string().optional(), text: z.string().max(65536).optional(), ts: z.string().optional(), thread_ts: z.string().optional(), subtype: z.string().optional(), bot_id: id.optional(), app_id: id.optional(), bot_profile: z.object({ app_id: id.optional() }).passthrough().optional(), event_ts: z.string().optional() }).passthrough().optional() }), decoded);
      const account = services.store.list<ChannelAccount>('channelAccounts', item => item.teamId === envelope.team_id && (!envelope.api_app_id || item.appId === envelope.api_app_id))[0];
      const provider = account ? services.config.operator.channelProviders.find(item => item.id === account.providerId) : services.config.operator.channelProviders.find(item => item.adapter === 'slack' && item.id === context.query.get('providerId'));
      if (!provider?.signingSecretRef) throw new IntegrationError('capability_unavailable', 'Configure the installed Slack app signing secret.');
      await verifyIngress(services, context.request, raw, provider.id, 'slack', provider.signingSecretRef, 300000, decoded);
      if (envelope.type === 'url_verification' && envelope.challenge) return { challenge: envelope.challenge };
      if (!account || !envelope.event || !envelope.event_id) return ignored('No installed app or supported Slack event.');
      const binding = services.store.list<P.ChannelBinding>('channelBindings', item => item.accountId === account.id)[0]; const event = envelope.event;
      if (!binding) return ignored('Slack app binding was removed.');
      return dedupeIngress(services, provider.id, envelope.event_id, decoded, async () => {
        if (!binding.enabled || binding.state !== 'connected') return ignored('Slack binding is disabled.');
        if (event.type === 'member_joined_channel' && event.user === account.botUserId && event.channel) {
          const invitedAtMs = Number(event.event_ts) * 1000;
          if (!Number.isFinite(invitedAtMs) || Math.abs(services.now() - invitedAtMs) > 300000 || invitedAtMs < binding.createdAtMs) return ignored('Old app invitations are not backfilled.');
          await slackCall(services, binding, 'chat.postMessage', { channel: event.channel, text: 'Lemon Bot joined. Mention this app to start a thread; each participant must first link their own enabled Lemon Bot account.', client_msg_id: slackMessageKey(services.mutations.digest([provider.id, envelope.event_id])), unfurl_links: false, unfurl_media: false });
          return ignored('App invitation welcome was delivered; no work was started.');
        }
        if (!event.channel || !event.ts || !['message', 'app_mention'].includes(event.type) || event.subtype && event.subtype !== 'bot_message') return ignored('Only new messages and app mentions may start work.');
        const eventAtMs = Number(event.event_ts ?? event.ts) * 1000;
        if (!Number.isFinite(eventAtMs) || Math.abs(services.now() - eventAtMs) > 300000 || eventAtMs < binding.createdAtMs) return ignored('Old Slack events are not backfilled.');
        if (event.bot_id) {
          const appId = event.app_id ?? event.bot_profile?.app_id;
          const principal = appId ? applicationPrincipal(services, binding, appId) : null;
          if (!principal) return ignored('This application has no fixed operator principal grant.');
          const result = await createChannelServices(services).channelIngress({ principal, botId: binding.botId, channelBindingId: binding.id, externalThreadId: `${event.channel}:${event.thread_ts ?? event.ts}`, text: event.text ?? '', clientNonce: services.mutations.digest([provider.id, envelope.event_id]) });
          const run = result.runs[0]; if (!run) throw new IntegrationError('upstream_unavailable', 'Application dispatch returned no actual run.');
          return { accepted: result.status !== 'outcome_unknown', status: result.status === 'outcome_unknown' ? 'outcome_unknown' : 'accepted', reason: null, runId: run.id, conversationId: run.conversationId };
        }
        if (!event.user) return ignored('Verified human channel sender is required.');
        const direct = event.channel_type === 'im' || event.channel.startsWith('D');
        const linkFlowId = direct && event.text ? services.store.metadata<string>(`channelLinkCode:${services.mutations.digest(event.text.trim())}`) : null;
        if (linkFlowId) {
          const linkFlow = services.store.require<P.ChannelLinkFlow>('channelLinkFlows', linkFlowId);
          if (linkFlow.channelBindingId !== binding.id || linkFlow.state !== 'awaiting_external' || linkFlow.expiresAtMs <= services.now()) return ignored('Channel identity code is expired or already consumed.');
          principalFor(services, linkFlow.userId);
          recordChannelProof(services, linkFlow, event.user, null); services.store.setMetadata(`channelLinkCode:${services.mutations.digest(event.text!.trim())}`, null);
          await slackCall(services, binding, 'chat.postMessage', { channel: event.channel, text: 'Your own channel identity was verified. Return to Lemon Bot to complete the link. No work was started.', unfurl_links: false });
          return ignored('Own channel identity challenge verified; complete linking in the product.');
        }
        const link = services.store.list<P.ChannelPrincipalLink>('channelPrincipalLinks', item => item.channelBindingId === binding.id && item.externalUserId === event.user && item.verified)[0];
        if (!link) { await sendLinkInstructions(services, binding, event.user); return ignored('Own product account linking is required.'); }
        const principal = principalFor(services, link.userId);
        const threadId = direct ? event.channel : `${event.channel}:${event.thread_ts ?? event.ts}`;
        const prior = services.store.list<ChannelThread>('channelThreads', item => item.channelBindingId === binding.id && item.externalThreadId === threadId && item.userId === principal.userId)[0];
        if (!direct && event.type !== 'app_mention' && !prior) return ignored('Top-level channel participation requires an explicit app mention.');
        if (!direct && event.type === 'app_mention' && !event.text?.includes(`<@${account.botUserId}>`)) return ignored('An explicit mention of the installed app is required.');
        const result = await createChannelServices(services).channelIngress({ principal, botId: binding.botId, channelBindingId: binding.id, externalThreadId: threadId, text: event.text ?? '', clientNonce: services.mutations.digest([provider.id, envelope.event_id]) });
        const run = result.runs[0]; if (!run) throw new IntegrationError('upstream_unavailable', 'Slack dispatch returned no actual run.');
        return { accepted: result.status !== 'outcome_unknown', status: result.status === 'outcome_unknown' ? 'outcome_unknown' : 'accepted', reason: null, runId: run.id, conversationId: run.conversationId };
      });
    } },
  ];
}
