import { z } from 'zod';
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { createHash } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from '../core/services';
import { ApiError, fail } from '../core/errors';
import { pinnedUrl, privateMetadata, savePrivateMetadata, principal, userPrincipal, sha256, isPublicAddress, assertActiveAccount } from './common';
import { integrationConfiguration, type ConnectorProvider } from './config';
import { startOAuth, takeOAuthState, exchangeOAuth, markOAuthInstalled, oauthTokenClientDigest, type OAuthCompletion, type OAuthExchangeOperation } from './oauth';
import { effectiveBotGrants } from '../core/experiences';
import { cancelConnectorConsents, cancelGate } from '../core/gates';
import { baseBotMcpTemplate, syncBotConnectorRevocation } from '../core/bots';
import { revokeOAuthCompletion, reconcileOAuthRevocation, type OAuthRevocationReceipt } from './oauth-revocation';
import { effectiveInvocationAudience, type InvocationMcpServer } from '../runtime/runs';

const nonce = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/);
const revision = z.number().int().positive().max(Number.MAX_SAFE_INTEGER);
const label = z.string().trim().min(1).max(120);
const secretName = z.string().min(1).max(256).refine(value => value === value.trim() && Buffer.byteLength(value, 'utf8') <= 256 && !/[\u0000-\u001f\u007f{}]/.test(value));
const binding = z.object({ header: z.string().regex(/^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,64}$/), secretName }).strict();
const bindings = z.array(binding).max(32).refine(values => new Set(values.map(value => value.header.toLowerCase())).size === values.length);
const toolName = z.string().min(1).max(128).refine(value => Buffer.byteLength(value, 'utf8') <= 128 && !/[\u0000-\u001f\u007f]/.test(value));
const tools = z.array(z.object({ name: toolName, enabled: z.boolean() }).strict()).max(256).refine(values => new Set(values.map(value => value.name)).size === values.length);
const createSchema = z.object({ clientNonce: nonce, name: label, url: z.string().url().max(2048), accountLabel: label, authKind: z.enum(['none', 'secret_headers', 'oauth']), secretBindings: bindings.optional(), shared: z.boolean() }).strict();
const setupSchema = createSchema.extend({ machineId: z.string().min(1).max(128), secretBindings: bindings, requestedLevel: z.enum(['off', 'read_only', 'read_interact']) }).strict();
const updateSchema = z.object({ clientNonce: nonce, revision, name: label.optional(), accountLabel: label.optional(), tools: tools.optional(), secretBindings: bindings.optional() }).strict();
const mutationSchema = z.object({ clientNonce: nonce }).strict();
const revisionSchema = mutationSchema.extend({ revision }).strict();
const previewSchema = mutationSchema.extend({ action: z.literal('disconnect') }).strict();
const confirmSchema = revisionSchema.extend({ confirmationToken: z.string().min(1).max(1024), confirmName: z.string().min(1).max(120) }).strict();
const consentSchema = revisionSchema.extend({ decision: z.enum(['allow_once', 'allow_bot', 'decline']), expiresAtMs: z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).optional() }).strict();
const discoverySchema = z.object({ connected: z.literal(true), server: z.object({ name: z.string(), status: z.literal('connected') }).strict(), tools: z.array(z.object({ name: toolName, executionName: z.string().min(1).max(64), description: z.string().max(4096), inputSchema: z.record(z.string(), z.unknown()), readOnly: z.boolean() }).strict()).max(256), count: z.number().int().nonnegative(), truncated: z.boolean() }).strict();

type SecretBinding = z.infer<typeof binding>;
interface ConnectorPrivate { machineId: string; bindings: SecretBinding[]; readOnlyTools: string[]; executionNames: Record<string, string>; providerId: string | null; oauthSecretNames: string[]; oauthExpiresAtMs: number | null; discoveredAtMs: number | null; configuredLevel: 'off' | 'read_interact'; provisionState: 'pending' | 'acknowledged' | 'outcome_unknown'; desiredState: P.Connector['state'] | null; desiredFingerprint: string | null; provisionActorUserId: string | null; }
interface ConsentPrivate { userId: string; conversationId: string; operationId: string | null; consumedBy: string | null; }
interface ConnectorTemplatePolicy { machineId: string; readOnlyTools: string[]; configuredLevel: 'off' | 'read_interact' }
export interface ConnectorToolAuthorization { connectorId: string; botId: string; conversationId: string; toolName: string; operationId: string }

function parse<T>(schema: z.ZodType<T>, input: unknown): T {
  const result = schema.safeParse(input);
  if (!result.success) fail('invalid_request', 'Connector request has invalid or unsupported fields.');
  return result.data;
}

function parseResponse<T>(schema: z.ZodType<T>, input: unknown, mutation = false): T {
  const result = schema.safeParse(input);
  if (!result.success) fail(mutation ? 'outcome_unknown' : 'upstream_unavailable', 'Destination returned an invalid connector response.', !mutation);
  return result.data;
}

/** Matches the platform digest for a public ceiling or exact invocation MCP configuration. */
export function connectorConfigurationFingerprint(servers: InvocationMcpServer[]): string {
  return createHash('sha256').update(JSON.stringify(servers.map(server => [server.name, server.url, Object.entries(server.headers).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0), server.enabledTools ?? null, server.allowedOrigins ?? null, server.approvedPrivateOrigins ?? null]))).digest('hex');
}

/** Public profile ceiling only; credential authority is installed separately for a fixed invocation. */
export function connectorTemplates(services: BackendServices, bot: P.Bot): Promise<InvocationMcpServer[]> {
  return createConnectorServices(services).connectorTemplates(bot.id);
}

