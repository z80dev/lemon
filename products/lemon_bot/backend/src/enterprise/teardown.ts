import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../core/services';
import { ApiError } from '../core/errors';
import type { OAuthCompletion, OAuthExchangeOperation } from '../integrations/oauth';
import type { OIDCExchangeOperation } from './identity';
export interface ProviderTeardownReceipt extends P.ProviderCleanupResult { id: string; operationId: string; userId: string; encryptedBinding: string }
export type CleanupKind = P.ProviderCleanupResult['kind'];
export interface ProviderTeardownHandlers { execute(userId: string, kind: CleanupKind): Promise<void>; observe(receipt: ProviderTeardownReceipt): Promise<P.AccountCleanupResult> }
const receipts = 'providerTeardownReceipts';
function projection(row: ProviderTeardownReceipt): P.ProviderCleanupResult { return { providerId: row.providerId, kind: row.kind, receiptId: row.id, state: row.state, updatedAtMs: row.updatedAtMs, errorCode: row.errorCode }; }
export function prepareProviderTeardown(s: BackendServices, userId: string, operationId: string): P.ProviderCleanupResult[] {
  const existing = s.store.list<ProviderTeardownReceipt>(receipts, row => row.operationId === operationId); if (existing.length || s.store.metadata(`providerTeardownPrepared:${operationId}`)) return existing.map(projection);
  return s.store.transaction(() => {
    const values: ProviderTeardownReceipt[] = [];
    function add(kind: CleanupKind, providerId: string, binding: unknown) { if (values.length >= 200) throw new ApiError('too_large', 'Account teardown supports at most 200 provider targets; disconnect additional integrations first.'); const row: ProviderTeardownReceipt = { id: s.id('cleanup'), operationId, userId, kind, providerId, receiptId: null, state: 'pending', updatedAtMs: s.now(), errorCode: null, encryptedBinding: s.encrypt(binding) }; row.receiptId = row.id; s.store.put(receipts, row); values.push(row); }
    const emails = s.store.list<P.EmailAccount>('emailAccounts', row => row.userId === userId && row.state !== 'retired');
    for (const account of emails) add('email', account.provider, { account, provider: s.config.operator.emailProviders.find(provider => provider.id === account.provider) ?? null });
    const claim = s.store.get<{ id: string; providerId: string; state: string }>('emailClaimReservations', userId); if (claim?.state === 'reserved') add('email', claim.providerId, { claim });
    for (const connection of s.store.list<P.XConnection>('xConnections', row => row.userId === userId)) add('x', s.config.operator.xProvider?.oauth.id ?? 'x', { connection, encryptedCredential: s.store.metadata(`xCredential:${connection.id}`), provider: s.config.operator.xProvider });
    for (const session of s.store.list<{ id: string; userId: string; providerId: string }>('oidcProviderSessions', row => row.userId === userId)) { const provider = s.store.get<P.OIDCProvider>('oidcProviders', session.providerId); add('oidc', session.providerId, { session, provider }); }
    for (const oidcExchange of s.store.list<OIDCExchangeOperation>('oidcExchangeOperations', row => row.userId === userId)) add('oidc', oidcExchange.providerId, { oidcExchange });
    for (const completion of s.store.list<OAuthCompletion>('oauthCompletions', row => row.userId === userId)) { const kind: CleanupKind = completion.callbackPath.includes('/connectors/') ? 'connector' : completion.callbackPath.includes('/x/') ? 'x' : 'channel'; add(kind, completion.providerId, { completion }); }
    for (const exchange of s.store.list<OAuthExchangeOperation>('oauthExchangeOperations', row => row.userId === userId && !s.store.get('oauthCompletions', row.id))) { const kind: CleanupKind = exchange.callbackPath.includes('/connectors/') ? 'connector' : exchange.callbackPath.includes('/x/') ? 'x' : 'channel'; add(kind, exchange.providerId, { exchange }); }
    for (const link of s.store.list<P.ChannelPrincipalLink>('channelPrincipalLinks', row => row.userId === userId)) { const channel = s.store.get<P.ChannelBinding>('channelBindings', link.channelBindingId); const account = channel ? s.store.get<{ id: string; providerId: string }>('channelAccounts', channel.accountId) : null; add('channel', account?.providerId ?? channel?.adapter ?? 'channel', { link }); }
    s.store.setMetadata(`providerTeardownPrepared:${operationId}`, { userId, preparedAtMs: s.now() });
    return values.map(projection);
  });
}
export function createProviderTeardownServices(s: BackendServices, handlers: ProviderTeardownHandlers) {
  async function observeAccountTeardown(operationId: string): Promise<P.ProviderCleanupResult[]> {
    const rows = s.store.list<ProviderTeardownReceipt>(receipts, row => row.operationId === operationId);
    for (const row of rows.filter(row => row.state !== 'completed' && row.state !== 'not_required')) {
      try { const observed = await handlers.observe(row); s.store.put(receipts, { ...row, ...observed }); }
      catch (error) { s.store.put(receipts, { ...row, state: 'outcome_unknown', errorCode: error instanceof ApiError ? error.code : 'upstream_unavailable', updatedAtMs: s.now() }); }
    }
    return s.store.list<ProviderTeardownReceipt>(receipts, row => row.operationId === operationId).map(projection);
  }
  async function deprovisionUser(userId: string): Promise<void> {
    const fence = s.store.metadata<{ operationId: string; nonce: string }>(`accountDeletion:${userId}`); if (!fence?.operationId) throw new ApiError('conflict', 'Provider teardown requires a confirmed account deletion operation.');
    prepareProviderTeardown(s, userId, fence.operationId);
    const stepsKey = `providerTeardownSteps:${fence.operationId}`;
    for (const kind of ['email', 'x', 'channel', 'oidc', 'connector'] as const) {
      const steps = s.store.metadata<Partial<Record<CleanupKind, P.AccountCleanupState>>>(stepsKey) ?? {};
      if (steps[kind]) continue; // Once dispatched, uncertainty is observed only; never replay an effect.
      s.store.setMetadata(stepsKey, { ...steps, [kind]: 'running' });
      for (const row of s.store.list<ProviderTeardownReceipt>(receipts, row => row.operationId === fence.operationId && row.kind === kind && row.state !== 'not_required')) s.store.put(receipts, { ...row, state: 'running', updatedAtMs: s.now() });
      try { await handlers.execute(userId, kind); s.store.setMetadata(stepsKey, { ...(s.store.metadata<Partial<Record<CleanupKind, P.AccountCleanupState>>>(stepsKey) ?? {}), [kind]: 'completed' }); }
      catch (error) { s.store.setMetadata(stepsKey, { ...(s.store.metadata<Partial<Record<CleanupKind, P.AccountCleanupState>>>(stepsKey) ?? {}), [kind]: 'outcome_unknown' }); for (const row of s.store.list<ProviderTeardownReceipt>(receipts, row => row.operationId === fence.operationId && row.kind === kind && row.state !== 'not_required')) s.store.put(receipts, { ...row, state: 'outcome_unknown', errorCode: error instanceof ApiError ? error.code : 'upstream_unavailable', updatedAtMs: s.now() }); }
    }
    const observed = await observeAccountTeardown(fence.operationId);
    if (observed.some(row => row.state !== 'completed' && row.state !== 'not_required')) throw new ApiError('outcome_unknown', 'Local account cleanup can continue; external provider receipts remain unconfirmed. Inspect the Owner account teardown status.', false, { resourceIds: [fence.operationId] });
  }
  return { prepareProviderTeardown: (userId: string, operationId: string) => prepareProviderTeardown(s, userId, operationId), deprovisionUser, observeAccountTeardown };
}
