import type * as P from '../../../contracts/protocol';
import type { BackendServices, IntegrationServices, Route } from '../core/services';
import { ApiError } from '../core/errors';
import { assertActiveAccount, userPrincipal } from './common';
import { createConnectorRoutes, createConnectorServices } from './connectors';
import type { InvocationMcpServer } from '../runtime/runs';
import { createChannelRoutes, createChannelServices } from './channels';
import { createEmailRoutes, createEmailServices } from './email';
import { createEventRoutes } from './events';
import { createXRoutes, createXServices } from './x';
import { createAudioRoutes, createAudioServices } from './audio';
import { createPushServices } from './push';
import { createProviderCatalogRoutes } from './catalog';
import { clearOAuthUserState, reconcileOAuthStates, registerOAuthLateCleanup, type OAuthCompletion, type OAuthExchangeOperation, type OAuthTokens } from './oauth';
import type { OAuthRevocationReceipt } from './oauth-revocation';
import { createIdentityRoutes, createIdentityServices } from '../enterprise/identity';
import { createSCIMRoutes } from '../enterprise/scim';
import { createTokenRoutes } from '../enterprise/tokens';
import { createPolicyRoutes, createPolicyServices, directoryAffectedUsers } from '../enterprise/policy';
import { createHostRoutes, createHostServices } from '../enterprise/host';
import { createSpendRoutes, createSpendServices } from '../enterprise/spend';
import { createExportRoutes, createExportServices } from '../enterprise/exports';
import { refreshEffectivePolicy } from '../enterprise/enforcement';
import { previewProviderDeprovision } from '../enterprise/account-effects';
import { createProviderTeardownServices, type CleanupKind, type ProviderTeardownReceipt } from '../enterprise/teardown';
import type { OIDCExchangeOperation } from '../enterprise/identity';

type Services = IntegrationServices & { observeAccountTeardown(operationId: string): Promise<P.ProviderCleanupResult[]>; connectorTemplates(botId: string): Promise<InvocationMcpServer[]> };
const instances = new WeakMap<BackendServices, Services>();
interface CleanupBinding {
  account?: P.EmailAccount; claim?: { id: string; providerId: string; accountId?: string; address?: string };
  connection?: P.XConnection; encryptedCredential?: string | null; session?: { id: string; userId: string; providerId: string };
  completion?: OAuthCompletion; exchange?: OAuthExchangeOperation; link?: P.ChannelPrincipalLink;
  oidcExchange?: OIDCExchangeOperation;
}
interface DeliveryCleanup { id: string; userId: string; providerId: string; resourceId?: string; completionId?: string | null; accountId?: string; address?: string; claimOperationId?: string | null; sessionId?: string; tokenType?: string; state: string; errorCode?: P.ErrorCode | null }

