import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices } from '../core/services';
import { ApiError } from '../core/errors';

const https = z.string().url().refine(value => new URL(value).protocol === 'https:', 'HTTPS is required');
const origin = https.refine(value => new URL(value).origin === value, 'Expected an origin, not a URL path');
const oauth = z.object({ id: z.string().min(1), clientId: z.string().min(1), clientSecretRef: z.string().min(1), authorizeUrl: https, tokenUrl: https, scopes: z.array(z.string().min(1)), redirectUris: z.array(z.string().min(1)), allowedOrigins: z.array(origin).min(1) }).strict();
const entries = z.array(z.object({ id: z.string().regex(/^[A-Za-z0-9_.-]{1,128}$/), setupScript: z.string().min(1).max(262144), checkScript: z.string().max(262144).nullable(), secretNames: z.array(z.string().regex(/^[A-Za-z][A-Za-z0-9_]{0,127}$/)).max(64), timeoutMs: z.number().int().min(1000).max(1800000) }).strict()).max(100);
export interface ConnectorProvider { id: string; origins: string[]; oauth: P.OAuthProviderConfig | null; sharedServiceAccount: boolean }
export interface ReviewedSetupManifest { name: string; directoryGroupId: string | null; machineIds: string[]; entries: P.SetupManifest['entries'] }
export interface IntegrationConfiguration { connectorProviders: ConnectorProvider[]; approvedPrivateMcpOrigins: string[]; reviewedSetupManifests: ReviewedSetupManifest[] }
const extensions = z.object({
  connectorProviders: z.array(z.object({ id: z.string().min(1), origins: z.array(origin).min(1), oauth: oauth.nullable(), sharedServiceAccount: z.boolean() }).strict()).default([]),
  approvedPrivateMcpOrigins: z.array(origin).default([]),
  reviewedSetupManifests: z.array(z.object({ name: z.string().min(1).max(120), directoryGroupId: z.string().min(1).nullable(), machineIds: z.array(z.string().min(1)).min(1).max(1000), entries }).strict()).default([]),
});