export function createConnectorServices(services: BackendServices) {
  const privateKey = (id: string) => `connector:${id}`;
  const details = (id: string): ConnectorPrivate => {
    const value = privateMetadata<ConnectorPrivate>(services, privateKey(id));
    if (!value) fail('conflict', 'Connector destination configuration is unavailable; configure it again.');
    return value;
  };
  const saveDetails = (id: string, value: ConnectorPrivate) => {
    savePrivateMetadata(services, privateKey(id), value);
    services.store.setMetadata(`connectorTemplatePolicy:${id}`, { machineId: value.machineId, readOnlyTools: [...value.readOnlyTools], configuredLevel: value.configuredLevel } satisfies ConnectorTemplatePolicy);
  };
  const provider = (connector: P.Connector): ConnectorProvider | null => {
    const matches = integrationConfiguration(services).connectorProviders.filter(value => value.origins.includes(new URL(connector.url).origin));
    if (matches.length > 1) fail('policy_denied', 'Connector origin has ambiguous operator provider configuration.');
    return matches[0] ?? null;
  };
  function assertConnectorPolicy(connector: P.Connector): URL {
    try {
      assertActiveAccount(services, connector.ownerUserId);
      if (!services.auth.member(connector.ownerUserId).enabled) fail('policy_denied', 'Connector account owner is disabled.');
      if (connector.shared && !provider(connector)?.sharedServiceAccount) fail('policy_denied', 'Shared service account provider is no longer approved.');
      return assertOrigin(connector.url);
    } catch (error) {
      const current = services.store.get<P.Connector>('connectors', connector.id);
      if (error instanceof ApiError && error.code === 'policy_denied' && current && current.state !== 'blocked') {
        revokeConsents(current.id);
        publish(services.update(current, { state: 'blocked', lastError: 'Connector account or destination is blocked by current product/operator policy.' }));
      }
      throw error;
    }
  }
  function access(actor: Principal, id: string, manage = false): P.Connector {
    const connector = services.store.require<P.Connector>('connectors', id);
    if (connector.ownerUserId === actor.userId) {
      if (!services.auth.member(actor.userId).enabled) fail('forbidden', 'Connector account ownership requires enabled membership.');
      return connector;
    }
    if (!connector.shared) fail('not_found', 'Connector account was not found.');
    services.auth.bot(actor, connector.botId, manage);
    return connector;
  }
  function canManageBot(actor: Principal, botId: string): boolean {
    try { services.auth.bot(actor, botId, true); return true; }
    catch (error) { if (error instanceof ApiError && ['forbidden', 'not_found'].includes(error.code)) return false; throw error; }
  }
  function assertReady(connector: P.Connector, externalEffect = false): P.Machine & { nodeId: string } {
    const lifecycle = services.store.metadata<{ status: string }>(`botLifecycle:${connector.botId}`);
    if (lifecycle) fail(externalEffect || lifecycle.status === 'outcome_unknown' ? 'outcome_unknown' : 'conflict', 'Bot lifecycle changes fence new connector authorization.', !externalEffect && lifecycle.status !== 'outcome_unknown', { resourceIds: [connector.id, connector.botId] });
    return destination(connector);
  }
  function destination(connector: P.Connector): P.Machine & { nodeId: string } {
    const bot = services.store.require<P.Bot>('bots', connector.botId);
    const config = details(connector.id);
    if (bot.machineId !== config.machineId) fail('conflict', 'Connector belongs to the previous destination; set up credentials on the assigned machine.');
    const machine = services.store.require<P.Machine>('machines', bot.machineId);
    if (machine.status !== 'online' || !machine.nodeId) fail('machine_offline', 'Connector destination machine is offline.');
    return { ...machine, nodeId: machine.nodeId };
  }
  function assertOrigin(url: string): URL {
    let parsed: URL;
    try { parsed = new URL(url); } catch { fail('invalid_request', 'Connector URL is invalid.'); }
    if ([...parsed.searchParams.keys()].some(key => /(?:token|secret|password|credential|api[_-]?key|authorization|cookie)/i.test(key))) fail('invalid_request', 'Connector URL credentials must use destination secret bindings.');
    if (parsed.hostname.endsWith('.')) fail('invalid_request', 'Connector hostname must use its canonical origin without a terminal dot.');
    pinnedUrl(url, [parsed.origin]);
    const policies = services.store.metadata<P.Policies>('policies');
    if (policies?.allowedMcpOrigins && !policies.allowedMcpOrigins.includes(parsed.origin)) fail('policy_denied', 'Connector origin is blocked by workspace policy.');
    return parsed;
  }
  function headers(config: ConnectorPrivate): Record<string, string> {
    return Object.fromEntries(config.bindings.map(value => [value.header, `${value.header.toLowerCase() === 'authorization' ? 'Bearer ' : ''}\${LEMON_SECRET:${value.secretName}}`]));
  }
  async function validateBindings(actor: Principal, machine: P.Machine, values: SecretBinding[]): Promise<void> {
    services.auth.machine(actor, machine.id, true);
    const reserved = new Set(services.store.list<P.Bot>('bots').flatMap(bot => {
      const metadata = services.store.metadata<{ secretName: string }>(`botMcp:${bot.id}`);
      return metadata ? [metadata.secretName] : [];
    }));
    if (values.some(value => value.secretName.startsWith('lemon_bot/') || reserved.has(value.secretName) || value.header.toLowerCase() === 'x-lemon-bot-invocation')) fail('invalid_request', 'Core product and invocation credentials cannot be bound to user connectors.');
    if (machine.status !== 'online' || !machine.nodeId) fail('machine_offline', 'Connector destination machine is offline.');
    for (const value of values) if (/^(host|content-length|connection|transfer-encoding|upgrade|proxy-authorization|mcp-session-id)$/i.test(value.header)) fail('invalid_request', 'Connector header cannot override transport authority.');
    if (!values.length) return;
    const response = parseResponse(z.object({ names: z.array(z.string().min(1).max(256)), limit: z.number().int(), truncated: z.boolean() }).strict(), await services.lemon.call('node.secrets.list', { nodeId: machine.nodeId }));
    if (values.some(value => !response.names.includes(value.secretName))) fail(response.truncated ? 'capability_unavailable' : 'invalid_request', response.truncated ? 'The destination secret listing was truncated; the selected name could not be verified.' : 'A bound secret name does not exist on the destination machine.');
  }
  function grantFor(connector: P.Connector): P.BotGrant | null {
    return services.store.list<P.BotGrant>('botGrants', grant => grant.botId === connector.botId && grant.capabilityId === `connector:${connector.id}` && grant.machineId === details(connector.id).machineId)[0] ?? null;
  }
  function enabled(connector: P.Connector, effectiveLevel?: P.AccessLevel): string[] {
    const grant = grantFor(connector);
    const level = effectiveLevel ?? grant?.requestedLevel ?? 'off';
    const config = details(connector.id);
    if (!grant || level === 'off' || config.configuredLevel === 'off') return [];
    return connector.tools.filter(tool => tool.enabled && (level === 'read_interact' || config.readOnlyTools.includes(tool.name))).map(tool => tool.name);
  }
  function serverConfiguration(connector: P.Connector, effectiveLevel?: P.AccessLevel): InvocationMcpServer {
    const origin = assertOrigin(connector.url).origin;
    return { name: `connector-${connector.id}`, url: connector.url, headers: headers(details(connector.id)), enabledTools: enabled(connector, effectiveLevel), allowedOrigins: [origin], approvedPrivateOrigins: integrationConfiguration(services).approvedPrivateMcpOrigins.includes(origin) ? [origin] : [] };
  }
  async function connectorTemplates(botId: string): Promise<InvocationMcpServer[]> {
    const bot = services.store.require<P.Bot>('bots', botId);
    const result: InvocationMcpServer[] = [];
    for (const connector of services.store.list<P.Connector>('connectors', value => value.botId === botId && value.state !== 'disconnected' && value.state !== 'blocked')) {
      const policy = services.store.metadata<ConnectorTemplatePolicy>(`connectorTemplatePolicy:${connector.id}`);
      if (!policy) fail('capability_unavailable', 'Connector public template policy has not been provisioned.', true, { resourceIds: [connector.id] });
      if (policy.machineId !== bot.machineId) continue;
      const origin = assertOrigin(connector.url).origin;
      if (connector.shared && !provider(connector)?.sharedServiceAccount) fail('policy_denied', 'Shared service account provider is no longer approved.');
      const grant = services.store.list<P.BotGrant>('botGrants', value => value.botId === botId && value.capabilityId === `connector:${connector.id}` && value.machineId === policy.machineId)[0];
      const level = grant?.requestedLevel ?? 'off';
      const enabledTools = policy.configuredLevel === 'off' || level === 'off' ? [] : connector.tools.filter(tool => tool.enabled && (level === 'read_interact' || policy.readOnlyTools.includes(tool.name))).map(tool => tool.name);
      result.push({ name: `connector-${connector.id}`, url: connector.url, headers: {}, enabledTools, allowedOrigins: [origin], approvedPrivateOrigins: integrationConfiguration(services).approvedPrivateMcpOrigins.includes(origin) ? [origin] : [] });
    }
    return result;
  }
  async function connectorGrants(actor: Principal, bot: P.Bot, provisioning = false): Promise<P.BotGrant[]> {
    const capabilities = services.store.get<P.MachineCapabilities>('machineCapabilities', bot.machineId) ?? undefined;
    if (provisioning && !services.integrations.sharedProfilePolicy) fail('capability_unavailable', 'Workspace-required profile policy composition must be configured.');
    const floor = provisioning ? await services.integrations.sharedProfilePolicy!(bot.id) : undefined;
    return (await effectiveBotGrants(services, actor, bot, capabilities, provisioning, floor)).filter(grant => grant.capabilityId.startsWith('connector:'));
  }
  async function discover(connector: P.Connector): Promise<P.Connector> {
    const origin = assertConnectorPolicy(connector).origin;
    const hostname = new URL(connector.url).hostname.replace(/^\[|\]$/g, '');
    const addresses = isIP(hostname) ? [{ address: hostname }] : await lookup(hostname, { all: true }).catch(() => []);
    if (!addresses.length) fail('upstream_unavailable', 'Connector destination cannot be resolved.');
    if (addresses.some(value => !isPublicAddress(value.address)) && !integrationConfiguration(services).approvedPrivateMcpOrigins.includes(origin)) fail('policy_denied', 'Private MCP destinations require an exact operator-approved origin.');
    const machine = destination(connector);
    const config = details(connector.id);
    const result = parseResponse(discoverySchema, await services.lemon.call('node.mcp.discover', {
      nodeId: machine.nodeId,
      server: serverConfiguration(connector, 'off'),
    }));
    if (result.truncated || result.count !== result.tools.length || new Set(result.tools.map(tool => tool.executionName)).size !== result.tools.length) fail('capability_unavailable', 'Connector discovery must provide a complete bounded tool inventory with unique execution aliases.');
    if (new Set(result.tools.map(tool => tool.name)).size !== result.tools.length) fail('upstream_unavailable', 'Connector discovery returned duplicate tools.');
    const previous = new Map(connector.tools.map(tool => [tool.name, tool.enabled]));
    saveDetails(connector.id, { ...config, readOnlyTools: result.tools.filter(tool => tool.readOnly).map(tool => tool.name), executionNames: Object.fromEntries(result.tools.map(tool => [tool.name, tool.executionName])), discoveredAtMs: services.now(), configuredLevel: 'read_interact' });
    return services.update(connector, { state: 'connected', lastError: null, tools: result.tools.map(tool => ({ name: tool.name, enabled: previous.get(tool.name) ?? false })) });
  }
  function publish(connector: P.Connector): P.Connector {
    services.store.put('connectors', connector);
    services.events.emit('connector.upserted', connector, connector.shared ? { botId: connector.botId } : { userIds: [connector.ownerUserId] });
    return connector;
  }
  function revokeConsents(connectorId: string): void {
    cancelConnectorConsents(services, connectorId);
  }
  function updateConsentEntry(consent: P.ConnectorConsent): void {
    const entry = services.store.get<P.TranscriptEntry>('entries', consent.entryId);
    if (entry?.kind === 'card' && entry.card.type === 'connector_grant') {
      const updated = services.update(entry, { card: { type: 'connector_grant', consent } });
      services.store.put('entries', updated);
      services.events.emit('entry.upserted', updated, { conversationId: updated.conversationId, userIds: [consent.accountOwnerUserId] });
    }
  }
  async function synchronize(actor: Principal, botId: string): Promise<void> {
    await services.syncBotProfile(actor, botId);
  }
  async function prepareProvision(actor: Principal, connector: P.Connector): Promise<string> {
    if (connector.state !== 'disconnected' && connector.state !== 'blocked' && connector.state !== 'failed') assertActiveAccount(services, connector.ownerUserId);
    publish(connector);
    const bot = services.store.require<P.Bot>('bots', connector.botId);
    const expected = connectorConfigurationFingerprint([baseBotMcpTemplate(services), ...await connectorTemplates(bot.id)]);
    saveDetails(connector.id, { ...details(connector.id), provisionState: 'pending', desiredState: connector.state, desiredFingerprint: expected, provisionActorUserId: actor.userId });
    return expected;
  }
  async function provision(actor: Principal, connector: P.Connector): Promise<P.Connector> {
    const expected = await prepareProvision(actor, connector);
    try {
      await synchronize(actor, connector.botId);
      const profile = parseResponse(z.object({ profile: z.object({ mcpConfigFingerprint: z.string().regex(/^[a-f0-9]{64}$/) }).passthrough() }).passthrough(), await services.lemon.call('profiles.get', { id: services.store.require<P.Bot>('bots', connector.botId).profileId }));
      if (profile.profile.mcpConfigFingerprint !== expected) fail('outcome_unknown', 'Profile connector configuration fingerprint was not acknowledged.', false, { resourceIds: [connector.id] });
      if (connector.state === 'connected') assertReady(connector, true);
      if (connector.state === 'connected') assertActiveAccount(services, connector.ownerUserId, true);
      saveDetails(connector.id, { ...details(connector.id), provisionState: 'acknowledged' });
      releaseRevocationFence(connector.botId, connector.id);
      return connector;
    } catch (error) {
      const uncertain = !(error instanceof ApiError) || !error.retrySafe;
      saveDetails(connector.id, { ...details(connector.id), provisionState: uncertain ? 'outcome_unknown' : 'pending' });
      publish(services.update(connector, { state: 'failed', lastError: 'Profile synchronization was not acknowledged; inspect the destination before retrying.' }));
      if (uncertain) fail('outcome_unknown', 'Connector profile synchronization outcome is unknown.', false, { resourceIds: [connector.id] });
      throw error;
    }
  }
  async function create(actor: Principal, botId: string, input: P.ConnectorCreate, level: P.AccessLevel = 'read_interact', resourceIds?: string[]): Promise<P.Connector> {
    const bot = services.auth.bot(actor, botId, true);
    if (services.store.metadata(`botLifecycle:${botId}`)) fail('conflict', 'Finish the Bot lifecycle operation before connector setup.');
    const machine = services.auth.machine(actor, bot.machineId, true);
    assertOrigin(input.url);
    const values = input.secretBindings ?? [];
    if (input.authKind === 'none' && values.length || input.authKind === 'oauth' && values.length) fail('invalid_request', 'Secret bindings do not match the selected connector authentication kind.');
    await validateBindings(actor, machine, values);
    const connector: P.Connector = services.resource('connector', { botId, ownerUserId: actor.userId, name: input.name, url: assertOrigin(input.url).href, accountLabel: input.accountLabel, authKind: input.authKind, shared: input.shared, state: input.authKind === 'oauth' || input.authKind === 'secret_headers' && !values.length ? 'needs_auth' : 'added', tools: [], secretHeaderNames: values.map(value => value.header), lastError: null });
    const configured = provider(connector);
    if (input.shared && !configured?.sharedServiceAccount) fail('policy_denied', 'Shared connector requires an operator-declared service account provider.');
    if (configured?.id.toLowerCase() === 'gmail' && services.store.list<P.Connector>('connectors', value => value.botId === botId && value.ownerUserId === actor.userId && provider(value)?.id === configured.id).length) fail('conflict', 'Only one Gmail mailbox may be configured for this account and Bot.');
    services.store.transaction(() => {
      saveDetails(connector.id, { machineId: bot.machineId, bindings: values, readOnlyTools: [], executionNames: {}, providerId: configured?.id ?? null, oauthSecretNames: [], oauthExpiresAtMs: null, discoveredAtMs: null, configuredLevel: 'off', provisionState: 'pending', desiredState: null, desiredFingerprint: null, provisionActorUserId: actor.userId });
      services.store.put('connectors', connector);
      const grant: P.BotGrant = services.resource('grant', { botId, machineId: bot.machineId, capabilityId: `connector:${connector.id}`, requestedLevel: level, effectiveLevel: 'off', reasons: ['Awaiting actual destination connector discovery.'] });
      services.store.put('botGrants', grant);
      services.events.emit('grant.upserted', grant, { botId });
    });
    resourceIds?.push(connector.id);
    try {
      const connected = connector.state === 'needs_auth' ? connector : await discover(connector);
      publish(connected);
      await connectorGrants(actor, bot);
      return await provision(actor, connected);
    } catch (error) {
      if (details(connector.id).provisionState !== 'outcome_unknown') publish(services.update(services.store.require<P.Connector>('connectors', connector.id), { state: error instanceof ApiError && error.code === 'policy_denied' ? 'blocked' : 'failed', lastError: error instanceof ApiError && error.code === 'policy_denied' ? 'Connector destination is blocked by product/operator policy.' : 'Destination connector discovery or configuration was not acknowledged.' }));
      throw error;
    }
  }
  async function connectorProfileConfiguration(actor: Principal, botId: string, conversationId?: string, operationId?: string): Promise<InvocationMcpServer[]> {
    const bot = services.auth.bot(actor, botId);
    if (conversationId === undefined) return connectorTemplates(botId);
    const conversation = services.auth.conversation(actor, conversationId);
    if (!operationId || operationId.length > 128) fail('invalid_request', 'Invocation connector configuration requires its reserved operation identity.');
    if (services.store.metadata<{ dispatched: boolean }>(`runtimeRun:${operationId}`)?.dispatched) fail('outcome_unknown', 'An executing invocation cannot re-provision connector authority or replay a consumed grant.', false, { resourceIds: [operationId] });
    if (!conversation.botIds.includes(botId) || actor.kind === 'bot' && actor.botId !== botId) fail('forbidden', 'Connector invocation does not match this Bot and conversation.');
    reconcilePlacement(bot);
    const grants = await connectorGrants(actor, bot);
    const result: InvocationMcpServer[] = [];
    const configuredIds: string[] = [];
    for (const connector of services.store.list<P.Connector>('connectors', value => value.botId === botId && value.state === 'connected')) {
      if (details(connector.id).provisionState !== 'acknowledged') continue;
      if (!connector.shared && (connector.ownerUserId !== actor.userId || conversation.kind === 'group' || conversation.kind === 'channel')) continue;
      assertConnectorPolicy(connector);
      const expiresAtMs = details(connector.id).oauthExpiresAtMs;
      if (expiresAtMs !== null && expiresAtMs <= services.now()) {
        revokeConsents(connector.id);
        publish(services.update(connector, { state: 'needs_auth', lastError: 'Destination OAuth credential expired; authorize again.' }));
        fail('expired', 'Connector OAuth credential has expired.');
      }
      destination(connector);
      const level = grants.find(grant => grant.capabilityId === `connector:${connector.id}`)?.effectiveLevel ?? 'off';
      if (!enabled(connector, level).length) continue;
      if (!connector.shared && bot.visibility === 'team' && !authorizedConsent(actor, connector, conversation.id, operationId, true)) continue;
      result.push(serverConfiguration(connector, level));
      configuredIds.push(connector.id);
    }
    services.store.setMetadata(`invocationConnectors:${operationId}`, configuredIds);
    return result;
  }
  function expireConsent(consent: P.ConnectorConsent): P.ConnectorConsent {
    if (consent.gate.state === 'approved' && consent.expiresAtMs !== null && consent.expiresAtMs <= services.now()) {
      const next = services.update(consent, { gate: { ...consent.gate, state: 'expired', revision: consent.revision + 1, resolvedAtMs: services.now() } });
      services.store.put('consents', next);
      services.events.emit('consent.upserted', next, { userIds: [next.accountOwnerUserId] });
      updateConsentEntry(next);
      return next;
    }
    return consent;
  }
  function authorizedConsent(actor: Principal, connector: P.Connector, conversationId: string, operationId: string, consume: boolean): boolean {
    return services.store.transaction(() => {
      for (const stored of services.store.list<P.ConnectorConsent>('consents', value => value.connectorId === connector.id && value.botId === connector.botId && value.accountOwnerUserId === connector.ownerUserId)) {
        const consent = expireConsent(stored);
        const data = privateMetadata<ConsentPrivate>(services, `consent:${consent.id}`);
        if (!data || data.userId !== actor.userId || consent.gate.targetUserId !== connector.ownerUserId || consent.gate.state !== 'approved') continue;
        if (consent.scope === 'once' && (data.conversationId !== conversationId || data.operationId !== operationId || data.consumedBy !== null)) continue;
        if (consume && consent.scope === 'once') savePrivateMetadata(services, `consent:${consent.id}`, { ...data, consumedBy: operationId });
        return true;
      }
      return false;
    });
  }
  async function authorizeConnectorTool(actor: Principal, input: ConnectorToolAuthorization): Promise<void> {
    if (!input.operationId || input.operationId.length > 128) fail('invalid_request', 'Connector operation identity is required.');
    const bot = services.auth.bot(actor, input.botId);
    const conversation = services.auth.conversation(actor, input.conversationId);
    if (!conversation.botIds.includes(bot.id) || actor.kind === 'bot' && actor.botId !== bot.id) fail('forbidden', 'Connector invocation does not match the authorized Bot and conversation.');
    const connector = services.store.require<P.Connector>('connectors', input.connectorId);
    if (connector.botId !== bot.id || connector.state !== 'connected' || details(connector.id).provisionState !== 'acknowledged') fail('policy_denied', 'Connector is not provisioned and connected for this Bot.');
    const productRunId = services.store.metadata<string>(`nativeRunProduct:${input.operationId}`);
    const admitted = services.store.metadata<string[]>(`invocationConnectors:${input.operationId}`);
    const epochs = productRunId ? services.store.metadata<{ connectorId: string; epoch: number }[]>(`runConnectorEpochs:${productRunId}`) : null;
    if (!productRunId || !admitted?.includes(connector.id) || epochs?.find(value => value.connectorId === connector.id)?.epoch !== (services.store.metadata<number>(`connectorEpoch:${connector.id}`) ?? 0)) fail('policy_denied', 'Connector authority was not admitted for this fixed invocation, or has been revoked. Start a newly authorized invocation.');
    const run = services.store.require<P.Run>('runs', productRunId);
    if (run.botId !== bot.id || ['succeeded', 'failed', 'cancelled'].includes(run.status) || effectiveInvocationAudience(services, actor, services.auth.conversation(actor, run.conversationId), run.id).id !== conversation.id) fail('forbidden', 'Connector access must match the initiating invocation and its actual response audience.');
    assertConnectorPolicy(connector);
    const expiresAtMs = details(connector.id).oauthExpiresAtMs;
    if (expiresAtMs !== null && expiresAtMs <= services.now()) fail('expired', 'Connector OAuth credential has expired.');
    const grants = await connectorGrants(actor, bot);
    if (services.store.require<P.Connector>('connectors', connector.id).revision !== connector.revision || epochs?.find(value => value.connectorId === connector.id)?.epoch !== (services.store.metadata<number>(`connectorEpoch:${connector.id}`) ?? 0)) fail('policy_denied', 'Connector authority changed during invocation authorization.');
    destination(connector);
    const level = grants.find(grant => grant.capabilityId === `connector:${connector.id}`)?.effectiveLevel ?? 'off';
    if (!enabled(connector, level).includes(input.toolName)) fail('policy_denied', 'Connector tool is disabled by its explicit tool or capability grant.');
    if (connector.shared) {
      if (!provider(connector)?.sharedServiceAccount) fail('policy_denied', 'Shared service account provider is not approved.');
    } else {
      if (conversation.kind === 'group' || conversation.kind === 'channel') fail('policy_denied', 'Personal connector accounts require a private Bot conversation; shared contexts require an intentional service account.');
      if (connector.ownerUserId !== actor.userId) fail('policy_denied', 'Personal connector account cannot be lent to another member.');
      if (bot.visibility === 'team' && !authorizedConsent(actor, connector, conversation.id, input.operationId, true)) fail('policy_denied', 'Explicit account-owner connector consent is required.');
    }
  }
  async function connectorInvocationConfiguration(actor: Principal, botId: string, conversationId: string, operationId: string): Promise<InvocationMcpServer[]> {
    return connectorProfileConfiguration(actor, botId, conversationId, operationId);
  }
  async function requestConnectorConsent(actor: Principal, input: Omit<ConnectorToolAuthorization, 'toolName'>): Promise<P.ConnectorConsent> {
    const connector = access(actor, input.connectorId);
    if (connector.botId !== input.botId || connector.shared) fail('invalid_request', 'Personal connector consent must target its exact Bot and account.');
    const bot = services.auth.bot(actor, input.botId);
    const conversation = services.auth.conversation(actor, input.conversationId);
    if (!conversation.botIds.includes(bot.id)) fail('forbidden', 'Connector consent conversation does not contain this Bot.');
    if (conversation.kind === 'group' || conversation.kind === 'channel') fail('policy_denied', 'Open your own private Bot conversation to authorize a personal connector account.');
    const consent = await services.gates.create<P.ConnectorConsent>(actor, 'consent', { connectorId: connector.id, accountOwnerUserId: connector.ownerUserId, botId: bot.id, conversationId: conversation.id, targetUserId: connector.ownerUserId, clientNonce: input.operationId });
    const previous = privateMetadata<ConsentPrivate>(services, `consent:${consent.id}`);
    if (previous && (previous.userId !== actor.userId || previous.conversationId !== conversation.id || previous.operationId !== input.operationId)) fail('nonce_conflict', 'Consent requester binding does not match the original operation.');
    if (!previous) savePrivateMetadata(services, `consent:${consent.id}`, { userId: actor.userId, conversationId: conversation.id, operationId: input.operationId, consumedBy: null } satisfies ConsentPrivate);
    return consent;
  }
  async function resolveConsent(actor: Principal, id: string, body: P.ConsentResolve): Promise<P.ConnectorConsent> {
    const consent = services.store.require<P.ConnectorConsent>('consents', id);
    const connector = access(actor, consent.connectorId);
    if (consent.accountOwnerUserId !== actor.userId || consent.gate.targetUserId !== actor.userId || connector.botId !== consent.botId || connector.ownerUserId !== consent.accountOwnerUserId) fail('not_found', 'Account-owner consent was not found.');
    if (!privateMetadata<ConsentPrivate>(services, `consent:${id}`)) fail('conflict', 'Consent has no verified requester binding.');
    const result = await services.gates.resolve<P.ConnectorConsent>(actor, 'consents', id, body);
    services.audit(actor, 'connector.consent.resolve', id, 'succeeded', { decision: body.decision });
    return result;
  }
  async function revokeConsent(actor: Principal, id: string, body: P.Update): Promise<P.Deleted> {
    const consent = services.store.require<P.ConnectorConsent>('consents', id);
    if (consent.accountOwnerUserId !== actor.userId || consent.gate.targetUserId !== actor.userId) fail('not_found', 'Account-owner consent was not found.');
    services.mutations.checkRevision(consent, body.revision);
    cancelGate(services, 'consents', id);
    await fenceConnectorInvocations(actor, consent.connectorId);
    releaseRevocationFence(consent.botId, consent.connectorId);
    services.audit(actor, 'connector.consent.revoke', id, 'succeeded');
    return { id, deleted: true };
  }
  function releaseRevocationFence(botId: string, connectorId: string): void {
    const fence = services.store.metadata<{ connectorId: string; status: string }>(`connectorRevocation:${botId}`);
    if (fence?.connectorId === connectorId && fence.status !== 'outcome_unknown') services.store.setMetadata(`connectorRevocation:${botId}`, null);
  }
  async function fenceConnectorInvocations(actor: Principal, connectorId: string): Promise<void> {
    const connector = services.store.require<P.Connector>('connectors', connectorId);
    const epochKey = `connectorEpoch:${connectorId}`;
    services.store.setMetadata(epochKey, (services.store.metadata<number>(epochKey) ?? 0) + 1);
    const result = await services.runtime.revokeConnectorInvocations(actor, connector.botId, connectorId);
    if (result.status !== 'cancelled') {
      saveDetails(connectorId, { ...details(connectorId), provisionState: 'outcome_unknown' });
      fail('outcome_unknown', 'Active connector invocations were not confirmed revoked.', false, { resourceIds: [connectorId, ...result.runIds] });
    }
  }
  async function connectorProvisioning(actor: Principal, botId: string): Promise<void> {
    services.auth.bot(actor, botId, true);
    const bot = services.store.require<P.Bot>('bots', botId);
    reconcilePlacement(bot);
    for (const connector of services.store.list<P.Connector>('connectors', value => value.botId === botId && (value.shared || value.ownerUserId === actor.userId))) {
      if (details(connector.id).machineId !== bot.machineId) continue;
      if (!enabled(connector).length) {
        revokeConsents(connector.id);
        await fenceConnectorInvocations(actor, connector.id);
      }
      if (connector.state === 'connected') {
        const next = await discover(connector);
        await provision(actor, next);
      }
    }
    for (const connector of services.store.list<P.Connector>('connectors', value => value.botId === botId)) releaseRevocationFence(botId, connector.id);
  }
  async function disconnectConnector(actor: Principal, connector: P.Connector, deletingBot = false): Promise<P.Deleted> {
    const config = details(connector.id);
    const machine = services.store.require<P.Machine>('machines', config.machineId);
    if (machine.status !== 'online' || !machine.nodeId) fail('machine_offline', 'The credential destination must be online to acknowledge connector removal.');
    revokeConsents(connector.id);
    const disconnected = services.update(connector, { state: 'disconnected', tools: connector.tools.map(tool => ({ ...tool, enabled: false })) });
    saveDetails(connector.id, { ...config, configuredLevel: 'off', discoveredAtMs: null });
    const scopedOwnerRevocation = !deletingBot && connector.ownerUserId === actor.userId && !canManageBot(actor, connector.botId);
    if (deletingBot || scopedOwnerRevocation) {
      publish(disconnected);
      saveDetails(connector.id, { ...details(connector.id), desiredState: 'disconnected', desiredFingerprint: null, provisionState: 'pending', provisionActorUserId: actor.userId });
    } else await prepareProvision(actor, disconnected);
    await fenceConnectorInvocations(actor, connector.id);
    for (const pending of services.store.list<P.ConnectorAuth>('connectorAuths', value => value.connectorId === connector.id && value.state === 'pending')) {
      const next = services.update(pending, { state: 'failed' as const });
      services.store.put('connectorAuths', next);
      services.events.emit('connector_auth.upserted', next, { userIds: [connector.ownerUserId] });
    }
    try {
      if (scopedOwnerRevocation) {
        const marker = `connectorProfileSync:${connector.botId}`;
        services.store.setMetadata(marker, { connectorId: connector.id, actorUserId: actor.userId, connectorRevision: disconnected.revision });
        try {
          await syncBotConnectorRevocation(services, actor, connector.botId, connector.id, disconnected.revision);
          const snapshot = services.store.metadata<{ mcpServers: Parameters<typeof connectorConfigurationFingerprint>[0] }>(`botDesiredProfile:${connector.botId}`);
          if (!snapshot) fail('outcome_unknown', 'Scoped connector removal has no acknowledged configuration snapshot.', false);
          saveDetails(connector.id, { ...details(connector.id), desiredFingerprint: connectorConfigurationFingerprint(snapshot.mcpServers) });
        }
        finally { services.store.setMetadata(marker, null); }
        saveDetails(connector.id, { ...details(connector.id), provisionState: 'acknowledged' });
      } else if (!deletingBot) await provision(actor, disconnected);
      for (const name of config.oauthSecretNames) parseResponse(z.object({ name: z.literal(name), deleted: z.literal(true) }).strict(), await services.lemon.call('node.secrets.delete', { nodeId: machine.nodeId, name }, { mutation: true, resourceIds: [connector.id] }), true);
    } catch {
      saveDetails(connector.id, { ...details(connector.id), provisionState: 'outcome_unknown' });
      fail('outcome_unknown', 'Connector disconnect was not fully acknowledged; inspect the destination and do not replay.', false, { resourceIds: [connector.id] });
    }
    releaseRevocationFence(connector.botId, connector.id);
    services.store.transaction(() => {
      services.store.remove('connectors', connector.id);
      for (const grant of services.store.list<P.BotGrant>('botGrants', value => value.capabilityId === `connector:${connector.id}` && value.botId === connector.botId)) services.store.remove('botGrants', grant.id);
      services.store.setMetadata(`connector:${connector.id}`, null);
      services.store.setMetadata(`connectorTemplatePolicy:${connector.id}`, null);
      services.events.emit('connector.deleted', { id: connector.id, deleted: true }, connector.shared ? { botId: connector.botId } : { userIds: [connector.ownerUserId] });
      services.audit(actor, 'connector.disconnect', connector.id, 'succeeded');
    });
    return { id: connector.id, deleted: true };
  }
  async function deleteBotConnectors(actor: Principal, botId: string, confirmedBotRevision: number, selectedIds?: string[]): Promise<void> {
    const bot = services.store.require<P.Bot>('bots', botId);
    services.mutations.checkRevision(bot, confirmedBotRevision);
    if (bot.ownerUserId !== actor.userId && !(bot.visibility === 'team' && (actor.role === 'admin' || actor.role === 'owner'))) services.auth.bot(actor, botId, true);
    const candidates = services.store.list<P.Connector>('connectors', value => value.botId === botId && (selectedIds === undefined || selectedIds.includes(value.id)));
    if (selectedIds && (new Set(selectedIds).size !== selectedIds.length || candidates.length !== selectedIds.length || candidates.some(value => !value.shared && value.ownerUserId !== actor.userId))) fail('forbidden', 'Reset connector candidates must be exact owned accounts or managed service accounts.');
    for (const connector of candidates) await disconnectConnector(actor, connector, selectedIds === undefined);
  }
  function disconnectPlan(connector: P.Connector): { binding: P.JSONObject; affected: P.ScopeEffect[] } {
    const config = details(connector.id);
    const machine = services.store.require<P.Machine>('machines', config.machineId);
    const bot = services.store.require<P.Bot>('bots', connector.botId);
    const consents = services.store.list<P.ConnectorConsent>('consents', value => value.connectorId === connector.id && ['pending', 'approved'].includes(value.gate.state)).sort((a, b) => a.id.localeCompare(b.id));
    const grants = services.store.list<P.BotGrant>('botGrants', value => value.botId === connector.botId && value.capabilityId === `connector:${connector.id}`).sort((a, b) => a.id.localeCompare(b.id));
    const auths = services.store.list<P.ConnectorAuth>('connectorAuths', value => value.connectorId === connector.id && value.state === 'pending').sort((a, b) => a.id.localeCompare(b.id));
    const affected: P.ScopeEffect[] = [
      { resourceType: 'connector', id: connector.id, machineId: machine.id, operation: 'delete', explanation: 'Remove only this Bot connection and its acknowledged native MCP server.' },
      ...consents.map(value => ({ resourceType: 'consent', id: value.id, machineId: machine.id, operation: 'revoke' as const, explanation: 'Cancel this pending or remembered account grant; retained conversation history remains.' })),
      ...grants.map(value => ({ resourceType: 'bot_grant', id: value.id, machineId: machine.id, operation: 'revoke' as const, explanation: 'Remove the explicit connector capability grant.' })),
      ...config.oauthSecretNames.map(name => ({ resourceType: 'secret', id: name, machineId: machine.id, operation: 'delete' as const, explanation: 'Delete this product-issued OAuth credential on its original destination; manual secrets remain.' })),
    ];
    return { affected, binding: { machineId: machine.id, nodeId: machine.nodeId, botId: bot.id, botRevision: bot.revision, oauthSecretNames: [...config.oauthSecretNames].sort(), consents: consents.map(value => ({ id: value.id, revision: value.revision, consumedBy: privateMetadata<ConsentPrivate>(services, `consent:${value.id}`)?.consumedBy ?? null })), grants: grants.map(value => ({ id: value.id, revision: value.revision })), auths: auths.map(value => ({ id: value.id, revision: value.revision })) } };
  }
  function reconcilePlacement(bot: P.Bot): void {
    for (const connector of services.store.list<P.Connector>('connectors', value => value.botId === bot.id && value.state !== 'disconnected')) {
      const config = details(connector.id);
      if (config.machineId === bot.machineId) continue;
      revokeConsents(connector.id);
      saveDetails(connector.id, { ...config, configuredLevel: 'off', discoveredAtMs: null, provisionState: 'acknowledged' });
      publish(services.update(connector, { state: 'disconnected', tools: connector.tools.map(tool => ({ ...tool, enabled: false })), lastError: 'Assigned machine changed. Set up credentials on the new destination; no credentials were copied.' }));
      for (const grant of services.store.list<P.BotGrant>('botGrants', value => value.botId === bot.id && value.capabilityId === `connector:${connector.id}`)) services.store.put('botGrants', services.update(grant, { effectiveLevel: 'off', reasons: ['Connector credentials remain on the previous destination.'] }));
    }
  }
  async function reconcileConnector(actor: Principal, id: string): Promise<P.Connector | P.Deleted> {
    const connector = access(actor, id, true);
    const config = details(id);
    if (config.provisionState !== 'outcome_unknown') return connector;
    if (!config.desiredFingerprint || !config.desiredState) fail('outcome_unknown', 'No acknowledged configuration identity is available for this uncertain connector operation.', false, { resourceIds: [id] });
    const fence = services.store.metadata<{ connectorId: string; runIds: string[] }>(`connectorRevocation:${connector.botId}`);
    if (fence?.connectorId === id && fence.runIds.some(runId => !['succeeded', 'failed', 'cancelled'].includes(services.store.require<P.Run>('runs', runId).status))) fail('outcome_unknown', 'Connector invocations have not reached a verified terminal state.', false, { resourceIds: [id, ...fence.runIds] });
    const bot = services.store.require<P.Bot>('bots', connector.botId);
    const profile = parseResponse(z.object({ profile: z.object({ mcpConfigFingerprint: z.string() }).passthrough() }).passthrough(), await services.lemon.call('profiles.get', { id: bot.profileId }));
    if (profile.profile.mcpConfigFingerprint !== config.desiredFingerprint) fail('outcome_unknown', 'The persisted profile does not confirm the requested connector configuration. No mutation was replayed.', false, { resourceIds: [id] });
    if (config.desiredState === 'disconnected') {
      const machine = services.store.require<P.Machine>('machines', config.machineId);
      if (machine.status !== 'online' || !machine.nodeId) fail('machine_offline', 'The credential destination is unavailable for a read-only disconnect probe.');
      const secrets = parseResponse(z.object({ names: z.array(z.string()), truncated: z.boolean() }).passthrough(), await services.lemon.call('node.secrets.list', { nodeId: machine.nodeId }));
      if (secrets.truncated || config.oauthSecretNames.some(name => secrets.names.includes(name))) fail('outcome_unknown', 'Destination-owned OAuth credential deletion is not confirmed. No deletion was replayed.', false, { resourceIds: [id] });
      services.store.transaction(() => {
        services.store.remove('connectors', id);
        for (const grant of services.store.list<P.BotGrant>('botGrants', value => value.botId === connector.botId && value.capabilityId === `connector:${id}`)) services.store.remove('botGrants', grant.id);
        services.store.setMetadata(`connector:${id}`, null);
        services.store.setMetadata(`connectorTemplatePolicy:${id}`, null);
        services.events.emit('connector.deleted', { id, deleted: true }, connector.shared ? { botId: connector.botId } : { userIds: [connector.ownerUserId] });
      });
      if (fence?.connectorId === id) services.store.setMetadata(`connectorRevocation:${connector.botId}`, null);
      return { id, deleted: true };
    }
    const candidate = services.update(connector, { state: config.desiredState, lastError: null });
    const next = config.desiredState === 'connected' ? await discover(candidate) : candidate;
    saveDetails(id, { ...details(id), provisionState: 'acknowledged' });
    publish(next);
    if (fence?.connectorId === id) services.store.setMetadata(`connectorRevocation:${connector.botId}`, null);
    services.audit(actor, 'connector.provision.probe', id, 'succeeded');
    return next;
  }
  async function reconcile(): Promise<void> {
    for (const connector of services.store.list<P.Connector>('connectors')) {
      const config = details(connector.id);
      if (config.provisionState !== 'outcome_unknown' || !config.provisionActorUserId) continue;
      try { await reconcileConnector(userPrincipal(services, config.provisionActorUserId), connector.id); }
      catch (error) {
        if (!(error instanceof ApiError) || !['outcome_unknown', 'machine_offline', 'upstream_unavailable', 'policy_denied', 'forbidden', 'not_found', 'conflict'].includes(error.code)) throw error;
      }
    }
  }
  function canReadResource(actor: Principal, collection: string, entity: unknown): boolean | undefined {
    if (!['connectors', 'connectorAuths', 'consents'].includes(collection)) return undefined;
    const identity = z.object({ id: z.string() }).passthrough().safeParse(entity);
    if (!identity.success) return false;
    try {
      if (collection === 'connectors') {
        const connector = services.store.get<P.Connector>(collection, identity.data.id);
        if (!connector || !connector.shared && connector.ownerUserId !== actor.userId) return false;
        if (connector.ownerUserId !== actor.userId) services.auth.bot(actor, connector.botId);
        return true;
      }
      if (collection === 'connectorAuths') {
        const auth = services.store.get<P.ConnectorAuth>(collection, identity.data.id);
        if (!auth) return false;
        access(actor, auth.connectorId, true);
        return true;
      }
      const consent = services.store.get<P.ConnectorConsent>('consents', identity.data.id);
      if (!consent || consent.accountOwnerUserId !== actor.userId || consent.gate.targetUserId !== actor.userId) return false;
      const connector = services.store.get<P.Connector>('connectors', consent.connectorId);
      if (connector && (connector.ownerUserId !== consent.accountOwnerUserId || connector.botId !== consent.botId)) return false;
      if (!services.auth.member(actor.userId).enabled) return false;
      return true;
    } catch { return false; }
  }
  function completionProvider(completion: OAuthCompletion): P.OAuthProviderConfig {
    const binding = privateMetadata<{ providerId: string; tokenClientDigest: string }>(services, `connector-auth:${completion.resourceId}`);
    if (!binding) fail('capability_unavailable', 'Restore the original connector OAuth client registration before cleaning up its issued credential.', true, { resourceIds: [completion.id] });
    const candidates = integrationConfiguration(services).connectorProviders.filter(value => value.id === binding.providerId && value.oauth?.id === completion.providerId && oauthTokenClientDigest(value.oauth) === completion.tokenClientDigest && completion.tokenClientDigest === binding.tokenClientDigest);
    if (candidates.length !== 1 || !candidates[0]?.oauth) fail('capability_unavailable', 'Restore the exact registered connector OAuth client and issuer before credential cleanup.', true, { resourceIds: [completion.id] });
    return candidates[0].oauth;
  }
  async function retireOAuthCompletion(completion: OAuthCompletion): Promise<void> {
    if (completion.callbackPath !== '/v1/connectors/oauth/callback') fail('forbidden', 'OAuth completion does not belong to connector authorization.');
    const receipt = await revokeOAuthCompletion(services, completionProvider(completion), completion);
    if (receipt.access.state === 'revoked' && (!receipt.refresh || receipt.refresh.state === 'revoked')) return;
    const failure = receipt.access.state === 'failed' ? receipt.access : receipt.refresh?.state === 'failed' ? receipt.refresh : null;
    if (failure) fail(failure.errorCode ?? 'capability_unavailable', 'Configure the registered connector OAuth revocation endpoint and client credential to finish pending grant cleanup.', true, { resourceIds: [completion.id] });
    fail('outcome_unknown', 'Connector OAuth grant revocation is not confirmed. Configure introspection and reconcile; the revocation will not be replayed.', false, { resourceIds: [completion.id] });
  }
  async function cleanupOAuthUser(userId: string): Promise<void> {
    for (const completion of services.store.list<OAuthCompletion>('oauthCompletions', value => value.userId === userId && value.callbackPath === '/v1/connectors/oauth/callback')) {
      const previous = services.store.get<OAuthRevocationReceipt>('oauthRevocationReceipts', completion.id);
      if (previous && (previous.access.state === 'failed' || previous.refresh?.state === 'failed')) {
        // Explicit teardown only: failed proves no dispatch; uncertain entries never reset.
        const reset: OAuthRevocationReceipt = { ...previous, access: previous.access.state === 'failed' ? { state: 'pending', errorCode: null } : previous.access, refresh: previous.refresh?.state === 'failed' ? { state: 'pending', errorCode: null } : previous.refresh, updatedAtMs: services.now() };
        services.store.put('oauthRevocationReceipts', reset);
      }
      await retireOAuthCompletion(completion);
    }
    const uncertain = services.store.list<OAuthExchangeOperation>('oauthExchangeOperations', value => value.userId === userId && value.callbackPath === '/v1/connectors/oauth/callback' && ['pending', 'dispatching', 'outcome_unknown'].includes(value.state));
    if (uncertain.length) fail('outcome_unknown', 'An original connector OAuth exchange is unresolved; no authorization code will be replayed during account cleanup.', false, { resourceIds: uncertain.map(value => value.id) });
  }
  async function reconcileOAuthUser(userId: string): Promise<boolean> {
    for (const completion of services.store.list<OAuthCompletion>('oauthCompletions', value => value.userId === userId && value.callbackPath === '/v1/connectors/oauth/callback')) await reconcileOAuthRevocation(services, completionProvider(completion), completion);
    return !services.store.list<OAuthCompletion>('oauthCompletions', value => value.userId === userId && value.callbackPath === '/v1/connectors/oauth/callback').length && !services.store.list<OAuthExchangeOperation>('oauthExchangeOperations', value => value.userId === userId && value.callbackPath === '/v1/connectors/oauth/callback' && ['pending', 'dispatching', 'outcome_unknown'].includes(value.state)).length;
  }
  return { access, details, saveDetails, provider, destination, assertOrigin, assertConnectorPolicy, headers, validateBindings, discover, publish, provision, create, enabled, grantFor, revokeConsents, synchronize, connectorProfileConfiguration, connectorInvocationConfiguration, connectorTemplates, authorizeConnectorTool, requestConnectorConsent, resolveConsent, revokeConsent, connectorProvisioning, disconnectConnector, deleteBotConnectors, connectorGrants, fenceConnectorInvocations, reconcileConnector, reconcile, reconcilePlacement, canReadResource, prepareProvision, cleanupOAuthUser, reconcileOAuthUser, retireOAuthCompletion, disconnectPlan, assertReady, canManageBot };
}