export function createIntegrationServices(s: BackendServices): Services {
  const existing = instances.get(s); if (existing) return existing;
  const policy = createPolicyServices(s), host = createHostServices(s), spend = createSpendServices(s), exports = createExportServices(s);
  const identity = createIdentityServices(s), connectors = createConnectorServices(s), channels = createChannelServices(s), email = createEmailServices(s), x = createXServices(s), audio = createAudioServices(s), push = createPushServices(s);
  async function cleanup(userId: string, kind: CleanupKind): Promise<void> {
    if (kind === 'email') await email.retireUser(userId);
    else if (kind === 'x') await x.retireUser(userId);
    else if (kind === 'channel') await channels.retireUser(userId);
    else if (kind === 'oidc') await identity.endProviderSessions(userId);
    else await connectors.cleanupOAuthUser(userId);
  }
  registerOAuthLateCleanup(s, completion => completion.callbackPath.includes('/connectors/') ? connectors.retireOAuthCompletion(completion) : completion.callbackPath.includes('/x/') ? x.retireOAuthCompletion(completion) : channels.retireOAuthCompletion(completion));
  function outcome(state: P.AccountCleanupState, errorCode: P.ErrorCode | null = null): P.AccountCleanupResult { return { state, errorCode, updatedAtMs: s.now() }; }
  function observedRows(rows: DeliveryCleanup[], expected: number): P.AccountCleanupResult {
    if (rows.length < expected || rows.some(row => !['retired', 'revoked', 'completed'].includes(row.state))) {
      const failed = rows.find(row => row.state === 'failed');
      return outcome(failed ? 'failed' : 'outcome_unknown', failed?.errorCode ?? (failed ? 'capability_unavailable' : 'outcome_unknown'));
    }
    return outcome('completed');
  }
  async function observe(receipt: ProviderTeardownReceipt): Promise<P.AccountCleanupResult> {
    const binding = s.decrypt<CleanupBinding>(receipt.encryptedBinding);
    let completion: OAuthCompletion | OAuthExchangeOperation | undefined = binding.completion;
    if (binding.exchange) {
      const operation = s.store.get<OAuthExchangeOperation>('oauthExchangeOperations', binding.exchange.id);
      if (!operation || operation.tokenClientDigest !== binding.exchange.tokenClientDigest || operation.userId !== receipt.userId) return outcome('outcome_unknown', 'outcome_unknown');
      if (operation.state === 'failed' && !s.store.get('oauthCompletions', operation.id)) return outcome('completed');
      if (operation.state !== 'issued') return outcome(operation.state === 'pending' ? 'pending' : 'outcome_unknown', operation.state === 'pending' ? null : 'outcome_unknown');
      completion = s.store.get<OAuthCompletion>('oauthCompletions', operation.id) ?? operation;
    }
    if (receipt.kind === 'email') {
      await email.reconcileUserCleanup(receipt.userId);
      const accountId = binding.account?.id ?? binding.claim?.accountId ?? binding.claim?.id;
      if (!accountId) return outcome('outcome_unknown', 'outcome_unknown');
      const rows = s.store.list<DeliveryCleanup>('emailRetirements', row => row.userId === receipt.userId && row.providerId === receipt.providerId && row.accountId === accountId && (!binding.account || row.address === binding.account.address));
      return observedRows(rows, 1);
    }
    if (receipt.kind === 'oidc') {
      const operation = binding.oidcExchange ? s.store.get<OIDCExchangeOperation>('oidcExchangeOperations', binding.oidcExchange.id) : null;
      if (binding.oidcExchange && (!operation || operation.userId !== receipt.userId || operation.providerId !== receipt.providerId)) return outcome('outcome_unknown', 'outcome_unknown');
      if (operation?.state === 'failed') return outcome('completed');
      if (operation && operation.state !== 'issued') return outcome(operation.state === 'pending' ? 'pending' : 'outcome_unknown', operation.state === 'pending' ? null : 'outcome_unknown');
      const sessionId = binding.session?.id ?? operation?.sessionId;
      if (!sessionId) return outcome('outcome_unknown', 'outcome_unknown');
      const rows = s.store.list<DeliveryCleanup>('oidcEndSessionReceipts', row => row.userId === receipt.userId && row.providerId === receipt.providerId && row.sessionId === sessionId);
      return observedRows(rows, 1);
    }
    if (receipt.kind === 'channel' && binding.link) {
      const step = s.store.metadata<Record<string, string>>(`providerTeardownSteps:${receipt.operationId}`)?.channel;
      return step === 'completed' && !s.store.get('channelPrincipalLinks', binding.link.id) ? outcome('completed') : outcome('outcome_unknown', 'outcome_unknown');
    }
    if (receipt.kind === 'channel') {
      await channels.reconcileUserCleanup(receipt.userId);
      if (!completion) return outcome('outcome_unknown', 'outcome_unknown');
      return observedRows(s.store.list<DeliveryCleanup>('slackCleanups', row => row.userId === receipt.userId && row.completionId === completion!.id && row.resourceId === completion!.resourceId), 1);
    }
    if (receipt.kind === 'x') {
      await x.reconcileUserCleanup(receipt.userId);
      const resourceId = binding.connection?.id ?? completion?.resourceId;
      if (!resourceId) return outcome('outcome_unknown', 'outcome_unknown');
      const tokenSnapshot = completion && 'encryptedTokens' in completion ? completion.encryptedTokens : binding.encryptedCredential;
      const credential = tokenSnapshot ? s.decrypt<{ accessToken?: string; refreshToken?: string; access_token?: string; refresh_token?: string }>(tokenSnapshot) : null;
      if (binding.connection && !tokenSnapshot && binding.connection.externalAccountId === null) return outcome('completed');
      const rows = s.store.list<DeliveryCleanup>('xRevocations', row => row.userId === receipt.userId && row.providerId === receipt.providerId && row.resourceId === resourceId && (!completion || row.completionId === completion.id));
      const required = credential?.refreshToken || credential?.refresh_token || completion && 'refreshIssued' in completion && completion.refreshIssued ? 2 : 1;
      if (!rows.some(row => row.tokenType === 'access_token') || required === 2 && !rows.some(row => row.tokenType === 'refresh_token')) return outcome('outcome_unknown', 'outcome_unknown');
      return observedRows(rows, required);
    }
    if (!completion) return outcome('outcome_unknown', 'outcome_unknown');
    await connectors.reconcileOAuthUser(receipt.userId);
    const revoked = s.store.get<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id);
    if (!revoked || revoked.userId !== receipt.userId || revoked.providerId !== receipt.providerId || revoked.resourceId !== completion.resourceId) return outcome('outcome_unknown', 'outcome_unknown');
    const refreshRequired = 'encryptedTokens' in completion ? !!s.decrypt<OAuthTokens>(completion.encryptedTokens).refresh_token : completion.refreshIssued === true;
    if (revoked.access.state === 'revoked' && (!refreshRequired || revoked.refresh?.state === 'revoked')) return outcome('completed');
    const failed = revoked.access.state === 'failed' ? revoked.access : revoked.refresh?.state === 'failed' ? revoked.refresh : null;
    return outcome(failed ? 'failed' : 'outcome_unknown', failed?.errorCode ?? 'outcome_unknown');
  }
  const teardown = createProviderTeardownServices(s, { execute: cleanup, observe });
  const service: Services = {
    effectivePolicy: policy.effectivePolicy,
    async admission(actor, botId, routineId) {
      assertActiveAccount(s, actor.userId); const bot = s.auth.bot(actor, botId);
      if (bot.ownerUserId !== actor.userId) throw new ApiError('not_found', 'Bot not found.');
      if (!(await policy.effectivePolicy(actor, botId)).productAccess) throw new ApiError('policy_denied', 'Directory and workspace policies do not grant product access.');
      await host.admission(actor, botId); await spend.admission(actor, botId, routineId);
    },
    connectorConfig: connectors.connectorProfileConfiguration, authorizeConnector: connectors.authorizeConnectorTool,
    connectorTemplates: connectors.connectorTemplates,
    connectorProvisioning: connectors.connectorProvisioning, deleteBotConnectors: connectors.deleteBotConnectors,
    sendApprovedDraft: (actor, draft) => draft.content.kind === 'email' ? email.sendApprovedDraft(actor, draft) : channels.sendApprovedDraft(actor, draft),
    emitProviderNotifications: push.emitProviderNotifications, channelIngress: channels.channelIngress,
    assertChannelHandoff: channels.assertChannelHandoff, returnChannelHandoff: channels.returnChannelHandoff,
    speech: audio.speech, requireSSO: identity.requireSSO, endProviderSessions: identity.endProviderSessions,
    deprovisionUser: async userId => { clearOAuthUserState(s, userId); await teardown.deprovisionUser(userId); },
    previewDeprovisionUser: userId => previewProviderDeprovision(s, userId), observeAccountTeardown: teardown.observeAccountTeardown,
    authorizeExportAttachment: exports.authorizeExportAttachment, captureAction: exports.captureAction, captureUsage: exports.captureUsage,
    refreshPolicy: (actor, botIds, options) => refreshEffectivePolicy(s, actor, botIds, options),
    providerCapabilities: () => ({ ...audio.providerCapabilities(), ...push.providerCapabilities(), inventory: [...channels.inventory(), ...email.inventory(), ...(x.inventory() ? [x.inventory()] : []), ...audio.inventory(), ...push.inventory()] }),
    canReadResource(actor, collection, entity) {
      for (const domain of [connectors, channels, email, x, host, exports]) { const decision = domain.canReadResource(actor, collection, entity); if (decision !== undefined) return decision; }
      if (['directoryGroups', 'groupPolicies', 'oidcProviders'].includes(collection)) {
        return (actor.role === 'admin' || actor.role === 'owner') && !!entity && typeof entity === 'object';
      }
      if (collection === 'spendLimits') return spend.canRead(actor, entity as P.SpendLimit);
      if (collection === 'identityLinks') return !!entity && typeof entity === 'object' && 'userId' in entity && entity.userId === actor.userId;
      if (collection === 'integrationTokens') return actor.role === 'owner';
      return false;
    },
    async reconcile() {
      reconcileOAuthStates(s);
      const results = await Promise.allSettled([host.reconcile(), connectors.reconcile(), channels.reconcile(), email.reconcile(), x.reconcile(), identity.reconcile(), exports.reconcile()]);
      const failed = results.find(result => result.status === 'rejected'); if (failed?.status === 'rejected') throw failed.reason;
    },
    async dispose() { exports.dispose(); await host.dispose(); instances.delete(s); },
  };
  instances.set(s, service); return service;
}