const ident = z.string().min(1).max(256);
const stringList = z.array(ident).max(1000);
const secretSource = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('env'), name: z.string().regex(/^[A-Za-z_][A-Za-z0-9_]*$/) }).strict(),
  z.object({ kind: z.literal('file'), path: z.string().min(1).refine(path => path.startsWith('/'), 'Secret path must be absolute') }).strict(),
]);
const networkRule = z.object({ kind: z.enum(['domain', 'ip_cidr']), value: z.string().min(1).max(256), ports: z.array(z.number().int().min(1).max(65535)).max(256), protocol: z.enum(['tcp', 'udp', 'both']) }).strict();
const command = z.object({ argv: z.array(z.string().min(1).max(32768)).min(1).max(64), cwd: z.string().min(1), timeoutMs: z.number().int().min(1000).max(1800000), probeArgv: z.array(z.string().min(1).max(32768)).min(1).max(64) }).strict();
const providerSchema = z.object({
  version: z.literal(1),
  trustedFrontendOrigins: z.array(origin),
  oauthRedirectUris: z.array(z.string().url()).refine(values => values.every(value => value === 'lemonbot://auth/complete' || new URL(value).protocol === 'https:' || ['localhost', '127.0.0.1', '[::1]'].includes(new URL(value).hostname) && new URL(value).protocol === 'http:'), 'Unsafe OAuth client redirect'),
  serverSecrets: z.record(z.string().regex(/^[A-Za-z0-9_.-]{1,128}$/), secretSource),
  channelProviders: z.array(z.object({ id: ident, adapter: z.enum(['email', 'slack', 'telegram', 'discord', 'whatsapp']), oauth: oauth.nullable(), signingSecretRef: ident.nullable(), apiBaseUrl: https, accountSecretRef: ident.nullable(), capabilities: z.object({ events: stringList, inbound: z.boolean(), outbound: z.boolean() }).strict(), supportsBotAppInstall: z.boolean() }).strict()),
  emailProviders: z.array(z.object({ id: ident, domain: z.string().regex(/^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/), provisioningBaseUrl: https, provisioningSecretRef: ident, immutableAddresses: z.boolean(), reservedNames: stringList, smtp: z.object({ host: ident, port: z.number().int().min(1).max(65535), tls: z.literal(true), secretRef: ident }).strict(), imap: z.object({ host: ident, port: z.number().int().min(1).max(65535), tls: z.literal(true), secretRef: ident }).strict(), signingSecretRef: ident, supportsUnsubscribe: z.boolean() }).strict()),
  eventProviders: z.array(z.object({ id: ident, source: z.enum(['github', 'linear', 'sentry', 'pagerduty', 'slack', 'email']), signingSecretRef: ident, eventNames: stringList, routineIds: stringList, principalUserId: ident, maxAgeMs: z.number().int().min(1000).max(600000), eventDefinitions: z.array(z.object({ name: ident, label: ident, description: z.string().max(4096), filterSchema: z.record(z.string(), z.json()) }).strict()).optional() }).strict()),
  hostDrivers: z.array(z.object({ machineId: ident, provider: z.enum(['systemd', 'launchd', 'container', 'custom']), environmentRoot: z.string().min(1).nullable(), actions: z.partialRecord(z.enum(['update', 'recover', 'restart_worker', 'stop_worker', 'suspend', 'recreate_environment', 'delete_environment']), command), networkApply: command.nullable(), egressApply: command.nullable(), setupRun: command.nullable(), runtimeDestinations: z.array(networkRule) }).strict()),
  xProvider: z.object({ oauth, publicHandle: z.string().regex(/^@?[A-Za-z0-9_]{1,15}$/), signingSecretRef: ident, apiBaseUrl: https, deniedCountries: z.array(z.string().regex(/^[A-Z]{2}$/)), allowedMedia: z.array(z.enum(['photo', 'video', 'gif'])) }).strict().nullable(),
  exportAllowedOrigins: z.array(origin),
  requiredRuntimeDestinations: z.array(networkRule),
  breakGlassOwnerUserId: ident.nullable(),
  ...extensions.shape,
  machineManagementUserIds: stringList.optional(),
  exportPrivateOrigins: z.array(origin).optional(),
  oidcGroupMappings: z.array(z.object({ providerId: ident, externalId: ident, directoryGroupId: ident, name: z.string().min(1).max(120).optional() }).strict()).optional(),
  oidcSubjectMappings: z.array(z.object({ providerId: ident, subject: ident, userId: ident }).strict()).optional(),
  xPublicAccountSecretRef: ident.optional(),
  providerSpendSources: z.array(z.object({ providerAccount: ident, apiBaseUrl: https, secretRef: ident }).strict()).optional(),
  channelApplicationPrincipals: z.array(z.object({ providerId: ident, channelBindingId: ident, externalAppId: ident, userId: ident }).strict()).optional(),
  managedDirectoryOwnerOverride: z.boolean().optional(),
}).strict();
/** One startup schema for operator configuration; private extras are retained by the core loader. */
export function parseOperatorConfiguration(input: unknown): P.OperatorConfiguration {
  const defaults = { trustedFrontendOrigins: [], oauthRedirectUris: ['lemonbot://auth/complete'], serverSecrets: {}, channelProviders: [], emailProviders: [], eventProviders: [], hostDrivers: [], xProvider: null, exportAllowedOrigins: [], requiredRuntimeDestinations: [], breakGlassOwnerUserId: null };
  const parsed = providerSchema.safeParse(input !== null && typeof input === 'object' && !Array.isArray(input) ? { ...defaults, ...input } : input);
  if (!parsed.success) throw new ApiError('invalid_request', 'Operator configuration is invalid; inspect provider schemas in products/lemon_bot/providers.md.');
  const config = parsed.data;
  const references: string[] = [];
  if (config.xPublicAccountSecretRef) references.push(config.xPublicAccountSecretRef);
  for (const source of config.providerSpendSources ?? []) references.push(source.secretRef);
  for (const provider of config.channelProviders) { if (provider.accountSecretRef) references.push(provider.accountSecretRef); if (provider.signingSecretRef) references.push(provider.signingSecretRef); if (provider.oauth) references.push(provider.oauth.clientSecretRef); }
  for (const provider of config.emailProviders) references.push(provider.provisioningSecretRef, provider.signingSecretRef, provider.smtp.secretRef, provider.imap.secretRef);
  for (const provider of config.eventProviders) references.push(provider.signingSecretRef);
  if (config.xProvider) references.push(config.xProvider.signingSecretRef, config.xProvider.oauth.clientSecretRef);
  for (const provider of config.connectorProviders) if (provider.oauth) references.push(provider.oauth.clientSecretRef);
  if (references.some(ref => !Object.hasOwn(config.serverSecrets, ref))) throw new ApiError('invalid_request', 'Provider secret references must name configured serverSecrets entries.');
  if ((config.exportPrivateOrigins ?? []).some(value => !config.exportAllowedOrigins.includes(value))) throw new ApiError('invalid_request', 'Private export origins must also be approved export origins.');
  for (const providers of [config.channelProviders, config.emailProviders, config.eventProviders, config.connectorProviders]) if (new Set(providers.map(provider => provider.id)).size !== providers.length) throw new ApiError('invalid_request', 'Provider IDs must be unique within each provider family.');
  const oauthProviders = [...config.channelProviders.flatMap(provider => provider.oauth ? [provider.oauth] : []), ...config.connectorProviders.flatMap(provider => provider.oauth ? [provider.oauth] : []), ...(config.xProvider ? [config.xProvider.oauth] : [])];
  for (const provider of oauthProviders) if (![provider.authorizeUrl, provider.tokenUrl].every(value => provider.allowedOrigins.includes(new URL(value).origin))) throw new ApiError('invalid_request', 'OAuth endpoints must be pinned to their configured allowed origins.');
  return config;
}
export function integrationConfiguration(services: BackendServices): IntegrationConfiguration {
  const result = extensions.safeParse({ ...services.config.operator, ...services.config.operatorExtras });
  if (!result.success) throw new ApiError('capability_unavailable', 'Operator integration configuration is invalid; review connector providers and setup manifests.');
  return result.data;
}
export function approvedOrigins(services: BackendServices): string[] {
  const config = services.config.operator; const result = new Set(config.exportAllowedOrigins);
  for (const provider of config.channelProviders) { result.add(new URL(provider.apiBaseUrl).origin); for (const value of provider.oauth?.allowedOrigins ?? []) result.add(value); }
  for (const provider of config.emailProviders) result.add(new URL(provider.provisioningBaseUrl).origin);
  if (config.xProvider) { result.add(new URL(config.xProvider.apiBaseUrl).origin); for (const value of config.xProvider.oauth.allowedOrigins) result.add(value); }
  for (const provider of integrationConfiguration(services).connectorProviders) for (const value of [...provider.origins, ...(provider.oauth?.allowedOrigins ?? [])]) result.add(value);
  return [...result];
}

export function providerSpendSource(services: BackendServices, account: string): { providerAccount: string; apiBaseUrl: string; secretRef: string } | null {
  const source = providerSchema.shape.providerSpendSources.parse(services.config.operatorExtras?.providerSpendSources);
  return source?.find(item => item.providerAccount === account) ?? null;
}
