import { afterEach, describe, expect, test } from 'bun:test';
import { createHash } from 'node:crypto';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { AccessService, BackendServices, EventService, GateService, HttpClient, IntegrationServices, LemonService, MutationService, Principal } from '../../src/core/services';
import { Store } from '../../src/core/store';
import { createPrivateCodec } from '../../src/core/config';
import { installHelpers } from '../../src/core/helpers';
import { createAccessService } from '../../src/core/auth';
import { createEventService } from '../../src/core/events';
import { createMutationService } from '../../src/core/mutations';
import { createGateService } from '../../src/core/gates';
import { syncBotProfile, baseBotMcpTemplate, botSystemPrompt } from '../../src/core/bots';
import { buildInvocationContext, revokeConnectorInvocations } from '../../src/runtime/runs';
import { Router } from '../../src/core/router';
import { ApiError } from '../../src/core/errors';
import { createPolicyServices } from '../../src/enterprise/policy';
import { createConnectorRoutes, createConnectorServices, connectorConfigurationFingerprint } from '../../src/integrations/connectors';
import { createPushServices } from '../../src/integrations/push';
import type { InvocationContext, InvocationMcpServer } from '../../src/runtime/runs';
import { privateMetadata, sha256 } from '../../src/integrations/common';
import type { OAuthState } from '../../src/integrations/oauth';

const ORIGIN = 'https://93.184.216.34';
const PUBLIC_URL = 'https://product.example';
const serverSchema = z.object({ name: z.string(), url: z.string(), headers: z.record(z.string(), z.string()), enabledTools: z.array(z.string()).optional(), allowedOrigins: z.array(z.string()).optional(), approvedPrivateOrigins: z.array(z.string()).optional() }).strict();
type Server = z.infer<typeof serverSchema>;
const profileSchema = z.object({ id: z.string(), name: z.string(), description: z.string(), systemPrompt: z.string(), toolPolicy: z.record(z.string(), z.json()), mcpServers: z.array(serverSchema) }).strict();
type Profile = z.infer<typeof profileSchema>;

// Public execution-name records for the fixed product endpoint, using
// LemonSkills.McpSource.execution_name's ETF identity and 31-byte slug prefix.
const productToolNames = ['message_bot', 'handoff', 'create_draft', 'ask_user', 'request_approval', 'request_human_step', 'request_secret', 'send_voice_memo', 'share_file', 'create_routine', 'update_routine', 'save_skill', 'list_bots', 'post_to_group', 'remember', 'create_bot', 'update_preferences', 'create_reminder'] as const;
function executionName(server: Pick<Server, 'name' | 'url'>, name: string): string {
  const binary = (value: string): Buffer => {
    const bytes = Buffer.from(value);
    const header = Buffer.alloc(5);
    header[0] = 109; header.writeUInt32BE(bytes.length, 1);
    return Buffer.concat([header, bytes]);
  };
  const endpoint = new URL(server.url);
  const identity = Buffer.concat([Buffer.from([131, 104, 3]), binary(server.name), binary(endpoint.href), Buffer.from([104, 2, 100, 0, 4]), Buffer.from('tool'), binary(name)]);
  const slug = (value: string) => value.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
  const prefix = `mcp_${slug(server.name.split('/').at(-1)!)}_${slug(name)}`.slice(0, 31);
  return `${prefix}_${createHash('sha256').update(identity).digest('hex').slice(0, 32)}`;
}
const productExecutionProjection = {
  server: { name: 'lemon-bot' },
  tools: productToolNames.map(name => ({ name, executionName: executionName({ name: 'lemon-bot', url: `${PUBLIC_URL}/mcp` }, name) })),
  count: productToolNames.length,
};