function synchronizeDirectoryRoutes(s: BackendServices, routes: Route[]): Route[] {
  return routes.map(route => {
    const directory = route.path.startsWith('/v1/directory/groups') || route.path.startsWith('/v1/scim/v2/Groups') || ['/v1/auth/oidc/complete', '/v1/auth/oidc/link'].includes(route.path);
    const governance = route.path === '/v1/governance';
    if ((!directory && !governance) || route.method === 'GET') return route;
    return { ...route, handler: async context => {
      const before = s.store.list<P.DirectoryGroup>('directoryGroups');
      const previousPolicies = s.store.list<P.GroupPolicy>('groupPolicies');
      const previousGovernanceRevision = s.store.metadata<P.Governance>('governance')?.revision ?? 1;
      let result: unknown, handlerError: unknown, failed = false;
      try { result = await route.handler(context); } catch (error) { failed = true; handlerError = error; }
      // A later auth/provider error does not undo committed desired authority. Fence it
      // before returning even a failed response; a read/error alone must never cancel work.
      if (governance && previousGovernanceRevision !== (s.store.metadata<P.Governance>('governance')?.revision ?? 1)) {
        if (!context.user) throw new ApiError('unauthenticated', 'Governance synchronization requires its authenticated mutation principal.');
        await refreshEffectivePolicy(s, context.user, undefined, { workspace: true });
      } else if (directory) {
        const changed = directoryAffectedUsers(before, s.store.list<P.DirectoryGroup>('directoryGroups'), previousPolicies, s.store.list<P.GroupPolicy>('groupPolicies'));
        for (const userId of changed) {
          const member = s.store.list<P.Member>('members', value => value.userId === userId)[0];
          if (member?.enabled) await refreshEffectivePolicy(s, userPrincipal(s, userId));
        }
      }
      if (failed) throw handlerError;
      return result;
    } };
  });
}
export function createIntegrationRoutes(s: BackendServices): Route[] {
  createIntegrationServices(s);
  const host = createHostServices(s), exports = createExportServices(s);
  return synchronizeDirectoryRoutes(s, [
    ...createConnectorRoutes(s), ...createChannelRoutes(s), ...createEmailRoutes(s), ...createEventRoutes(s), ...createXRoutes(s), ...createAudioRoutes(s), ...createProviderCatalogRoutes(s),
    ...createIdentityRoutes(s), ...createSCIMRoutes(s), ...createTokenRoutes(s), ...createPolicyRoutes(s, { governanceChanged: host.governanceChanged, cancelContent: exports.cancelContent }), ...createHostRoutes(s, host), ...createSpendRoutes(s), ...createExportRoutes(s),
  ]);
}
