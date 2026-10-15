import { statSync } from 'node:fs';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../core/services';

/** Account deletion binds exact provider resources without disabling membership before core cascades. */
export function previewProviderDeprovision(services: BackendServices, userId: string): { affected: P.ScopeEffect[]; binding: P.JSONObject } {
  services.auth.user(userId);
  const emailAccounts = services.store.list<P.EmailAccount>('emailAccounts', account => account.userId === userId);
  const xConnections = services.store.list<P.XConnection>('xConnections', connection => connection.userId === userId);
  const identityLinks = services.store.list<P.IdentityLink>('identityLinks', link => link.userId === userId);
  const pendingClaim = services.store.get<{ id: string; nonce: string; providerId: string; botId: string; address: string; accountId: string; state: string }>('emailClaimReservations', userId);
  const providerSessions = services.store.list<{ id: string; userId: string; providerId: string }>('oidcProviderSessions', session => session.userId === userId);
  const providerIds = new Set([...identityLinks.map(link => link.providerId), ...providerSessions.map(session => session.providerId)]);
  const affected: P.ScopeEffect[] = [];
  const configurations: unknown[] = [];
  const unavailableProviders: string[] = [];
  function prerequisite(ref: string): void {
    const source = services.config.operator.serverSecrets[ref];
    if (!source) { unavailableProviders.push('server_secret'); return; }
    if (source.kind === 'env') { if (!process.env[source.name]) unavailableProviders.push('provider_credential'); }
    else { try { const info = statSync(source.path); if (!info.isFile() || (info.mode & 0o077) !== 0 || typeof process.getuid === 'function' && info.uid !== process.getuid()) unavailableProviders.push('private_credential_file'); } catch { unavailableProviders.push('private_credential_file'); } }
  }
  if (pendingClaim?.state === 'reserved') {
    const provider = services.config.operator.emailProviders.find(provider => provider.id === pendingClaim.providerId);
    if (!provider) unavailableProviders.push('mailbox_provisioning');
    else prerequisite(provider.provisioningSecretRef);
    configurations.push(provider ?? null);
    affected.push({ resourceType: 'email_claim', id: pendingClaim.accountId, machineId: services.store.get<P.Bot>('bots', pendingClaim.botId)?.machineId ?? null, operation: 'revoke', explanation: 'Cancel or retire the exact uncertain provider provisioning operation before deleting the account; no new address is claimed.' });
  }
  for (const account of emailAccounts) {
    const provider = services.config.operator.emailProviders.find(provider => provider.id === account.provider);
    if (!provider && account.state !== 'retired') unavailableProviders.push('mailbox_provisioning');
    if (provider && account.state !== 'retired') prerequisite(provider.provisioningSecretRef);
    configurations.push(provider ?? null);
    affected.push({ resourceType: 'email_account', id: account.id, machineId: null, operation: account.state === 'retired' ? 'retain' : 'revoke', explanation: account.state === 'retired' ? 'Mailbox is already retired; prior external messages and provider retention remain.' : 'Retire the exact configured provider mailbox before removing product access; prior mail and provider retention remain independently governed.' });
  }
  if (xConnections.length) {
    const provider = services.config.operator.xProvider;
    if (!provider && xConnections.some(connection => connection.state !== 'failed')) unavailableProviders.push('x_oauth');
    if (provider) prerequisite(provider.oauth.clientSecretRef);
    configurations.push(provider);
    for (const connection of xConnections) affected.push({ resourceType: 'x_connection', id: connection.id, machineId: services.store.get<P.Bot>('bots', connection.mainBotId)?.machineId ?? null, operation: 'revoke', explanation: 'Disable mention ingress and revoke the exact configured X OAuth grant. Prior public posts, provider copies and provider-account billing remain.' });
  }
  for (const providerId of providerIds) configurations.push(services.store.get<P.OIDCProvider>('oidcProviders', providerId));
  for (const link of identityLinks) affected.push({ resourceType: 'identity_link', id: link.id, machineId: null, operation: 'revoke', explanation: 'Revoke product-linked identity sessions and attempt the configured IdP end-session protocol where supported; externally retained IdP sessions and directory data may remain.' });
  for (const session of providerSessions) affected.push({ resourceType: 'oidc_session', id: session.id, machineId: null, operation: 'revoke', explanation: 'Remove the server-held OIDC session hint and attempt the configured provider end-session; external IdP retention remains provider-controlled.' });
  return { affected, binding: { providerResources: [...emailAccounts, ...xConnections, ...identityLinks].map(resource => ({ id: resource.id, revision: resource.revision })).sort((a, b) => a.id.localeCompare(b.id)), pendingClaimDigest: pendingClaim?.state === 'reserved' ? services.mutations.digest(pendingClaim) : null, providerSessionIds: providerSessions.map(session => session.id).sort(), providerConfigurationDigest: services.mutations.digest(configurations), unavailableProviders, residual: 'Host files, browser identities, external messages, backup retention and provider billing are not deleted by product account cleanup. Missing provider prerequisites do not prevent reachable local cleanup; unconfirmed external receipts remain visible to the Owner.' } };
}
