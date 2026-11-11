import { createHash } from 'node:crypto';
import { afterEach, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { refreshEffectivePolicy } from '../../src/enterprise/enforcement';
import { productBotTools } from '../../src/core/bots';
import { nativeFollowupAdmissionPath } from '../../src/runtime/admission';
import type { BackendServices, Principal } from '../../src/core/services';
import { closeFixture, fixture as ownerFixture } from '../integrations/channels-fixture';

const serviceFixtures: BackendServices[] = [];
afterEach(() => { for (const services of serviceFixtures.splice(0)) closeFixture(services); });

const projectedProductTools = productBotTools.map((name, index) => ({ name, executionName: `mcp_fixture_tool_${index}` }));
function projectionReply() { return { server: { name: 'lemon-bot' }, tools: projectedProductTools, count: projectedProductTools.length }; }

function mcpConfigFingerprint(servers: unknown): string {
  const definitions = Array.isArray(servers) ? servers : [];
  const canonical = definitions.map(server => {
    const entry = server as { name: string; url: string; headers: Record<string, string>; enabledTools?: string[]; allowedOrigins?: string[]; approvedPrivateOrigins?: string[] };
    return [entry.name, entry.url, Object.entries(entry.headers).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0), entry.enabledTools ?? null, entry.allowedOrigins ?? null, entry.approvedPrivateOrigins ?? null];
  });
  return createHash('sha256').update(JSON.stringify(canonical)).digest('hex');
}

function enforcementFixture() {
  const owner: Principal = { kind: 'user', id: 'alice', userId: 'alice', workspaceId: 'workspace', role: 'member', sessionId: 'session_alice', deviceId: null, botId: null };
  const base = ownerFixture(undefined, owner);
  const services = base.services;
  serviceFixtures.push(services);
  const bot = base.bot;
  const machine = services.store.require<P.Machine>('machines', bot.machineId);

  const measured: P.MachineCapabilities = { machineId: machine.id, os: 'linux', measuredAtMs: services.now(), stale: false, items: [{ id: 'files', name: 'Files', category: 'files', supported: true, configuredLevel: 'read_interact', osGrant: 'not_required', tools: ['read', 'write', 'edit', 'grep'], reason: 'Policy roots measured', measuredAtMs: services.now(), stale: false }] };

  services.lemon.connected = true;
  services.lemon.methods = ['nodes.list', 'node.capabilities.get', 'mcp.execution_names', 'profiles.update', 'profiles.sync'];
  const calls: string[] = [];
  services.lemon.call = async <T>(method: string, params: Record<string, unknown> = {}): Promise<T> => {
    calls.push(method);
    if (method === 'mcp.execution_names') return projectionReply() as T;
    if (method === 'nodes.list') return { nodes: [{ id: machine.nodeId, status: 'online', capabilities: ['node.capabilities.get'] }], summary: { presenceAvailable: true, truncated: false } } as T;
    if (method === 'node.capabilities.get') { const { machineId: _machineId, ...data } = measured; return { ...data, nodeId: machine.nodeId } as T; }
    if (method === 'profiles.update') return { profile: { ...params, canonicalSessionKey: `agent:${String(params.id)}:main`, mcpConfigFingerprint: mcpConfigFingerprint(params.mcpServers) } } as T;
    if (method === 'profiles.sync') return { profileId: params.id, nodeId: params.nodeId, mutationId: params.mutationId, acknowledged: true, revisionDigest: 'a'.repeat(64) } as T;
    throw new Error(`Unexpected RPC in enforcement fixture: ${method}`);
  };

  // The native follow-up admission issuer is already installed; this test exercises policy synchronization only.
  services.store.setMetadata(`nativeFollowupIssuerConfig:${bot.id}`, {
    botId: bot.id,
    profileId: bot.profileId,
    url: new URL(nativeFollowupAdmissionPath, services.config.publicUrl).toString(),
    digest: 'configured-digest',
    encryptedToken: services.encrypt('configured-token'),
    state: 'configured',
  });

  return { services, owner, bot, machine, calls };
}

function allowance(services: BackendServices, id: string, overrides: Partial<P.ApprovalAllowance> = {}): P.ApprovalAllowance {
  return {
    ...services.resource('allowance', {}),
    id,
    scope: 'chat',
    botId: 'bot',
    conversationId: 'room',
    ownerUserId: 'alice',
    toolGroups: ['terminal'],
    label: 'Terminal allowed in this chat',
    state: 'active',
    endedReason: null,
    endedAtMs: null,
    endedByUserId: null,
    sourceApprovalId: null,
    createdByUserId: 'alice',
    useCount: 0,
    lastUsedAtMs: null,
    ...overrides,
  };
}

test('acknowledged policy synchronization ends that bot active allowances with policy_changed', async () => {
  const f = enforcementFixture();
  f.services.store.put('approvalAllowances', allowance(f.services, 'allowance_synced', { botId: f.bot.id }));
  f.services.store.put('approvalAllowances', allowance(f.services, 'allowance_other_bot', { botId: 'another_bot' }));
  f.services.store.put('approvalAllowances', allowance(f.services, 'allowance_already_ended', { botId: f.bot.id, state: 'ended', endedReason: 'stopped', endedAtMs: 10, endedByUserId: 'alice' }));

  await refreshEffectivePolicy(f.services, f.owner, [f.bot.id]);

  expect(f.services.store.metadata(`botPolicySync:${f.bot.id}`)).toMatchObject({ state: 'acknowledged' });
  const ended = f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'allowance_synced');
  expect(ended.state).toBe('ended');
  expect(ended.endedReason).toBe('policy_changed');
  expect(ended.endedByUserId).toBe('alice');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'allowance_other_bot').state).toBe('active');
  // An already ended allowance keeps its original reason.
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'allowance_already_ended').endedReason).toBe('stopped');
});

test('unacknowledged policy synchronization leaves allowances active', async () => {
  const f = enforcementFixture();
  f.services.store.put('approvalAllowances', allowance(f.services, 'allowance_unconfirmed', { botId: f.bot.id }));
  f.services.lemon.call = async () => { throw new Error('Native receipt unavailable.'); };

  await expect(refreshEffectivePolicy(f.services, f.owner, [f.bot.id])).rejects.toMatchObject({ code: 'outcome_unknown' });

  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'allowance_unconfirmed').state).toBe('active');
});