/** Stateful destination records: measured presence, stored profiles and destination-only secret resolution. */
class DestinationPeer implements LemonService {
  connected = true;
  methods = ['node.mcp.discover', 'node.secrets.list', 'node.secrets.set', 'node.secrets.delete', 'node.capabilities.get', 'node.runtime.features', 'nodes.list', 'node.host.info', 'profiles.update', 'profiles.get', 'profiles.sync', 'mcp.execution_names', 'profile.followup.admission.set', 'runs.followup.lineage.get', 'chat.abort', 'agent.wait'];
  calls: { method: string; params: Record<string, unknown> }[] = [];
  secrets = new Map<string, string>();
  profiles = new Map<string, Server[]>();
  private currentProfiles = new Map<string, Profile>();
  private destinationProfiles = new Map<string, Profile>();
  private admissionIssuers = new Map<string, { url: string; encryptedToken: string }>();
  failure: 'discovery' | 'sync_after_apply' | 'secret_write_after_apply' | 'cancellation' | null = null;
  private codec = createPrivateCodec(new Uint8Array(32).fill(29));
  private events = new Set<(event: string, payload: unknown) => void>();
  private connections = new Set<() => void>();
  putSecret(name: string, value: string): void { this.secrets.set(name, this.codec.encrypt(value)); }
  readSecret(name: string): string {
    const encrypted = this.secrets.get(name);
    if (!encrypted) throw new ApiError('upstream_unavailable', 'Destination secret resolution failed.');
    return this.codec.decrypt<string>(encrypted);
  }
  putProfile(profile: Profile): void {
    const stored = profileSchema.parse(profile);
    this.currentProfiles.set(stored.id, structuredClone(stored));
    this.destinationProfiles.set(stored.id, structuredClone(stored));
    this.profiles.set(stored.id, structuredClone(stored.mcpServers));
  }
  async call<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    this.calls.push({ method, params: structuredClone(params) });
    let result: unknown;
    switch (method) {
      case 'nodes.list': {
        z.object({ nodeId: z.literal('node-1') }).strict().parse(params);
        result = { nodes: [{ id: 'node-1', name: 'fixture-node', purpose: 'lemon_bot', enrollmentInviteId: 'invite-1', status: 'online', lastSeenMs: 1_800_000_000_000, pairedAtMs: 1_800_000_000_000, capabilities: ['node.mcp.discover', 'node.capabilities.get', 'node.secrets.list', 'node.secrets.set', 'node.secrets.delete'] }], summary: { presenceAvailable: true, truncated: false } }; break;
      }
      case 'node.host.info': {
        z.object({ nodeId: z.literal('node-1') }).strict().parse(params);
        result = { hostname: 'fixture-node', os: 'linux', osVersion: '6.12', arch: 'arm64', cpuCount: 4, memTotalBytes: 8_589_934_592, memFreeBytes: 4_294_967_296, diskTotalBytes: 137_438_953_472, diskFreeBytes: 68_719_476_736, uptimeSec: 60, lemonVersion: 'fixture', defaultCwd: '/home/fixture', user: 'fixture' }; break;
      }
      case 'node.capabilities.get': {
        z.object({ nodeId: z.literal('node-1') }).strict().parse(params);
        // This peer implements connector operations, not native filesystem/shell/browser grants.
        result = { nodeId: 'node-1', os: 'linux', measuredAtMs: 1_800_000_000_000, stale: false, items: [] }; break;
      }
      case 'node.runtime.features': {
        const input = z.object({ nodeId: z.literal('node-1') }).strict().parse(params);
        result = { nodeId: input.nodeId, protocol: 1, lemonVersion: 'fixture', methods: this.methods, features: { hostIO: true, filesystemCAS: true, deletePreviews: true, encryptedSecrets: true, ptyShell: true, mcpDiscovery: true, profileSync: true, liveStreaming: true, repairInvites: true, nativeExecutionPolicy: true }, botReady: true, missingFeatures: [], nativePrivacyContext: { version: 1 } }; break;
      }
      case 'mcp.execution_names': {
        z.object({ server: z.object({ name: z.literal('lemon-bot'), url: z.literal(`${PUBLIC_URL}/mcp`) }).strict(), toolNames: z.array(z.enum(productToolNames)).refine(names => names.length === productToolNames.length && names.every((name, index) => name === productToolNames[index])) }).strict().parse(params);
        result = structuredClone(productExecutionProjection); break;
      }
      case 'profile.followup.admission.set': {
        const input = z.object({ profileId: z.literal('lb-fixture'), url: z.literal(`${PUBLIC_URL}/internal/runtime/followup/admission`), token: z.string().min(32) }).strict().parse(params);
        if (!this.destinationProfiles.has(input.profileId)) throw new ApiError('not_found', 'Destination profile was not synchronized.');
        this.admissionIssuers.set(input.profileId, { url: input.url, encryptedToken: this.codec.encrypt(input.token) });
        result = { profileId: input.profileId, configured: true }; break;
      }
      case 'runs.followup.lineage.get': throw new ApiError('not_found', 'No native follow-up was issued by this destination.');
      case 'chat.abort': result = { aborted: true }; break;
      case 'agent.wait': {
        if (this.failure === 'cancellation') throw new ApiError('upstream_unavailable', 'Runtime terminal state unavailable.');
        result = { runId: params.runId, ok: false, answer: null, cancelled: true }; break;
      }
      case 'node.secrets.list': {
        z.object({ nodeId: z.literal('node-1') }).strict().parse(params);
        result = { names: [...this.secrets.keys()], limit: 500, truncated: false }; break;
      }
      case 'node.secrets.set': {
        const input = z.object({ nodeId: z.literal('node-1'), name: z.string(), value: z.string(), operationId: z.string().min(1).optional() }).strict().parse(params);
        this.putSecret(input.name, input.value);
        if (this.failure === 'secret_write_after_apply') throw new ApiError('outcome_unknown', 'Destination acknowledgement lost.', false);
        result = { name: input.name, set: true, ...(input.operationId ? { operationId: input.operationId, currentBindingMatches: this.readSecret(input.name) === input.value } : {}) }; break;
      }
      case 'node.secrets.delete': {
        const input = z.object({ nodeId: z.literal('node-1'), name: z.string() }).strict().parse(params);
        this.secrets.delete(input.name); result = { name: input.name, deleted: true }; break;
      }
      case 'node.mcp.discover': {
        const input = z.object({ nodeId: z.literal('node-1'), server: serverSchema }).strict().parse(params);
        const origin = new URL(input.server.url).origin;
        if (!input.server.allowedOrigins?.includes(origin)) throw new ApiError('policy_denied', 'Destination origin refused.');
        for (const header of Object.values(input.server.headers)) {
          for (const match of header.matchAll(/\$\{LEMON_SECRET:([^}]+)\}/g)) this.readSecret(match[1]!);
          if (/\$\{LEMON_SECRET:[^}]*$/.test(header)) throw new ApiError('upstream_unavailable', 'Destination reference malformed.');
        }
        if (this.failure === 'discovery') throw new ApiError('upstream_unavailable', 'Destination MCP discovery failed.');
        result = { connected: true, server: { name: input.server.name, status: 'connected' }, tools: [{ name: 'read_items', executionName: executionName(input.server, 'read_items'), description: 'Read records', inputSchema: { type: 'object' }, readOnly: true }, { name: 'write_item', executionName: executionName(input.server, 'write_item'), description: 'Change a record', inputSchema: { type: 'object' }, readOnly: false }], count: 2, truncated: false }; break;
      }
      case 'profiles.update': {
        const patch = profileSchema.partial().required({ id: true }).parse(params);
        const previous = this.currentProfiles.get(patch.id);
        if (!previous) throw new ApiError('not_found', 'Controller profile does not exist.');
        const stored = profileSchema.parse({ ...previous, ...patch });
        this.currentProfiles.set(stored.id, structuredClone(stored));
        this.profiles.set(stored.id, structuredClone(stored.mcpServers));
        result = { profile: this.profileRecord(stored.id) }; break;
      }
      case 'profiles.sync': {
        const input = z.object({ id: z.literal('lb-fixture'), nodeId: z.literal('node-1'), mutationId: z.string().min(1) }).strict().parse(params);
        const stored = this.currentProfiles.get(input.id);
        if (!stored) throw new ApiError('not_found', 'Controller profile does not exist.');
        this.destinationProfiles.set(input.id, structuredClone(stored));
        if (this.failure === 'sync_after_apply') throw new ApiError('outcome_unknown', 'Profile synchronization acknowledgement lost.', false);
        result = { profileId: input.id, nodeId: input.nodeId, mutationId: input.mutationId, acknowledged: true, revisionDigest: createHash('sha256').update(JSON.stringify(stored)).digest('hex') }; break;
      }
      case 'profiles.get': {
        const id = z.object({ id: z.literal('lb-fixture') }).strict().parse(params).id;
        result = { profile: this.profileRecord(id) }; break;
      }
      default: throw new Error(`Unexpected destination test RPC: ${method}`);
    }
    return result as T;
  }
  private profileRecord(id: string) {
    const stored = this.currentProfiles.get(id);
    if (!stored) throw new ApiError('not_found', 'Controller profile does not exist.');
    const canonical = stored.mcpServers.map(server => [server.name, server.url, Object.entries(server.headers).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0), server.enabledTools ?? null, server.allowedOrigins ?? null, server.approvedPrivateOrigins ?? null]);
    return { ...structuredClone(stored), canonicalSessionKey: `agent:${id}:main`, mcpConfigFingerprint: createHash('sha256').update(JSON.stringify(canonical)).digest('hex') };
  }
  onEvent(listener: (event: string, payload: unknown) => void): () => void { this.events.add(listener); return () => this.events.delete(listener); }
  onConnected(listener: () => void): () => void { this.connections.add(listener); return () => this.connections.delete(listener); }
  start(): void { this.connected = true; for (const listener of this.connections) listener(); }
  close(): void { this.connected = false; this.events.clear(); this.connections.clear(); }
}

const cleanup: (() => void)[] = [];
afterEach(() => { for (const close of cleanup.splice(0)) close(); });

function unexpectedBoundary(boundary: string): () => never {
  return () => { throw new Error(`Unexpected connector fixture boundary: ${boundary}`); };
}

