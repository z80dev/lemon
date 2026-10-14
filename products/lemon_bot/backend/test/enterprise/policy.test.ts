import { describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { composeEffectivePolicy, createPolicyServices, defaultGovernance, type PolicyCompositionInput } from '../../src/enterprise/policy';
import type { BackendServices, Principal } from '../../src/core/services';
const resource = { revision: 1, createdAtMs: 1, updatedAtMs: 1 };
const group: P.DirectoryGroup = { ...resource, id: 'g', name: 'Engineering', externalId: null, source: 'scim', memberUserIds: ['u'] };
const groupPolicy: P.GroupPolicy = { ...resource, id: 'gp', directoryGroupId: 'g', productAccess: true, capabilityModes: { shell: 'allow' }, requiredRuleIds: [], localExecutionCeiling: 'allow', allowEgress: true, allowSudo: true, networkPolicyId: null, reviewExempt: true };
function fixture(changes: Partial<PolicyCompositionInput> = {}): PolicyCompositionInput {
  return { userId: 'u', botId: 'b', machineId: 'm', workspaceEnabled: true, memberEnabled: true, governance: { ...defaultGovernance, allowSudo: true, allowEgress: true }, policies: { revision: 1, publicTemplates: false, allowedMcpOrigins: null, localExecutionCeiling: 'ask', actionRecording: false, auditRetentionDays: 90, rules: [] }, groups: [group], groupPolicies: [groupPolicy], rules: [], networkPolicies: [], ...changes };
}
function rule(id: string, mode: P.PolicyRule['mode'], overrides: Partial<P.PolicyRule> = {}): P.PolicyRule { return { ...resource, id, category: 'shell', mode, ownerUserId: null, botId: null, machineId: null, required: false, description: 'Test rule', ...overrides }; }
describe('effective policy composition', () => {
  test('eligible ordinary groups widen while hard workspace execution ceiling stays ask', () => {
    const policy = composeEffectivePolicy(fixture({ rules: [rule('ordinary', 'ask_first')] }));
    expect(policy.rules.find(rule => rule.category === 'shell')?.mode).toBe('allow');
    expect(policy.localExecutionCeiling).toBe('ask');
    expect(policy.allowEgress).toBe(true);
  });
  test('personal tighter choice and required ask_first defeat review exemption', () => {
    const personal = composeEffectivePolicy(fixture({ rules: [rule('mine', 'auto_review', { ownerUserId: 'u' })] }));
    expect(personal.rules.find(rule => rule.category === 'shell')?.mode).toBe('auto_review');
    const required = composeEffectivePolicy(fixture({ rules: [rule('required', 'ask_first', { required: true })] }));
    expect(required.rules.find(rule => rule.category === 'shell')?.mode).toBe('ask_first');
    expect(required.explanations.some(text => text.includes('required ask_first'))).toBe(true);
  });
  test('unrelated personal rules never influence another member', () => {
    const policy = composeEffectivePolicy(fixture({ rules: [rule('foreign', 'ask_first', { ownerUserId: 'another' })] }));
    expect(policy.rules.some(item => item.id === 'foreign')).toBe(false);
    expect(policy.rules.find(item => item.category === 'shell')?.mode).toBe('allow');
  });
  test('workspace disabled or SCIM inactive membership always refuses product access', () => {
    expect(composeEffectivePolicy(fixture({ workspaceEnabled: false })).productAccess).toBe(false);
    expect(composeEffectivePolicy(fixture({ memberEnabled: false })).productAccess).toBe(false);
    expect(composeEffectivePolicy(fixture({ governance: { ...defaultGovernance, groupAccess: 'selected', allowedDirectoryGroupIds: [] } })).productAccess).toBe(false);
  });
  test('workspace egress and sudo hard locks cannot be widened by groups', () => {
    const policy = composeEffectivePolicy(fixture({ governance: { ...defaultGovernance } }));
    expect(policy.allowSudo).toBe(false); expect(policy.allowEgress).toBe(false);
  });
  test('network hard lock and explicit group replacement retain all intersecting policies', () => {
    const network: P.NetworkPolicy = { ...resource, id: 'wn', scope: 'workspace', directoryGroupId: null, mode: 'allowlist_only', rules: [], requiredRuntimeDestinations: [] };
    const gn: P.NetworkPolicy = { ...network, id: 'gn', scope: 'directory_group', directoryGroupId: 'g' };
    const base = fixture({ groupPolicies: [{ ...groupPolicy, networkPolicyId: 'gn' }], networkPolicies: [network, gn] });
    expect(composeEffectivePolicy(base).networkPolicies.map(item => item.id)).toEqual(['wn']);
    expect(composeEffectivePolicy({ ...base, governance: { ...base.governance, lockNetworkForGroups: false } }).networkPolicies.map(item => item.id)).toEqual(['gn']);
  });
});

function serviceFixture() {
  const input = fixture();
  const bot = { id: 'b', ownerUserId: 'u', machineId: 'm' } as P.Bot;
  const rows: Record<string, unknown[]> = { directoryGroups: input.groups, groupPolicies: input.groupPolicies, policyRules: input.rules, networkPolicies: input.networkPolicies };
  const metadata: Record<string, unknown> = { workspaceId: 'w', policies: input.policies, governance: input.governance };
  const services = {
    store: {
      metadata: (key: string) => metadata[key] ?? null,
      get: (collection: string) => collection === 'workspaces' ? { enabled: true } : null,
      list: (collection: string) => rows[collection] ?? [],
    },
    // Deliberately permissive legacy authorization: policy must enforce ownership independently.
    auth: { bot: () => bot, member: () => ({ enabled: true }) },
  } as unknown as BackendServices;
  const owner: Principal = { kind: 'user', id: 'u', userId: 'u', workspaceId: 'w', role: 'member', sessionId: null, deviceId: null, botId: null };
  return { services, rows, owner };
}

test('owner bot policy retains personal choices and mandatory group rules', async () => {
  const f = serviceFixture();
  f.rows.policyRules = [rule('personal', 'auto_review', { ownerUserId: 'u' }), rule('mandatory', 'ask_first', { required: true })];
  const policy = await createPolicyServices(f.services).effectivePolicy(f.owner, 'b');
  expect(policy.userId).toBe('u');
  expect(policy.directoryGroupIds).toEqual(['g']);
  expect(policy.rules.find(item => item.category === 'shell')).toMatchObject({ id: 'mandatory', mode: 'ask_first', required: true });
  f.rows.policyRules = [rule('personal', 'auto_review', { ownerUserId: 'u' })];
  expect((await createPolicyServices(f.services).effectivePolicy(f.owner, 'b')).rules.find(item => item.category === 'shell')?.mode).toBe('auto_review');
});

test('legacy visibility and grants cannot authorize another actor bot policy, including administrators', async () => {
  const f = serviceFixture();
  for (const role of ['member', 'admin', 'owner'] as const) {
    const stranger = { ...f.owner, id: 'other', userId: 'other', role };
    await expect(createPolicyServices(f.services).effectivePolicy(stranger, 'b')).rejects.toMatchObject({ code: 'policy_denied' });
    await expect(createPolicyServices(f.services).requiredNetworkPolicies(stranger, 'b')).rejects.toMatchObject({ code: 'policy_denied' });
  }
});