/** Full /v1 routes; the core mutation service owns nonce reservation and exact replay. */
export function createConnectorRoutes(services: BackendServices): Route[] {
  const connectors = createConnectorServices(services);
  const authPublish = (value: P.ConnectorAuth): P.ConnectorAuth => {
    services.store.put('connectorAuths', value);
    const connector = services.store.require<P.Connector>('connectors', value.connectorId);
    services.events.emit('connector_auth.upserted', value, { userIds: [connector.ownerUserId] });
    return value;
  };
  async function startAuthorization(context: RequestContext): Promise<P.ConnectorAuth> {
    parse(mutationSchema, context.body);
    const actor = principal(context);
    const connector = connectors.access(actor, context.params.id!, true);
    if (connectors.details(connector.id).provisionState === 'outcome_unknown') fail('outcome_unknown', 'Connector provisioning must be reconciled before another authorization.', false, { resourceIds: [connector.id] });
    connectors.assertReady(connector);
    connectors.assertConnectorPolicy(connector);
    if (connector.shared && !connectors.canManageBot(actor, connector.botId)) fail('forbidden', 'A Bot maintainer must authorize reconnecting shared credentials.');
    const auth = services.resource('connector_auth', { connectorId: connector.id, authorizationUrl: '', expiresAtMs: services.now() + 600000, state: 'pending' as P.ConnectorAuth['state'] });
    context.nonceResourceIds.push(auth.id, connector.id);
    if (connector.authKind !== 'oauth') {
      if (connector.authKind === 'secret_headers' && !connectors.details(connector.id).bindings.length) fail('capability_unavailable', 'Configure existing destination secret names through connector secretBindings before authenticating.');
      services.store.put('connectorAuths', auth);
      try {
        await connectors.validateBindings(actor, connectors.destination(connector), connectors.details(connector.id).bindings);
        const connected = await connectors.discover(connector);
        await connectors.provision(actor, connected);
        return authPublish(services.update(auth, { state: 'connected' }));
      } catch (error) {
        authPublish(services.update(auth, { state: 'failed' }));
        throw error;
      }
    }
    if (actor.userId !== connector.ownerUserId) fail('forbidden', 'Only the actual account owner can authorize OAuth credentials.');
    const configured = connectors.provider(connector);
    if (!configured?.oauth) fail('capability_unavailable', 'Register this connector origin, OAuth client, secret reference and backend callback with the operator.');
    for (const pending of services.store.list<P.ConnectorAuth>('connectorAuths', value => value.connectorId === connector.id && value.state === 'pending')) authPublish(services.update(pending, { state: 'failed' }));
    const started = startOAuth(services, configured.oauth, { userId: actor.userId, resourceId: auth.id, callbackPath: '/v1/connectors/oauth/callback' });
    savePrivateMetadata(services, `connector-auth:${auth.id}`, { connectorRevision: connector.revision, machineId: connectors.destination(connector).id, providerId: configured.id, providerDigest: services.mutations.digest(configured.oauth), tokenClientDigest: oauthTokenClientDigest(configured.oauth) });
    return authPublish({ ...auth, authorizationUrl: started.authorizationUrl, expiresAtMs: started.flow.expiresAtMs });
  }
  async function callback(context: RequestContext): Promise<P.ConnectorAuth> {
    const query = parse(z.object({ state: z.string().regex(/^[A-Za-z0-9_-]{32,128}$/), code: z.string().min(1).max(8192).optional(), error: z.string().min(1).max(256).optional() }).strict().refine(value => Boolean(value.code) !== Boolean(value.error)), Object.fromEntries(context.query));
    const flow = takeOAuthState(services, query.state);
    const auth = services.store.require<P.ConnectorAuth>('connectorAuths', flow.resourceId);
    const connector = services.store.require<P.Connector>('connectors', auth.connectorId);
    const binding = privateMetadata<{ connectorRevision: number; machineId: string; providerId: string; providerDigest: string }>(services, `connector-auth:${auth.id}`);
    const configured = connectors.provider(connector);
    if (!configured?.oauth) fail('capability_unavailable', 'The registered connector OAuth provider is no longer configured.');
    if (auth.state !== 'pending' || !binding || binding.connectorRevision !== connector.revision || binding.machineId !== connectors.destination(connector).id || binding.providerId !== configured.id || binding.providerDigest !== services.mutations.digest(configured.oauth) || configured.oauth.id !== flow.providerId || connector.ownerUserId !== flow.userId) fail('conflict', 'OAuth callback no longer matches this account, registered client, provider or destination.');
    const actor = userPrincipal(services, flow.userId);
    services.auth.bot(actor, connector.botId);
    connectors.assertConnectorPolicy(connector);
    if (query.error) {
      connectors.publish(services.update(connector, { state: 'needs_auth', lastError: 'Provider authorization was denied.' }));
      return authPublish(services.update(auth, { state: 'denied' }));
    }
    const accessName = `LB_OAUTH_${sha256(auth.id).replace(/[^A-Za-z0-9]/g, '_')}`;
    const refreshName = `${accessName}_REFRESH`;
    try {
      const token = await exchangeOAuth(services, configured.oauth, flow, query.code!, { clientAuthentication: configured.oauth.clientAuthentication ?? 'body' });
      const machine = connectors.destination(connector);
      const config = connectors.details(connector.id);
      connectors.assertReady(connector, true);
      // The only token egress is write-only destination storage; no profile or event gets a value.
      assertActiveAccount(services, flow.userId, true);
      const newNames = [accessName, ...(token.refresh_token ? [refreshName] : [])];
      connectors.saveDetails(connector.id, { ...config, oauthSecretNames: [...new Set([...config.oauthSecretNames, ...newNames])], provisionState: 'pending' });
      parseResponse(z.object({ name: z.literal(accessName), set: z.literal(true) }).strict(), await services.lemon.call('node.secrets.set', { nodeId: machine.nodeId, name: accessName, value: token.access_token }, { mutation: true, resourceIds: [connector.id, auth.id] }), true);
      assertActiveAccount(services, flow.userId, true);
      if (token.refresh_token) parseResponse(z.object({ name: z.literal(refreshName), set: z.literal(true) }).strict(), await services.lemon.call('node.secrets.set', { nodeId: machine.nodeId, name: refreshName, value: token.refresh_token }, { mutation: true, resourceIds: [connector.id, auth.id] }), true);
      assertActiveAccount(services, flow.userId, true);
      connectors.assertReady(connector, true);
      const expiresAtMs = token.expires_in === undefined ? null : services.now() + Math.floor(token.expires_in * 1000);
      if (expiresAtMs !== null && !Number.isSafeInteger(expiresAtMs)) fail('upstream_unavailable', 'Provider returned an invalid credential expiration.', false);
      connectors.saveDetails(connector.id, { ...connectors.details(connector.id), bindings: [{ header: 'Authorization', secretName: accessName }], oauthExpiresAtMs: expiresAtMs });
      connectors.revokeConsents(connector.id);
      const candidate = services.update(connector, { secretHeaderNames: ['Authorization'] });
      await connectors.prepareProvision(actor, candidate);
      await connectors.fenceConnectorInvocations(actor, connector.id);
      const connected = await connectors.discover(candidate);
      connectors.assertReady(connector, true);
      assertActiveAccount(services, flow.userId, true);
      connectors.publish(connected);
      await connectors.connectorGrants(actor, services.store.require<P.Bot>('bots', connector.botId));
      await connectors.provision(actor, connected);
      assertActiveAccount(services, flow.userId, true);
      for (const oldName of config.oauthSecretNames.filter(name => !newNames.includes(name))) parseResponse(z.object({ name: z.literal(oldName), deleted: z.literal(true) }).strict(), await services.lemon.call('node.secrets.delete', { nodeId: machine.nodeId, name: oldName }, { mutation: true, resourceIds: [connector.id, auth.id] }), true);
      connectors.saveDetails(connector.id, { ...connectors.details(connector.id), oauthSecretNames: newNames });
      return services.store.transaction(() => {
        assertActiveAccount(services, flow.userId, true);
        const result = authPublish(services.update(auth, { state: 'connected' }));
        markOAuthInstalled(services, flow.id);
        return result;
      });
    } catch (error) {
      const uncertain = !(error instanceof ApiError) || !error.retrySafe;
      if (!services.store.get<P.Connector>('connectors', connector.id)) fail('outcome_unknown', 'The account connector was removed during authorization; reconcile the issued credential completion.', false, { resourceIds: [connector.id, auth.id, flow.id] });
      connectors.saveDetails(connector.id, { ...connectors.details(connector.id), provisionState: uncertain ? 'outcome_unknown' : 'pending' });
      connectors.publish(services.update(services.store.require<P.Connector>('connectors', connector.id), { state: error instanceof ApiError && error.code === 'policy_denied' ? 'blocked' : 'failed', lastError: uncertain ? 'Authorization outcome is not confirmed. Inspect destination credentials before retrying.' : 'Provider authorization or destination discovery failed.' }));
      authPublish(services.update(auth, { state: 'failed' }));
      if (uncertain) fail('outcome_unknown', 'Connector authorization outcome is unknown; the callback will not be replayed.', false, { resourceIds: [connector.id, auth.id] });
      throw error;
    }
  }
  async function update(context: RequestContext): Promise<P.Connector> {
    const body = parse(updateSchema, context.body);
    const actor = principal(context);
    const connector = connectors.access(actor, context.params.id!, true);
    services.mutations.checkRevision(connector, body.revision);
    context.nonceResourceIds.push(connector.id);
    const config = connectors.details(connector.id);
    if (config.provisionState === 'outcome_unknown') fail('outcome_unknown', 'Connector provisioning is not confirmed; inspect the destination before editing.', false, { resourceIds: [connector.id] });
    if (body.tools && (body.tools.length !== connector.tools.length || body.tools.some(tool => !connector.tools.some(existing => existing.name === tool.name)))) fail('invalid_request', 'Tool controls must replace the complete actually discovered inventory.');
    if (body.secretBindings) {
      if (actor.userId !== connector.ownerUserId) fail('forbidden', 'Only the account owner can replace credential bindings.');
      if (connector.authKind !== 'secret_headers' || !body.secretBindings.length) fail('invalid_request', 'Only secret-header connectors accept explicit credential bindings.');
      await connectors.validateBindings(actor, connectors.destination(connector), body.secretBindings);
      connectors.saveDetails(connector.id, { ...config, bindings: body.secretBindings });
    }
    const revoking = body.secretBindings !== undefined || Boolean(body.tools?.some(tool => !tool.enabled && connector.tools.find(existing => existing.name === tool.name)?.enabled));
    if (revoking) connectors.revokeConsents(connector.id);
    const candidate = services.update(connector, { ...(body.name === undefined ? {} : { name: body.name }), ...(body.accountLabel === undefined ? {} : { accountLabel: body.accountLabel }), ...(body.tools === undefined ? {} : { tools: body.tools }), ...(body.secretBindings === undefined ? {} : { secretHeaderNames: body.secretBindings.map(value => value.header) }) });
    if (revoking) {
      await connectors.prepareProvision(actor, candidate);
      await connectors.fenceConnectorInvocations(actor, connector.id);
    }
    const next = candidate.state === 'connected' ? await connectors.discover(candidate) : candidate;
    const result = await connectors.provision(actor, next);
    services.audit(actor, 'connector.update', connector.id, 'succeeded');
    return result;
  }
  async function disconnect(context: RequestContext): Promise<P.Deleted> {
    const body = parse(confirmSchema, context.body);
    const actor = principal(context);
    const connector = connectors.access(actor, context.params.id!, true);
    services.mutations.checkRevision(connector, body.revision);
    services.mutations.confirm(actor, connector, 'disconnect', body, connectors.disconnectPlan(connector).binding);
    context.nonceResourceIds.push(connector.id);
    return connectors.disconnectConnector(actor, connector);
  }
  return [
    { method: 'GET', path: '/v1/bots/:id/connectors', auth: 'member', handler: context => {
      const actor = principal(context);
      const bot = services.auth.bot(actor, context.params.id!);
      connectors.reconcilePlacement(bot);
      for (const connector of services.store.list<P.Connector>('connectors', value => value.botId === bot.id && (value.ownerUserId === actor.userId || value.shared))) {
        try { connectors.assertConnectorPolicy(connector); }
        catch (error) { if (!(error instanceof ApiError) || error.code !== 'policy_denied') throw error; }
      }
      return services.page(context, services.store.list<P.Connector>('connectors', value => value.botId === bot.id && (value.ownerUserId === actor.userId || value.shared)));
    } },
    { method: 'POST', path: '/v1/bots/:id/connectors', auth: 'member', status: 201, handler: async context => {
      return connectors.create(principal(context), context.params.id!, parse(createSchema, context.body), 'read_interact', context.nonceResourceIds);
    } },
    { method: 'POST', path: '/v1/bots/:id/connectors/setup', auth: 'member', status: 201, handler: async context => {
      const body = parse(setupSchema, context.body);
      const actor = principal(context);
      const bot = services.auth.bot(actor, context.params.id!, true);
      if (bot.ownerUserId !== actor.userId) fail('forbidden', 'Only the Bot owner can perform destination connector setup.');
      if (bot.machineId !== body.machineId) fail('conflict', 'Setup machine must equal the Bot current assignment.');
      const connector = await connectors.create(actor, bot.id, body, body.requestedLevel, context.nonceResourceIds);
      return { connector, machineId: bot.machineId, secretNames: body.secretBindings.map(value => value.secretName), grants: (await connectors.connectorGrants(actor, bot)).filter(value => value.capabilityId === `connector:${connector.id}`) } satisfies P.ConnectorSetupResult;
    } },
    { method: 'PATCH', path: '/v1/connectors/:id', auth: 'member', handler: update },
    { method: 'POST', path: '/v1/connectors/:id/preview', auth: 'member', handler: context => {
      parse(previewSchema, context.body);
      const actor = principal(context);
      const connector = connectors.access(actor, context.params.id!, true);
      const plan = connectors.disconnectPlan(connector);
      return services.mutations.preview(actor, connector, 'disconnect', connector.name, ['Remove this Bot MCP connection and revoke its future consent grants.', 'Delete product-owned OAuth secrets from this destination; manually configured named secrets remain.', 'Retain conversation history, learned memory, host files, browser logins, and independent provider sessions.'], plan.affected, plan.binding);
    } },
    { method: 'DELETE', path: '/v1/connectors/:id', auth: 'member', handler: disconnect },
    { method: 'POST', path: '/v1/connectors/:id/auth', auth: 'member', handler: startAuthorization },
    { method: 'GET', path: '/v1/connector-auth/:id', auth: 'member', handler: context => {
      const value = services.store.require<P.ConnectorAuth>('connectorAuths', context.params.id!);
      connectors.access(principal(context), value.connectorId, true);
      return value.state === 'pending' && value.expiresAtMs <= services.now() ? authPublish(services.update(value, { state: 'expired' })) : value;
    } },
    { method: 'GET', path: '/v1/connectors/oauth/callback', auth: 'public', mutation: false, handler: callback },
    { method: 'GET', path: '/v1/consents', auth: 'member', handler: context => {
      const actor = principal(context);
      return services.page(context, services.store.list<P.ConnectorConsent>('consents', value => value.accountOwnerUserId === actor.userId && value.gate.targetUserId === actor.userId));
    } },
    { method: 'POST', path: '/v1/consents/:id/resolve', auth: 'member', handler: context => connectors.resolveConsent(principal(context), context.params.id!, parse(consentSchema, context.body)) },
    { method: 'DELETE', path: '/v1/consents/:id', auth: 'member', handler: context => connectors.revokeConsent(principal(context), context.params.id!, parse(revisionSchema, context.body)) },
  ];
}