async function fixture() {
  const store = new Store(':memory:');
  const peer = new DestinationPeer();
  const key = new Uint8Array(32).fill(7);
  const codec = createPrivateCodec(key);
  const operator: P.OperatorConfiguration = { version: 1, trustedFrontendOrigins: [], oauthRedirectUris: [], serverSecrets: {}, channelProviders: [], emailProviders: [], eventProviders: [], hostDrivers: [], xProvider: null, exportAllowedOrigins: [], requiredRuntimeDestinations: [], breakGlassOwnerUserId: null };
  const oauth: P.OAuthProviderConfig = { id: 'records-oauth', clientId: 'registered-client', clientSecretRef: 'records-client-secret', authorizeUrl: `${ORIGIN}/oauth/authorize`, tokenUrl: `${ORIGIN}/oauth/token`, scopes: ['records.read', 'records.write'], redirectUris: [`${PUBLIC_URL}/v1/connectors/oauth/callback`], allowedOrigins: [ORIGIN] };
  operator.connectorProviders = [{ id: 'records', origins: [ORIGIN], oauth, sharedServiceAccount: false }];
  operator.approvedPrivateMcpOrigins = [];
  let serial = 0;
  let now = 1_800_000_000_000;
  let auth: AccessService | undefined;
  let events: EventService | undefined;
  let mutations: MutationService | undefined;
  let gates: (GateService & { close(): void }) | undefined;
  let integrations: IntegrationServices | undefined;
  // Lazy factories retain the real cyclic graph; helpers/router replace only their installation boundaries.
  const services: BackendServices = {
    config: { publicUrl: PUBLIC_URL, controlUrl: 'ws://127.0.0.1:4040/ws', operatorToken: 'test-operator-not-a-provider-token', dataDir: '/unused-test-data', host: '127.0.0.1', port: 4080, trustedOverlay: false, operator },
    store, lemon: peer, ...codec,
    get auth() { return auth ??= createAccessService(services); },
    get events() { return events ??= createEventService(services); },
    get mutations() { return mutations ??= createMutationService(services, key); },
    get gates() { return gates ??= createGateService(services); },
    get integrations(): IntegrationServices {
      if (!integrations) {
        const push = createPushServices(services, { env: {} });
        integrations = {
          ...createPolicyServices(services),
          admission: unexpectedBoundary('integrations.admission'),
          connectorConfig: connectorServices.connectorProfileConfiguration,
          connectorTemplates: connectorServices.connectorTemplates,
          canReadResource: (actor, collection, entity) => connectorServices.canReadResource(actor, collection, entity) ?? false,
          sendApprovedDraft: unexpectedBoundary('integrations.sendApprovedDraft'),
          emitProviderNotifications: push.emitProviderNotifications,
          channelIngress: unexpectedBoundary('integrations.channelIngress'),
          providerCapabilities: push.providerCapabilities,
        };
      }
      return integrations;
    },
    runtime: {
      submit: unexpectedBoundary('runtime.submit'),
      send: unexpectedBoundary('runtime.send'),
      cancel: unexpectedBoundary('runtime.cancel'),
      revokeConnectorInvocations: (actor, botId, connectorId) => revokeConnectorInvocations(services, actor, botId, connectorId),
      reconcile: unexpectedBoundary('runtime.reconcile'),
      sessionKey: unexpectedBoundary('runtime.sessionKey'),
    },
    attachments: {
      create: unexpectedBoundary('attachments.create'),
      copy: unexpectedBoundary('attachments.copy'),
      bytes: unexpectedBoundary('attachments.bytes'),
      download: unexpectedBoundary('attachments.download'),
    },
    id: unexpectedBoundary('helpers.id before installation'),
    now: unexpectedBoundary('helpers.now before installation'),
    resource: unexpectedBoundary('helpers.resource before installation'),
    update: unexpectedBoundary('helpers.update before installation'),
    page: unexpectedBoundary('helpers.page before installation'),
    pageAfter: unexpectedBoundary('helpers.pageAfter before installation'),
    secret: async ref => { if (ref !== oauth.clientSecretRef) throw new Error('Backend attempted to resolve a destination secret.'); return 'configured-server-client-secret'; },
    http: async input => { throw new Error(`Unexpected connector fixture HTTP request: ${String(input)}`); },
    audit: unexpectedBoundary('helpers.audit before installation'),
    entry: unexpectedBoundary('helpers.entry before installation'),
    notify: unexpectedBoundary('helpers.notify before installation'),
    invoke: unexpectedBoundary('router.invoke before installation'),
    syncBotProfile: (actor, botId) => syncBotProfile(services, actor, botId),
  };
  installHelpers(services);
  services.id = (prefix = 'id') => `${prefix}_${String(++serial).padStart(24, '0')}`;
  services.now = () => now;
  const connectorServices = createConnectorServices(services);
  const gateService = gates ??= createGateService(services);
  const router = new Router(services);
  router.register(createConnectorRoutes(services));
  store.setMetadata('workspaceId', 'workspace-1');
  // Resource helper supplies generated IDs, so fixed fixture identity is applied last.
  const preferences: P.Preferences = { appearance: 'system', language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false };
  for (const userId of ['alice', 'bob']) {
    const user: P.User = { ...services.resource('user', { email: `${userId}@example.test`, displayName: userId, avatarAttachmentId: null, preferences, notifications: { enabled: false, sound: false, previews: false, completed: false, needsInput: false } }), id: userId };
    store.put('users', user);
    store.put('members', { ...services.resource('member', { userId, email: user.email, displayName: userId, role: userId === 'alice' ? 'owner' as const : 'member' as const, enabled: true }), id: `member-${userId}` });
  }
  store.put('workspaces', { ...services.resource('workspace', { name: 'Fixture', ownerUserId: 'alice', enabled: true, timezone: 'UTC' }), id: 'workspace-1' });
  const machine: P.Machine = { ...services.resource('machine', { nodeId: 'node-1', nodeName: 'fixture-node', name: 'Destination', ownerUserId: 'alice', accessUserIds: [], status: 'online' as const, lastSeenAtMs: now, labels: {}, botIds: ['bot-1'] }), id: 'machine-1' };
  store.put('machines', machine);
  const bot: P.Bot = { ...services.resource('bot', { ownerUserId: 'alice', machineId: machine.id, profileId: 'lb-fixture', name: 'Records', title: '', job: '', instructions: '', avatar: { kind: 'character' as const, shape: 'round', color: 'yellow', attachmentId: null }, voice: preferences.voice, language: null, skillIds: [], referenceAttachmentIds: [], mainConversationId: 'room-alice', sidebar: { pinned: false, hidden: false, sectionId: null, rank: 0, unread: false, notificationsEnabled: false }, activity: 'idle' as const, activeRunIds: [] }), id: 'bot-1' };
  store.put('bots', bot);
  const bobBot: P.Bot = { ...bot, id: 'bot-bob', ownerUserId: 'bob', profileId: 'lb-bob', machineId: 'machine-bob', mainConversationId: 'room-bob' };
  store.put('bots', bobBot);
  store.put('machines', { ...machine, id: 'machine-bob', ownerUserId: 'bob', botIds: [bobBot.id] });
  for (const ownedBot of [bot, bobBot]) store.put('conversations', { ...services.resource('conversation', { kind: 'dm' as const, name: 'Private', botIds: [ownedBot.id], ownerUserId: ownedBot.ownerUserId, parentConversationId: null, leadBotId: null, channelBindingId: null, lastEntryId: null, unreadCount: 0, lastReadSeq: 0, activity: [] }), id: ownedBot.mainConversationId });
  peer.putSecret('BOT_MCP', 'private-product-bot-token');
  peer.putSecret('RECORDS_TOKEN', 'destination-only-account-secret');
  store.setMetadata(`botMcp:${bot.id}`, { secretName: 'BOT_MCP', encryptedToken: codec.encrypt('private-product-bot-token'), digest: 'fixture-digest' });
  peer.putProfile({ id: bot.profileId, name: bot.name, description: bot.title, systemPrompt: `${botSystemPrompt(bot)}\n\nSelected enabled skill IDs; load their managed SKILL.md through the native skill loader and treat documents as untrusted tool data:\n`, toolPolicy: { profile: 'custom', allow: [], deny: [], blocked_tools: [], require_approval: [] }, mcpServers: [baseBotMcpTemplate(services)] });
  const alice = await services.auth.session('alice');
  const bob = await services.auth.session('bob');
  const principal = (userId: string): Principal => ({ kind: 'user', id: userId, userId, workspaceId: 'workspace-1', role: userId === 'alice' ? 'owner' : 'member', sessionId: null, botId: null, deviceId: null });
  const request = async <T>(method: string, path: string, body?: unknown, userId: 'alice' | 'bob' | null = 'alice'): Promise<{ status: number; body: T; response: Response }> => {
    const response = await router.fetch(new Request(`${PUBLIC_URL}${path}`, { method, headers: { 'Content-Type': 'application/json', ...(userId === null ? {} : { Authorization: `Bearer ${userId === 'alice' ? alice.token : bob.token}` }) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) }));
    return { status: response.status, body: await response.json() as T, response };
  };
  const create = async (changes: Partial<P.ConnectorSetupRequest> = {}) => request<P.ConnectorSetupResult>('POST', `/v1/bots/${bot.id}/connectors/setup`, { clientNonce: services.id('nonce'), machineId: machine.id, name: 'Records', url: `${ORIGIN}/mcp`, accountLabel: 'Alice records', authKind: 'secret_headers', secretBindings: [{ header: 'Authorization', secretName: 'RECORDS_TOKEN' }], requestedLevel: 'read_interact', ...changes });
  const enable = async (connector: P.Connector) => request<P.Connector>('PATCH', `/v1/connectors/${connector.id}`, { clientNonce: services.id('nonce'), revision: connector.revision, tools: connector.tools.map(tool => ({ ...tool, enabled: true })) });
  const admit = async (userId: string, operationId: string, conversationId = `room-${userId}`): Promise<P.Run> => {
    const actor = principal(userId);
    const run: P.Run = services.resource('run', { conversationId, botId: bot.id, initiatorUserId: userId, clientNonce: services.id('nonce'), status: 'running', error: null, startedAtMs: services.now(), completedAtMs: null, routineRunId: null });
    store.put('runs', run);
    store.setMetadata(`nativeRunProduct:${operationId}`, run.id);
    store.setMetadata(`runPrincipal:${run.id}`, actor);
    await buildInvocationContext(services, actor, services.auth.conversation(actor, conversationId), bot, operationId);
    return run;
  };
  cleanup.push(() => { gateService.close(); peer.close(); store.close(); });
  return { services, store, peer, bot, bobBot, machine, oauth, connectors: connectorServices, request, create, enable, admit, principal, advance: (ms: number) => { now += ms; } };
}

