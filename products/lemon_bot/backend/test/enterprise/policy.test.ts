import { afterEach, describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { composeEffectivePolicy, createPolicyServices, defaultGovernance, type PolicyCompositionInput } from '../../src/enterprise/policy';
import type { BackendServices, Principal } from '../../src/core/services';
import { closeFixture, fixture as ownerFixture } from '../integrations/channels-fixture';
const serviceFixtures: BackendServices[] = [];
afterEach(() => { for (const services of serviceFixtures.splice(0)) closeFixture(services); });
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
  const owner: Principal = { kind: 'user', id: 'u', userId: 'u', workspaceId: 'w', role: 'member', sessionId: null, deviceId: null, botId: null };
  const base = ownerFixture(undefined, owner), services = base.services;
  serviceFixtures.push(services);
  const bot: P.Bot = { ...base.bot, id: 'b', machineId: 'm' };
  services.store.put('bots', bot);
  services.store.setMetadata('policies', input.policies); services.store.setMetadata('governance', input.governance);
  for (const group of input.groups) services.store.put('directoryGroups', group);
  for (const policy of input.groupPolicies) services.store.put('groupPolicies', policy);
  const setRules = (rules: P.PolicyRule[]) => {
    for (const current of services.store.list<P.PolicyRule>('policyRules')) services.store.remove('policyRules', current.id);
    for (const rule of rules) services.store.put('policyRules', rule);
  };
  return { services, setRules, owner, bot };
}

test('owner bot policy retains personal choices and mandatory group rules', async () => {
  const f = serviceFixture();
  f.setRules([rule('personal', 'auto_review', { ownerUserId: 'u' }), rule('mandatory', 'ask_first', { required: true })]);
  const policy = await createPolicyServices(f.services).effectivePolicy(f.owner, 'b');
  expect(policy.userId).toBe('u');
  expect(policy.directoryGroupIds).toEqual(['g']);
  expect(policy.rules.find(item => item.category === 'shell')).toMatchObject({ id: 'mandatory', mode: 'ask_first', required: true });
  f.setRules([rule('personal', 'auto_review', { ownerUserId: 'u' })]);
  expect((await createPolicyServices(f.services).effectivePolicy(f.owner, 'b')).rules.find(item => item.category === 'shell')?.mode).toBe('auto_review');
});

test('legacy visibility and grants cannot authorize another actor bot policy, including administrators', async () => {
  const f = serviceFixture();
  // An adversarial legacy reader still cannot grant another actor policy authority.
  f.services.auth.bot = () => f.bot;
  for (const role of ['member', 'admin', 'owner'] as const) {
    const stranger = { ...f.owner, id: 'other', userId: 'other', role };
    await expect(createPolicyServices(f.services).effectivePolicy(stranger, 'b')).rejects.toMatchObject({ code: 'policy_denied' });
    await expect(createPolicyServices(f.services).requiredNetworkPolicies(stranger, 'b')).rejects.toMatchObject({ code: 'policy_denied' });
  }
});

test('workspace hardening projects only actual generic restrictions and excludes private owner policy', () => {
  const f = serviceFixture();
  const policies: P.Policies = { ...fixture().policies, allowedMcpOrigins: ['https://approved.example'], localExecutionCeiling: 'deny' };
  f.services.store.setMetadata('policies', policies);
  f.services.store.setMetadata('governance', { ...defaultGovernance, requireReview: false });
  f.setRules([
    rule('global', 'ask_first', { required: true }),
    rule('this-bot', 'auto_review', { botId: 'b', machineId: 'm' }),
    rule('other-bot', 'ask_first', { botId: 'other' }),
    rule('other-machine', 'ask_first', { machineId: 'other' }),
    rule('owner-private', 'ask_first', { ownerUserId: 'u' }),
    rule('foreign-private', 'ask_first', { ownerUserId: 'foreign' }),
  ]);
  const restrictions = createPolicyServices(f.services).workspaceRestrictions({ botId: 'b', machineId: 'm' });
  expect(restrictions.rules.map(rule => rule.id)).toEqual(['global', 'this-bot']);
  expect(restrictions.localExecutionCeiling).toBe('deny');
  expect(restrictions.allowedMcpOrigins).toEqual(['https://approved.example']);
  expect(restrictions.requireReview).toBe(false);
  expect(JSON.stringify(restrictions)).not.toContain('owner-private');
  expect(JSON.stringify(restrictions)).not.toContain('foreign-private');
  f.services.store.setMetadata('policies', null); f.services.store.setMetadata('governance', null);
  const defaults = createPolicyServices(f.services).workspaceRestrictions({ botId: 'b', machineId: 'm' });
  expect(defaults.localExecutionCeiling).toBe('ask'); expect(defaults.allowedMcpOrigins).toBeNull(); expect(defaults.requireReview).toBe(true);
});
