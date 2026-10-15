import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { integrationConfiguration } from './config';
import { principal } from './common';

/** Safe catalog only: private URLs, commands, credential references and account tokens stay server-side. */
export async function integrationProviderCatalog(services: BackendServices, who: Principal): Promise<P.IntegrationProvider[]> {
  const channels = await services.invoke<P.ChannelProviderInfo[]>(who, 'GET', '/v1/channels/providers');
  const emails = await services.invoke<P.EmailProviderInfo[]>(who, 'GET', '/v1/email/providers');
  const x = await services.invoke<P.XProviderInfo | null>(who, 'GET', '/v1/x/provider');
  const oidc = await services.invoke<{ id: string; name: string; enabled: boolean; requireSSO: boolean }[]>(who, 'GET', '/v1/auth/oidc/providers');
  const catalog: P.IntegrationProvider[] = [...channels, ...emails, ...(x ? [x] : [])];
  for (const provider of integrationConfiguration(services).connectorProviders) {
    const prerequisites: string[] = [];
    if (provider.oauth) { try { await services.secret(provider.oauth.clientSecretRef); } catch { prerequisites.push('Configure this MCP provider OAuth client secret in backend serverSecrets.'); } }
    catalog.push({ id: provider.id, kind: 'connector', label: provider.id, configured: prerequisites.length === 0, prerequisites, capabilities: ['destination_mcp_discovery', 'per_tool_controls', 'destination_secret_references', ...(provider.oauth ? ['oauth_pkce'] : []), ...(provider.sharedServiceAccount ? ['reviewed_shared_service_account'] : [])] });
  }
  for (const provider of services.config.operator.eventProviders) {
    const prerequisites: string[] = [];
    try { await services.secret(provider.signingSecretRef); } catch { prerequisites.push('Configure this event provider signing secret in backend serverSecrets.'); }
    if (!provider.eventNames.length) prerequisites.push('Register exact supported event names and filter schemas.');
    if (!provider.routineIds.length) prerequisites.push('Bind a fixed authorized routine and initiating principal.');
    catalog.push({ id: provider.id, kind: 'event', label: provider.source, configured: prerequisites.length === 0, prerequisites, capabilities: [...provider.eventNames] });
  }
  for (const provider of oidc) catalog.push({ id: provider.id, kind: 'identity', label: provider.name, configured: provider.enabled, prerequisites: provider.enabled ? [] : ['Enable the registered OIDC provider.'], capabilities: ['oidc_pkce', 'verified_subject', ...(provider.requireSSO ? ['required_sso'] : [])] });
  for (const driver of services.config.operator.hostDrivers) {
    try { services.auth.machine(who, driver.machineId, true); } catch { continue; }
    catalog.push({ id: driver.machineId, kind: 'host', label: driver.provider, configured: true, prerequisites: [], capabilities: [...Object.keys(driver.actions), ...(driver.networkApply ? ['network_policy'] : []), ...(driver.egressApply ? ['encrypted_egress'] : []), ...(driver.setupRun ? ['reviewed_setup'] : [])] });
  }
  if (who.role === 'admin' || who.role === 'owner') for (const destination of services.store.list<P.ExportDestination>('exportDestinations')) {
    const prerequisites: string[] = [];
    if (!destination.enabled) prerequisites.push('Enable this reviewed export destination.');
    if (destination.secretRef) { try { await services.secret(destination.secretRef); } catch { prerequisites.push('Configure the collector backend serverSecret.'); } }
    catalog.push({ id: destination.id, kind: 'export', label: destination.name, configured: prerequisites.length === 0, prerequisites, capabilities: [destination.protocol, ...destination.streams] });
  }
  // Domains intentionally absent from operator configuration are absent, not fabricated providers.
  return catalog.map(({ id, kind, label, configured, prerequisites, capabilities }) => ({ id, kind, label, configured, prerequisites, capabilities }));
}
export function createProviderCatalogRoutes(services: BackendServices): Route[] {
  return [{ method: 'GET', path: '/v1/integration-providers', auth: 'member', handler: context => integrationProviderCatalog(services, principal(context)) }];
}