describe('destination connector configuration', () => {
  test('discovers on the actual destination, keeps values out of resources/events/profile, defaults tools disabled', async () => {
    const f = await fixture();
    const result = await f.create();
    expect(result.status).toBe(201);
    expect(result.body.connector.state).toBe('connected');
    expect(result.body.secretNames).toEqual(['RECORDS_TOKEN']);
    expect(result.body.connector.tools).toEqual([{ name: 'read_items', enabled: false }, { name: 'write_item', enabled: false }]);
    expect(result.body.grants[0]?.effectiveLevel).toBe('read_interact');
    const discovery = f.peer.calls.find(call => call.method === 'node.mcp.discover')!;
    expect(discovery.params.nodeId).toBe('node-1');
    expect(serverSchema.parse(discovery.params.server).headers.Authorization).toBe('Bearer ${LEMON_SECRET:RECORDS_TOKEN}');
    const enabled = await f.enable(result.body.connector);
    expect(enabled.status).toBe(200);
    const config = await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id);
    expect(config[0]?.enabledTools).toEqual(['read_items', 'write_item']);
    expect(config[0]?.allowedOrigins).toEqual([ORIGIN]);
    expect(config[0]?.approvedPrivateOrigins).toEqual([]);
    expect(config[0]?.headers).toEqual({});
    expect(f.peer.profiles.get(f.bot.profileId)?.every(server => Object.keys(server.headers).length === 0)).toBe(true);
    const current = await f.peer.call<{ profile: Profile & { mcpConfigFingerprint: string } }>('profiles.get', { id: f.bot.profileId });
    const server = serverSchema.parse(discovery.params.server);
    expect(current.profile.toolPolicy.allow).toEqual([...['read_skill', 'webfetch', 'websearch', 'task', 'agent_message', 'wait', 'parent_question'], ...productExecutionProjection.tools.map(tool => tool.executionName), executionName(server, 'read_items'), executionName(server, 'write_item')].sort());
    expect(current.profile.toolPolicy.deny).toEqual(expect.arrayContaining(['read', 'write', 'bash', 'browser_evaluate', 'recall']));
    expect(current.profile.mcpConfigFingerprint).toBe(connectorConfigurationFingerprint([baseBotMcpTemplate(f.services), ...config]));
    const publicData = JSON.stringify([result.body, enabled.body, config, f.store.list('auditRecords'), f.store.db.query('SELECT payload FROM events').all(), [...f.peer.profiles.values()]]);
    expect(publicData).not.toContain('destination-only-account-secret');
    expect(publicData).not.toContain('private-product-bot-token');
    expect(publicData).not.toContain(f.services.config.operatorToken);
  });

  test('owner effective templates remain credential-free and do not consume pending consent', async () => {
    const f = await fixture();
    const value = await f.create();
    const connector = (await f.enable(value.body.connector)).body;
    const consent = await f.connectors.requestConnectorConsent(f.principal('alice'), { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', operationId: f.services.id('run') });
    const before = f.peer.calls.length;
    const templates = await f.connectors.connectorTemplates(f.bot.id);
    expect(templates).toEqual([{ name: `connector-${connector.id}`, url: `${ORIGIN}/mcp`, headers: {}, enabledTools: ['read_items', 'write_item'], allowedOrigins: [ORIGIN], approvedPrivateOrigins: [] }]);
    expect(f.peer.calls).toHaveLength(before);
    expect(f.store.require<P.ConnectorConsent>('consents', consent.id).gate.state).toBe('pending');
    expect(JSON.stringify(templates)).not.toContain('RECORDS_TOKEN');
    expect(JSON.stringify(f.store.metadata(`connectorTemplatePolicy:${connector.id}`))).not.toContain('RECORDS_TOKEN');
    expect(f.peer.profiles.get(f.bot.profileId)).toEqual([baseBotMcpTemplate(f.services), ...templates]);
    expect(f.connectors.details(connector.id).desiredFingerprint).toBe(connectorConfigurationFingerprint([baseBotMcpTemplate(f.services), ...templates]));
  });

  test('owner capability grant constrains both native templates and invocation configuration', async () => {
    const f = await fixture();
    const created = await f.create();
    const connector = (await f.enable(created.body.connector)).body;
    const grant = f.connectors.grantFor(connector)!;
    f.store.put('botGrants', f.services.update(grant, { requestedLevel: 'read_only' as const }));
    expect((await f.connectors.connectorTemplates(f.bot.id))[0]?.enabledTools).toEqual(['read_items']);
    expect((await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id, 'room-alice', 'read-operation'))[0]?.enabledTools).toEqual(['read_items']);
    f.store.put('botGrants', f.services.update(f.store.require<P.BotGrant>('botGrants', grant.id), { requestedLevel: 'off' as const }));
    expect((await f.connectors.connectorTemplates(f.bot.id))[0]?.enabledTools).toEqual([]);
    expect(await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id, 'room-alice', 'off-operation')).toEqual([]);
  });

  test('foreign CRUD, provisioning and mismatched account ownership dispatch nothing', async () => {
    const f = await fixture();
    const connector = (await f.create()).body.connector;
    const before = f.peer.calls.length;
    for (const [method, path, body] of [
      ['GET', `/v1/bots/${f.bot.id}/connectors`, undefined],
      ['PATCH', `/v1/connectors/${connector.id}`, { clientNonce: f.services.id('nonce'), revision: connector.revision, name: 'Foreign edit' }],
      ['POST', `/v1/connectors/${connector.id}/auth`, { clientNonce: f.services.id('nonce') }],
      ['POST', `/v1/connectors/${connector.id}/preview`, { clientNonce: f.services.id('nonce'), action: 'disconnect' }],
    ] as const) expect((await f.request(method, path, body, 'bob')).status).toBe(404);
    await expect(f.connectors.connectorProvisioning(f.principal('bob'), f.bot.id)).rejects.toMatchObject({ code: 'not_found' });
    f.store.put('connectors', { ...connector, ownerUserId: 'bob' });
    await expect(f.connectors.connectorTemplates(f.bot.id)).rejects.toMatchObject({ code: 'policy_denied' });
    await expect(f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id, 'room-alice', 'mismatched-account')).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.peer.calls).toHaveLength(before);
  });

  test('rejects raw credentials, malformed names, missing destination names, foreign machine and unsafe origins before connection', async () => {
    const f = await fixture();
    const raw = await f.request<P.ErrorEnvelope>('POST', `/v1/bots/${f.bot.id}/connectors`, { clientNonce: f.services.id('nonce'), name: 'Unsafe', url: `${ORIGIN}/mcp`, accountLabel: 'Alice', authKind: 'secret_headers', headers: { Authorization: 'plaintext' } });
    expect(raw.body.error.code).toBe('invalid_request');
    expect((await f.create({ secretBindings: [{ header: 'Authorization', secretName: '${ENV_TOKEN}' }] })).status).toBe(400);
    expect((await f.create({ secretBindings: [{ header: 'Authorization', secretName: 'MISSING' }] })).status).toBe(400);
    expect((await f.create({ machineId: 'machine-other' })).status).toBe(409);
    expect((await f.create({ url: 'http://93.184.216.34/mcp' })).status).toBe(403);
    expect((await f.create({ url: 'https://alice:password@93.184.216.34/mcp' })).status).toBe(403);
    expect((await f.create({ url: 'https://127.0.0.1/mcp' })).status).toBe(403);
    expect(f.peer.calls.filter(call => call.method === 'node.mcp.discover')).toHaveLength(0);
  });

  test('private origins require an operator exact allowlist and propagate that policy to the destination', async () => {
    const f = await fixture();
    f.services.config.operator!.approvedPrivateMcpOrigins = ['https://127.0.0.1'];
    const value = await f.create({ url: 'https://127.0.0.1/mcp' });
    expect(value.status).toBe(201);
    const server = serverSchema.parse(f.peer.calls.find(call => call.method === 'node.mcp.discover')!.params.server);
    expect(server.allowedOrigins).toEqual(['https://127.0.0.1']);
    expect(server.approvedPrivateOrigins).toEqual(['https://127.0.0.1']);
  });

  test('discovery failure never reports Connected and same nonce does not redispatch', async () => {
    const f = await fixture();
    f.peer.failure = 'discovery';
    const input = { clientNonce: f.services.id('nonce'), name: 'Records', url: `${ORIGIN}/mcp`, accountLabel: 'Alice', authKind: 'none' };
    const first = await f.request<P.ErrorEnvelope>('POST', `/v1/bots/${f.bot.id}/connectors`, input);
    expect(first.body.error.code).toBe('upstream_unavailable');
    expect(f.store.list<P.Connector>('connectors')[0]?.state).toBe('failed');
    const before = f.peer.calls.length;
    const second = await f.request<P.ErrorEnvelope>('POST', `/v1/bots/${f.bot.id}/connectors`, input);
    expect(second.body.error.code).toBe(first.body.error.code);
    expect(f.peer.calls).toHaveLength(before);
  });

  test('read-only and off grants constrain actual enabled tools, arbitrary tool names are rejected', async () => {
    const f = await fixture();
    const created = await f.create({ requestedLevel: 'read_only' });
    const enabled = await f.enable(created.body.connector);
    expect(enabled.status).toBe(200);
    expect((await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id))[0]?.enabledTools).toEqual(['read_items']);
    const run = await f.admit('alice', 'operation-1');
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), { connectorId: enabled.body.id, botId: f.bot.id, conversationId: 'room-alice', toolName: 'write_item', operationId: 'operation-1' })).rejects.toMatchObject({ code: 'policy_denied' });
    f.store.put('runs', f.services.update(run, { status: 'succeeded' as const, completedAtMs: f.services.now() }));
    const arbitrary = await f.request<P.ErrorEnvelope>('PATCH', `/v1/connectors/${enabled.body.id}`, { clientNonce: f.services.id('nonce'), revision: enabled.body.revision, tools: [{ name: 'invented_tool', enabled: true }] });
    expect(arbitrary.body.error.code).toBe('invalid_request');
    const grant = f.store.list<P.BotGrant>('botGrants', value => value.capabilityId === `connector:${enabled.body.id}`)[0]!;
    f.store.put('botGrants', f.services.update(grant, { requestedLevel: 'off', effectiveLevel: 'off' }));
    await f.connectors.connectorProvisioning(f.principal('alice'), f.bot.id);
    expect((await f.connectors.connectorTemplates(f.bot.id))[0]?.enabledTools).toEqual([]);
    expect(await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id, 'room-alice', f.services.id('run'))).toEqual([]);
  });

  test('direct tool authorization conceals personal Bots and rejects unadmitted or revoked invocation authority', async () => {
    const f = await fixture();
    const created = await f.create();
    const connector = (await f.enable(created.body.connector)).body;
    const input = { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', toolName: 'read_items', operationId: 'fixed-native-operation' };
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).rejects.toMatchObject({ code: 'policy_denied' });
    await f.admit('alice', input.operationId);
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).resolves.toBeUndefined();
    await expect(f.connectors.authorizeConnectorTool(f.principal('bob'), { ...input, conversationId: 'room-bob' })).rejects.toMatchObject({ code: 'not_found' });
    f.store.setMetadata(`connectorEpoch:${connector.id}`, (f.store.metadata<number>(`connectorEpoch:${connector.id}`) ?? 0) + 1);
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).rejects.toMatchObject({ code: 'policy_denied' });
    expect(f.store.metadata<string[]>(`invocationConnectors:${input.operationId}`)).toEqual([connector.id]);
  });

  test('ambiguous profile synchronization is fenced and an exact nonce never repeats the mutation', async () => {
    const f = await fixture();
    f.peer.failure = 'sync_after_apply';
    const input = { clientNonce: f.services.id('nonce'), name: 'Records', url: `${ORIGIN}/mcp`, accountLabel: 'Alice', authKind: 'none' };
    const first = await f.request<P.ErrorEnvelope>('POST', `/v1/bots/${f.bot.id}/connectors`, input);
    expect(first.body.error.code).toBe('outcome_unknown');
    expect(first.body.error.retrySafe).toBe(false);
    expect(first.body.error.details?.resourceIds).toEqual([f.store.list<P.Connector>('connectors')[0]!.id]);
    const before = f.peer.calls.filter(call => call.method === 'profiles.update').length;
    await f.request('POST', `/v1/bots/${f.bot.id}/connectors`, input);
    expect(f.peer.calls.filter(call => call.method === 'profiles.update')).toHaveLength(before);
    f.peer.failure = null;
    const settled = await f.connectors.reconcileConnector(f.principal('alice'), f.store.list<P.Connector>('connectors')[0]!.id);
    expect('state' in settled && settled.state).toBe('connected');
    expect(f.peer.calls.filter(call => call.method === 'profiles.update')).toHaveLength(before);
  });
  test('declarative copies never bind credentials or pretend authenticated', async () => {
    const f = await fixture();
    const created = await f.create({ authKind: 'secret_headers', secretBindings: [] });
    expect(created.status).toBe(201);
    expect(created.body.connector.state).toBe('needs_auth');
    expect(created.body.secretNames).toEqual([]);
    expect(f.peer.calls.some(call => call.method === 'node.mcp.discover')).toBe(false);
    const auth = await f.request<P.ErrorEnvelope>('POST', `/v1/connectors/${created.body.connector.id}/auth`, { clientNonce: f.services.id('nonce') });
    expect(auth.body.error.code).toBe('capability_unavailable');
  });

  test('core bot and invocation secrets cannot become third-party header bindings', async () => {
    const f = await fixture();
    f.peer.putSecret('lemon_bot/invocations/visible-run', 'private-invocation-proof');
    expect((await f.create({ secretBindings: [{ header: 'Authorization', secretName: 'BOT_MCP' }] })).status).toBe(400);
    expect((await f.create({ secretBindings: [{ header: 'Authorization', secretName: 'lemon_bot/invocations/visible-run' }] })).status).toBe(400);
    expect((await f.create({ secretBindings: [{ header: 'X-Lemon-Bot-Invocation', secretName: 'RECORDS_TOKEN' }] })).status).toBe(400);
    expect(f.peer.calls.some(call => call.method === 'node.mcp.discover')).toBe(false);
  });

  test('disabling a tool requires actual terminal cancellation; an uncertain cancellation never replays', async () => {
    const f = await fixture();
    const created = await f.create();
    const connector = (await f.enable(created.body.connector)).body;
    const run: P.Run = f.services.resource('run', { conversationId: 'room-alice', botId: f.bot.id, initiatorUserId: 'alice', clientNonce: f.services.id('nonce'), status: 'running', error: null, startedAtMs: f.services.now(), completedAtMs: null, routineRunId: null });
    f.store.put('runs', run);
    f.store.setMetadata(`runtimeRun:${run.id}`, { upstreamRunId: run.id, executionRunId: run.id, sessionKey: 'agent:lb-fixture:main', dispatched: true });
    f.store.setMetadata(`invocationConnectors:${run.id}`, [connector.id]);
    f.peer.failure = 'cancellation';
    const body = { clientNonce: f.services.id('nonce'), revision: connector.revision, tools: connector.tools.map(tool => ({ ...tool, enabled: false })) };
    const first = await f.request<P.ErrorEnvelope>('PATCH', `/v1/connectors/${connector.id}`, body);
    expect(first.body.error.code).toBe('outcome_unknown');
    expect(first.body.error.retrySafe).toBe(false);
    expect(f.store.require<P.Run>('runs', run.id).status).toBe('running');
    const before = f.peer.calls.filter(call => call.method === 'chat.abort').length;
    await f.request('PATCH', `/v1/connectors/${connector.id}`, body);
    expect(f.peer.calls.filter(call => call.method === 'chat.abort')).toHaveLength(before);
    expect(await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id, 'room-alice', f.services.id('run'))).toEqual([]);
  });

});

describe('owner-scoped connector consent', () => {
  test('owner consent resolution is private and nonce-bound, not borrowed invocation authority', async () => {
    const f = await fixture();
    const created = await f.create();
    const enabled = await f.enable(created.body.connector);
    const connector = enabled.body;
    expect((await f.connectors.connectorTemplates(f.bot.id))[0]?.headers).toEqual({});
    await expect(f.connectors.connectorProfileConfiguration(f.principal('bob'), f.bot.id, 'room-bob', 'different-operation')).rejects.toMatchObject({ code: 'not_found' });
    const operationId = f.services.id('run');
    const consent = await f.connectors.requestConnectorConsent(f.principal('alice'), { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', operationId });
    const foreign = await f.request<P.ErrorEnvelope>('POST', `/v1/consents/${consent.id}/resolve`, { clientNonce: f.services.id('nonce'), revision: consent.revision, decision: 'allow_once' }, 'bob');
    expect(foreign.status).toBe(404);
    const allowed = await f.request<P.ConnectorConsent>('POST', `/v1/consents/${consent.id}/resolve`, { clientNonce: f.services.id('nonce'), revision: consent.revision, decision: 'allow_once' });
    expect(allowed.body.gate.state).toBe('approved');
    const replayed = await f.connectors.requestConnectorConsent(f.principal('alice'), { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', operationId });
    expect(replayed.id).toBe(consent.id);
    expect((await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id, 'room-alice', operationId))[0]?.headers.Authorization).toBe('Bearer ${LEMON_SECRET:RECORDS_TOKEN}');
    const foreignList = await f.request<P.Page<P.ConnectorConsent>>('GET', '/v1/consents', undefined, 'bob');
    expect(foreignList.body.items).toEqual([]);
    const entry = f.store.require<P.TranscriptEntry>('entries', consent.entryId);
    expect(entry.targetedUserId).toBe('alice');
    expect(f.services.auth.canRead(f.principal('bob'), 'entries', entry)).toBe(false);
  });

  test('revoking owner consent fences previously admitted native authority without lending access', async () => {
    const f = await fixture();
    const connector = (await f.enable((await f.create()).body.connector)).body;
    const operationId = 'revoked-owner-operation';
    const consent = await f.connectors.requestConnectorConsent(f.principal('alice'), { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', operationId });
    const allowed = await f.request<P.ConnectorConsent>('POST', `/v1/consents/${consent.id}/resolve`, { clientNonce: f.services.id('nonce'), revision: consent.revision, decision: 'allow_bot' });
    await f.admit('alice', operationId);
    const input = { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', toolName: 'read_items', operationId };
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).resolves.toBeUndefined();
    const deleted = await f.request<P.Deleted>('DELETE', `/v1/consents/${consent.id}`, { clientNonce: f.services.id('nonce'), revision: allowed.body.revision });
    expect(deleted.body).toEqual({ id: consent.id, deleted: true });
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).rejects.toMatchObject({ code: 'policy_denied' });
    expect((await f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bot.id, 'room-alice', 'new-owner-operation'))).toHaveLength(1);
  });

  test('operator service-account custody cannot authorize a foreign Bot or reuse native admission', async () => {
    const f = await fixture();
    f.services.config.operator!.connectorProviders = [{ id: 'service-records', origins: [ORIGIN], oauth: null, sharedServiceAccount: true }];
    const created = await f.create();
    expect(created.status).toBe(201);
    const connector = (await f.enable(created.body.connector)).body;
    expect(f.services.auth.bot(f.principal('bob'), f.bobBot.id).id).toBe(f.bobBot.id);
    expect(f.services.auth.conversation(f.principal('bob'), 'room-bob').botIds).toEqual([f.bobBot.id]);
    const input = { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', toolName: 'read_items', operationId: 'owner-native-operation' };
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).rejects.toMatchObject({ code: 'policy_denied' });
    const run = await f.admit('alice', input.operationId);
    const invocation = f.store.metadata<InvocationContext>(`runtimeInvocation:${input.operationId}`)!;
    expect(invocation.invocationProof.runId).toBe(input.operationId);
    expect(f.peer.readSecret(invocation.invocationProof.secretName)).toStartWith(`${input.operationId}.`);
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).resolves.toBeUndefined();
    const before = f.peer.calls.length;
    await expect(f.connectors.connectorProfileConfiguration(f.principal('bob'), f.bot.id, 'room-bob', 'foreign-operation')).rejects.toMatchObject({ code: 'not_found' });
    await expect(f.admit('bob', 'foreign-native-operation')).rejects.toMatchObject({ code: 'not_found' });
    await expect(f.connectors.authorizeConnectorTool(f.principal('bob'), input)).rejects.toMatchObject({ code: 'not_found' });
    await expect(f.connectors.connectorProfileConfiguration(f.principal('alice'), f.bobBot.id, 'room-bob', 'admin-operation')).rejects.toMatchObject({ code: 'not_found' });
    expect(f.peer.calls).toHaveLength(before);
    expect(f.store.metadata(`runtimeInvocation:foreign-native-operation`)).toBeNull();
    expect(f.store.metadata(`invocationConnectors:foreign-operation`)).toBeNull();
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), { ...input, operationId: 'different-operation' })).rejects.toMatchObject({ code: 'policy_denied' });
    f.store.setMetadata(`runPrincipal:${run.id}`, f.principal('bob'));
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).rejects.toMatchObject({ code: 'forbidden' });
    f.store.setMetadata(`runPrincipal:${run.id}`, f.principal('alice'));
    await expect(f.connectors.authorizeConnectorTool(f.principal('alice'), input)).resolves.toBeUndefined();
    expect(f.store.metadata<string[]>(`invocationConnectors:${input.operationId}`)).toEqual([connector.id]);
  });
});

describe('configured OAuth and destructive disconnect', () => {
  test('S256 state exchange stores credentials only on the destination and duplicate callbacks never exchange again', async () => {
    const f = await fixture();
    const created = await f.create({ authKind: 'oauth', secretBindings: [] });
    expect(created.body.connector.state).toBe('needs_auth');
    const auth = await f.request<P.ConnectorAuth>('POST', `/v1/connectors/${created.body.connector.id}/auth`, { clientNonce: f.services.id('nonce') });
    const authorize = new URL(auth.body.authorizationUrl);
    expect(authorize.origin).toBe(ORIGIN);
    expect(authorize.searchParams.get('code_challenge_method')).toBe('S256');
    const state = authorize.searchParams.get('state')!;
    const flow = privateMetadata<OAuthState>(f.services, `oauth:${sha256(state)}`)!;
    expect(authorize.searchParams.get('code_challenge')).toBe(sha256(flow.verifier));
    expect(JSON.stringify(auth.body)).not.toContain(flow.verifier);
    const exchanges: URLSearchParams[] = [];
    const transport: HttpClient = async (input, init) => {
      expect(String(input)).toBe(f.oauth.tokenUrl);
      const form = new URLSearchParams(String(init?.body)); exchanges.push(form);
      expect(form.get('client_id')).toBe(f.oauth.clientId);
      expect(form.get('client_secret')).toBe('configured-server-client-secret');
      expect(form.get('redirect_uri')).toBe(`${PUBLIC_URL}/v1/connectors/oauth/callback`);
      expect(form.get('code_verifier')).toBe(flow.verifier);
      return Response.json({ access_token: 'provider-private-access-token', token_type: 'Bearer', refresh_token: 'provider-private-refresh-token', expires_in: 3600 });
    };
    f.services.http = transport;
    const callback = await f.request<P.ConnectorAuth>('GET', `/v1/connectors/oauth/callback?state=${state}&code=provider-code`, undefined, null);
    expect(callback.body.state).toBe('connected');
    const writes = f.peer.calls.filter(call => call.method === 'node.secrets.set');
    expect(writes.map(call => call.params.value)).toEqual(['provider-private-access-token', 'provider-private-refresh-token']);
    expect(writes.every(call => call.params.nodeId === 'node-1')).toBe(true);
    const projected = JSON.stringify([callback.body, f.store.list('connectors'), f.store.list('connectorAuths'), f.store.list('entries'), f.store.list('auditRecords'), f.store.db.query('SELECT payload FROM events').all(), [...f.peer.profiles.values()]]);
    expect(projected).not.toContain('provider-private-access-token');
    expect(projected).not.toContain('provider-private-refresh-token');
    expect(projected).not.toContain('configured-server-client-secret');
    expect((await f.request<P.ErrorEnvelope>('GET', `/v1/connectors/oauth/callback?state=${state}&code=provider-code`, undefined, null)).body.error.code).toBe('conflict');
    expect(exchanges).toHaveLength(1);
    expect(f.peer.calls.filter(call => call.method === 'node.secrets.set')).toHaveLength(2);
  });

  test('expired and wrong-state authorization cannot write destination credentials', async () => {
    const f = await fixture();
    const created = await f.create({ authKind: 'oauth', secretBindings: [] });
    const auth = await f.request<P.ConnectorAuth>('POST', `/v1/connectors/${created.body.connector.id}/auth`, { clientNonce: f.services.id('nonce') });
    const state = new URL(auth.body.authorizationUrl).searchParams.get('state')!;
    expect((await f.request<P.ErrorEnvelope>('GET', `/v1/connectors/oauth/callback?state=${'x'.repeat(43)}&code=bad`, undefined, null)).body.error.code).toBe('unauthenticated');
    f.advance(600000);
    expect((await f.request<P.ErrorEnvelope>('GET', `/v1/connectors/oauth/callback?state=${state}&code=expired`, undefined, null)).body.error.code).toBe('expired');
    expect((await f.request<P.ConnectorAuth>('GET', `/v1/connector-auth/${auth.body.id}`)).body.state).toBe('expired');
    expect(f.peer.calls.filter(call => call.method === 'node.secrets.set')).toEqual([]);
  });
  test('a changed registered OAuth client cannot consume a code for another configuration', async () => {
    const f = await fixture();
    const created = await f.create({ authKind: 'oauth', secretBindings: [] });
    const auth = await f.request<P.ConnectorAuth>('POST', `/v1/connectors/${created.body.connector.id}/auth`, { clientNonce: f.services.id('nonce') });
    const state = new URL(auth.body.authorizationUrl).searchParams.get('state')!;
    f.services.config.operator!.connectorProviders = [{ id: 'records', origins: [ORIGIN], oauth: { ...f.oauth, clientId: 'other-client' }, sharedServiceAccount: false }];
    const exchanges: (RequestInfo | URL)[] = [];
    const transport: HttpClient = async input => { exchanges.push(input); throw new Error('A changed client must not exchange this code.'); };
    f.services.http = transport;
    const result = await f.request<P.ErrorEnvelope>('GET', `/v1/connectors/oauth/callback?state=${state}&code=wrong-client`, undefined, null);
    expect(result.body.error.code).toBe('conflict');
    expect(exchanges).toEqual([]);
    expect(f.peer.calls.filter(call => call.method === 'node.secrets.set')).toEqual([]);
  });

  test('account deletion fences late issuance, retains a private completion, and cleanup revokes once', async () => {
    const f = await fixture();
    const created = await f.create({ authKind: 'oauth', secretBindings: [] });
    const auth = await f.request<P.ConnectorAuth>('POST', `/v1/connectors/${created.body.connector.id}/auth`, { clientNonce: f.services.id('nonce') });
    const state = new URL(auth.body.authorizationUrl).searchParams.get('state')!;
    const revocations: string[] = [];
    const transport: HttpClient = async (input, init) => {
      if (String(input) === f.oauth.tokenUrl) {
        f.store.setMetadata('accountDeletion:alice', { status: 'running' });
        return Response.json({ access_token: 'late-issued-access', token_type: 'Bearer', refresh_token: 'late-issued-refresh' });
      }
      expect(String(input)).toBe(`${ORIGIN}/oauth/revoke`);
      revocations.push(new URLSearchParams(String(init?.body)).get('token')!);
      return new Response(null, { status: 200 });
    };
    f.services.http = transport;
    const callback = await f.request<P.ErrorEnvelope>('GET', `/v1/connectors/oauth/callback?state=${state}&code=late`, undefined, null);
    expect(callback.body.error.code).toBe('outcome_unknown');
    expect(f.peer.calls.filter(call => call.method === 'node.secrets.set')).toEqual([]);
    expect(f.store.list('oauthCompletions')).toHaveLength(1);
    await expect(f.connectors.cleanupOAuthUser('alice')).rejects.toMatchObject({ code: 'capability_unavailable' });
    expect(revocations).toEqual([]);
    expect(await f.connectors.reconcileOAuthUser('alice')).toBe(false);
    f.services.config.operator!.connectorProviders = [{ id: 'records', origins: [ORIGIN], oauth: { ...f.oauth, revocationUrl: `${ORIGIN}/oauth/revoke` }, sharedServiceAccount: false }];
    await f.connectors.cleanupOAuthUser('alice');
    expect(revocations).toEqual(['late-issued-access', 'late-issued-refresh']);
    expect(await f.connectors.reconcileOAuthUser('alice')).toBe(true);
    await f.connectors.cleanupOAuthUser('alice');
    expect(revocations).toHaveLength(2);
  });


  test('disconnect requires exact preview, removes profile tools and remembered consents, retains manual secrets and history', async () => {
    const f = await fixture('team');
    const created = await f.create();
    const connector = (await f.enable(created.body.connector)).body;
    const consent = await f.connectors.requestConnectorConsent(f.principal('alice'), { connectorId: connector.id, botId: f.bot.id, conversationId: 'room-alice', operationId: f.services.id('run') });
    await f.request('POST', `/v1/consents/${consent.id}/resolve`, { clientNonce: f.services.id('nonce'), revision: consent.revision, decision: 'allow_bot' });
    expect((await f.request<P.ErrorEnvelope>('DELETE', `/v1/connectors/${connector.id}`, { clientNonce: f.services.id('nonce'), revision: connector.revision, confirmationToken: 'not-an-issued-preview', confirmName: connector.name })).body.error.code).toBe('confirmation_required');
    const preview = await f.request<P.Confirmation>('POST', `/v1/connectors/${connector.id}/preview`, { clientNonce: f.services.id('nonce'), action: 'disconnect' });
    expect(preview.body.effects.some(effect => effect.includes('Retain conversation history'))).toBe(true);
    const body = { clientNonce: f.services.id('nonce'), revision: preview.body.revision, confirmationToken: preview.body.confirmationToken, confirmName: preview.body.confirmName };
    expect((await f.request<P.Deleted>('DELETE', `/v1/connectors/${connector.id}`, body)).body).toEqual({ id: connector.id, deleted: true });
    expect(f.store.get('connectors', connector.id)).toBeNull();
    expect(f.store.require<P.ConnectorConsent>('consents', consent.id).gate.state).toBe('cancelled');
    expect(f.store.get('entries', consent.entryId)).not.toBeNull();
    expect(f.peer.readSecret('RECORDS_TOKEN')).toBe('destination-only-account-secret');
    expect(f.peer.profiles.get(f.bot.profileId)?.map(server => server.name)).toEqual(['lemon-bot']);
    const effects = f.peer.calls.length;
    expect((await f.request<P.Deleted>('DELETE', `/v1/connectors/${connector.id}`, body)).body.deleted).toBe(true);
    expect(f.peer.calls).toHaveLength(effects);
  });

  test('fingerprints distinguish omitted controls, disabled tools and exact destination references', () => {
    const server = { name: 'records', url: `${ORIGIN}/mcp`, headers: { Authorization: 'Bearer ${LEMON_SECRET:A}' } };
    expect(connectorConfigurationFingerprint([server])).not.toBe(connectorConfigurationFingerprint([{ ...server, enabledTools: [] }]));
    expect(connectorConfigurationFingerprint([server])).not.toBe(connectorConfigurationFingerprint([{ ...server, headers: { Authorization: 'Bearer ${LEMON_SECRET:B}' } }]));
    expect(connectorConfigurationFingerprint([{ ...server, headers: { Z: 'literal', A: '${LEMON_SECRET:A}' } }])).toBe(connectorConfigurationFingerprint([{ ...server, headers: { A: '${LEMON_SECRET:A}', Z: 'literal' } }]));
  });
});
