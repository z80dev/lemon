import { afterEach, describe, expect, test } from 'bun:test';
import type * as P from '../../../contracts/protocol';
import { composeEffectivePolicy, createPolicyRoutes, createPolicyServices, defaultGovernance, type PolicyCompositionInput } from '../../src/enterprise/policy';
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
  test('folder read policy separates explicit files restrictions from synthetic requireReview', () => {
    const cases: { name: string; changes: Partial<PolicyCompositionInput>; expected: P.EffectivePolicy['workspaceReads'] }[] = [
      { name: 'default', changes: {}, expected: 'allow' },
      { name: 'synthetic review', changes: { groupPolicies: [{ ...groupPolicy, reviewExempt: false }] }, expected: 'allow' },
      { name: 'folder governance', changes: { governance: { ...defaultGovernance, folderReadsNeedReview: true } }, expected: 'ask' },
      { name: 'execution denied', changes: { policies: { ...fixture().policies, localExecutionCeiling: 'deny' } }, expected: 'ask' },
      { name: 'required explicit', changes: { rules: [rule('files', 'ask_first', { category: 'files', required: true })] }, expected: 'ask' },
      { name: 'personal explicit', changes: { rules: [rule('files', 'ask_first', { category: 'files', ownerUserId: 'u' })] }, expected: 'ask' },
      { name: 'group required ID', changes: { groupPolicies: [{ ...groupPolicy, requiredRuleIds: ['files'] }], rules: [rule('files', 'ask_first', { category: 'files' })] }, expected: 'ask' },
      { name: 'ordinary workspace rule', changes: { rules: [rule('files', 'ask_first', { category: 'files' })] }, expected: 'allow' },
      { name: 'foreign personal rule', changes: { rules: [rule('files', 'ask_first', { category: 'files', ownerUserId: 'other' })] }, expected: 'allow' },
      { name: 'different Bot', changes: { rules: [rule('files', 'ask_first', { category: 'files', required: true, botId: 'other' })] }, expected: 'allow' },
      { name: 'different machine', changes: { rules: [rule('files', 'ask_first', { category: 'files', required: true, machineId: 'other' })] }, expected: 'allow' },
      { name: 'required auto review', changes: { rules: [rule('files', 'auto_review', { category: 'files', required: true })] }, expected: 'allow' },
      { name: 'shell rule', changes: { rules: [rule('shell', 'ask_first', { required: true })] }, expected: 'allow' },
      { name: 'denied group does not require', changes: { groupPolicies: [{ ...groupPolicy, productAccess: false, requiredRuleIds: ['files'] }], rules: [rule('files', 'ask_first', { category: 'files' })] }, expected: 'allow' },
    ];
    for (const value of cases) expect({ name: value.name, workspaceReads: composeEffectivePolicy(fixture(value.changes)).workspaceReads }).toEqual({ name: value.name, workspaceReads: value.expected });
  });
  test('remembered approvals matrix: default allows chat for shell and files, bot empty', () => {
    const policy = composeEffectivePolicy(fixture());
    expect(policy.rememberedApprovals).toEqual({ chat: ['shell', 'files'], bot: [] });
  });
  test('remembered approvals matrix: chat_and_bot governance includes shell and files in both', () => {
    const policy = composeEffectivePolicy(fixture({ governance: { ...defaultGovernance, rememberedApprovals: 'chat_and_bot' } }));
    expect(policy.rememberedApprovals).toEqual({ chat: ['shell', 'files'], bot: ['shell', 'files'] });
  });
  test('remembered approvals matrix: required ask_first shell rule removes shell from both chat and bot', () => {
    const chatOnly = composeEffectivePolicy(fixture({ rules: [rule('req-shell', 'ask_first', { required: true })] }));
    expect(chatOnly.rememberedApprovals).toEqual({ chat: ['files'], bot: [] });
    const chatAndBot = composeEffectivePolicy(fixture({
      governance: { ...defaultGovernance, rememberedApprovals: 'chat_and_bot' },
      rules: [rule('req-shell', 'ask_first', { required: true })],
    }));
    expect(chatAndBot.rememberedApprovals).toEqual({ chat: ['files'], bot: ['files'] });
  });
  test('remembered approvals matrix: personal ask_first shell rule removes shell from both chat and bot', () => {
    const chatOnly = composeEffectivePolicy(fixture({ rules: [rule('my-shell', 'ask_first', { ownerUserId: 'u' })] }));
    expect(chatOnly.rememberedApprovals).toEqual({ chat: ['files'], bot: [] });
    const chatAndBot = composeEffectivePolicy(fixture({
      governance: { ...defaultGovernance, rememberedApprovals: 'chat_and_bot' },
      rules: [rule('my-shell', 'ask_first', { ownerUserId: 'u' })],
    }));
    expect(chatAndBot.rememberedApprovals).toEqual({ chat: ['files'], bot: ['files'] });
  });
  test('remembered approvals matrix: review-forced rule (from requireReview: true) does not remove shell or files', () => {
    const policy = composeEffectivePolicy(fixture({
      governance: { ...defaultGovernance, requireReview: true, rememberedApprovals: 'chat_and_bot' },
      groupPolicies: [{ ...groupPolicy, reviewExempt: false }],
    }));
    expect(policy.rules.find(r => r.category === 'shell')?.mode).toBe('ask_first');
    expect(policy.rules.find(r => r.category === 'shell')?.required).toBe(true);
    expect(policy.rememberedApprovals).toEqual({ chat: ['shell', 'files'], bot: ['shell', 'files'] });
  });
  test('remembered approvals matrix: localExecutionCeiling deny, no product access, or governance off yield empty lists', () => {
    expect(composeEffectivePolicy(fixture({ policies: { ...fixture().policies, localExecutionCeiling: 'deny' } })).rememberedApprovals).toEqual({ chat: [], bot: [] });
    expect(composeEffectivePolicy(fixture({ workspaceEnabled: false })).rememberedApprovals).toEqual({ chat: [], bot: [] });
    expect(composeEffectivePolicy(fixture({ memberEnabled: false })).rememberedApprovals).toEqual({ chat: [], bot: [] });
    expect(composeEffectivePolicy(fixture({ governance: { ...defaultGovernance, rememberedApprovals: 'off' } })).rememberedApprovals).toEqual({ chat: [], bot: [] });
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
  expect(restrictions.folderReadsNeedReview).toBe(false);
  f.services.store.setMetadata('governance', { ...defaultGovernance, folderReadsNeedReview: true });
  expect(createPolicyServices(f.services).workspaceRestrictions({ botId: 'b', machineId: 'm' }).folderReadsNeedReview).toBe(true);
  expect(JSON.stringify(restrictions)).not.toContain('owner-private');
  expect(JSON.stringify(restrictions)).not.toContain('foreign-private');
  f.services.store.setMetadata('policies', null); f.services.store.setMetadata('governance', null);
  const defaults = createPolicyServices(f.services).workspaceRestrictions({ botId: 'b', machineId: 'm' });
  expect(defaults.localExecutionCeiling).toBe('ask'); expect(defaults.allowedMcpOrigins).toBeNull(); expect(defaults.requireReview).toBe(true);
});

test('stored governance without rememberedApprovals field reads back as chat', async () => {
  const f = serviceFixture();
  const legacyGovernance = { revision: 1, groupAccess: 'all' as const, allowedDirectoryGroupIds: [], allowSudo: false, allowEgress: false, lockNetworkForGroups: true, requireReview: true, allowedChannelAdapters: [], xMentionsEnabled: false, emailEnabled: false, contentExportEnabled: false, inactiveHostPolicy: { enabled: false, afterDays: 30, action: 'suspend' as const } };
  f.services.store.setMetadata('governance', legacyGovernance);
  const services = createPolicyServices(f.services);
  expect(services.governance().rememberedApprovals).toBe('chat');
  expect(services.governance().folderReadsNeedReview).toBe(false);
  const effective = await services.effectivePolicy(f.owner, f.bot.id);
  expect(effective.rememberedApprovals).toEqual({ chat: ['shell', 'files'], bot: [] });
});

test('folder read governance updates persist and notify policy enforcement', async () => {
  const f = serviceFixture();
  const changes: P.Governance[] = [];
  const route = createPolicyRoutes(f.services, { governanceChanged: async (_previous, next) => { changes.push(next); } }).find(route => route.method === 'PATCH' && route.path === '/v1/governance')!;
  const result = await route.handler({
    services: f.services, request: new Request('http://localhost/v1/governance', { method: 'PATCH' }), params: {}, query: new URLSearchParams(),
    body: { clientNonce: 'folder_review_nonce_0001', revision: 1, folderReadsNeedReview: true }, user: { ...f.owner, role: 'admin' }, requestId: 'req_folder', route, nonceResourceIds: [],
  }) as P.Governance;
  expect(result.folderReadsNeedReview).toBe(true);
  expect(changes).toEqual([result]);
  expect((await createPolicyServices(f.services).effectivePolicy(f.owner, f.bot.id)).workspaceReads).toBe('ask');
});

function makeAllowance(services: BackendServices, id: string, overrides: Partial<P.ApprovalAllowance> = {}): P.ApprovalAllowance {
  return {
    id,
    revision: 1,
    createdAtMs: 1,
    updatedAtMs: 1,
    scope: 'chat',
    botId: 'b',
    conversationId: 'c',
    ownerUserId: 'u',
    toolGroups: ['terminal'],
    label: 'Allow Terminal for this chat',
    state: 'active',
    endedReason: null,
    endedAtMs: null,
    endedByUserId: null,
    sourceApprovalId: null,
    createdByUserId: 'u',
    useCount: 0,
    lastUsedAtMs: null,
    ...overrides,
  };
}

test('PATCH /v1/governance invalidation: setting to off ends all allowances, setting to chat ends bot scope', async () => {
  const f = serviceFixture();
  const admin: Principal = { kind: 'user', id: 'admin', userId: 'admin', workspaceId: 'w', role: 'admin', sessionId: 's', deviceId: null, botId: null };
  const chatAllowance = makeAllowance(f.services, 'alw_chat', { scope: 'chat', botId: f.bot.id, conversationId: 'c1', ownerUserId: 'u' });
  const botAllowance = makeAllowance(f.services, 'alw_bot', { scope: 'bot', botId: f.bot.id, conversationId: null, ownerUserId: 'u' });
  f.services.store.put('approvalAllowances', chatAllowance);
  f.services.store.put('approvalAllowances', botAllowance);

  f.services.store.setMetadata('governance', { ...defaultGovernance, revision: 1, rememberedApprovals: 'chat_and_bot' });
  const routes = createPolicyRoutes(f.services);
  const patchGov = routes.find(r => r.method === 'PATCH' && r.path === '/v1/governance')!;

  await patchGov.handler({
    request: new Request('http://localhost/v1/governance', { method: 'PATCH' }),
    params: {},
    query: new URLSearchParams(),
    body: { clientNonce: 'nonce1234567890123456', revision: 1, rememberedApprovals: 'chat' },
    user: admin,
    services: f.services,
    requestId: 'req_1',
    route: patchGov,
    nonceResourceIds: [],
  });

  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_bot').state).toBe('ended');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_bot').endedReason).toBe('policy_changed');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_chat').state).toBe('active');

  const currentGov = f.services.store.metadata<P.Governance>('governance')!;
  await patchGov.handler({
    request: new Request('http://localhost/v1/governance', { method: 'PATCH' }),
    params: {},
    query: new URLSearchParams(),
    body: { clientNonce: 'nonce2234567890123456', revision: currentGov.revision, rememberedApprovals: 'off' },
    user: admin,
    services: f.services,
    requestId: 'req_2',
    route: patchGov,
    nonceResourceIds: [],
  });

  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_chat').state).toBe('ended');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_chat').endedReason).toBe('policy_changed');
});
test('PATCH /v1/governance invalidation: changing other fields ends all allowances even if chat is enabled', async () => {
  const f = serviceFixture();
  const admin: Principal = { kind: 'user', id: 'admin', userId: 'admin', workspaceId: 'w', role: 'admin', sessionId: 's', deviceId: null, botId: null };
  const chatAllowance = makeAllowance(f.services, 'alw_chat_other', { scope: 'chat', botId: f.bot.id, conversationId: 'c1', ownerUserId: 'u' });
  f.services.store.put('approvalAllowances', chatAllowance);

  f.services.store.setMetadata('governance', { ...defaultGovernance, revision: 1, rememberedApprovals: 'chat' });
  const routes = createPolicyRoutes(f.services);
  const patchGov = routes.find(r => r.method === 'PATCH' && r.path === '/v1/governance')!;

  // Changing requireReview (a field other than rememberedApprovals) ends all allowances
  await patchGov.handler({
    request: new Request('http://localhost/v1/governance', { method: 'PATCH' }),
    params: {},
    query: new URLSearchParams(),
    body: { clientNonce: 'nonceother1234567890', revision: 1, requireReview: false },
    user: admin,
    services: f.services,
    requestId: 'req_other',
    route: patchGov,
    nonceResourceIds: [],
  });

  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_chat_other').state).toBe('ended');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_chat_other').endedReason).toBe('policy_changed');
});


test('PATCH /v1/directory/groups/:id/policy invalidation: ends allowances of group members with policy_changed', async () => {
  const f = serviceFixture();
  const admin: Principal = { kind: 'user', id: 'admin', userId: 'admin', workspaceId: 'w', role: 'admin', sessionId: 's', deviceId: null, botId: null };
  const memberAllowance = makeAllowance(f.services, 'alw_member', { ownerUserId: 'u', botId: f.bot.id });
  const otherAllowance = makeAllowance(f.services, 'alw_other', { ownerUserId: 'other_user', botId: f.bot.id });
  f.services.store.put('approvalAllowances', memberAllowance);
  f.services.store.put('approvalAllowances', otherAllowance);

  const routes = createPolicyRoutes(f.services);
  const patchGroupPolicy = routes.find(r => r.method === 'PATCH' && r.path === '/v1/directory/groups/:id/policy')!;
  const currentGp = f.services.store.list<P.GroupPolicy>('groupPolicies', p => p.directoryGroupId === 'g')[0];

  await patchGroupPolicy.handler({
    request: new Request('http://localhost/v1/directory/groups/g/policy', { method: 'PATCH' }),
    params: { id: 'g' },
    query: new URLSearchParams(),
    body: { clientNonce: 'nonce3234567890123456', revision: currentGp.revision, localExecutionCeiling: 'ask' },
    user: admin,
    services: f.services,
    requestId: 'req_3',
    route: patchGroupPolicy,
    nonceResourceIds: [],
  });

  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_member').state).toBe('ended');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_member').endedReason).toBe('policy_changed');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_other').state).toBe('active');
});

test('PATCH /v1/directory/groups/:id invalidation: membership changes end allowances of affected users only', async () => {
  const f = serviceFixture();
  const admin: Principal = { kind: 'user', id: 'admin', userId: 'admin', workspaceId: 'w', role: 'admin', sessionId: 's', deviceId: null, botId: null };
  // Group 'g' is locally sourced with members ['u', 'bob']; 'carol' is an existing workspace member.
  const existing = f.services.store.list<P.Member>('members')[0]!;
  for (const userId of ['bob', 'carol']) f.services.store.put('members', { ...existing, id: userId, userId, email: `${userId}@example.org`, displayName: userId });
  const localGroup: P.DirectoryGroup = { id: 'g', revision: 1, createdAtMs: 1, updatedAtMs: 1, name: 'Local Group', source: 'local', externalId: null, memberUserIds: ['u', 'bob'] };
  f.services.store.put('directoryGroups', localGroup);

  const memberU = makeAllowance(f.services, 'alw_u', { ownerUserId: 'u' });
  const memberBob = makeAllowance(f.services, 'alw_bob', { ownerUserId: 'bob' });
  const memberCarol = makeAllowance(f.services, 'alw_carol', { ownerUserId: 'carol' });
  f.services.store.put('approvalAllowances', memberU);
  f.services.store.put('approvalAllowances', memberBob);
  f.services.store.put('approvalAllowances', memberCarol);

  const routes = createPolicyRoutes(f.services);
  const patchGroup = routes.find(r => r.method === 'PATCH' && r.path === '/v1/directory/groups/:id')!;

  // Update group members: keep 'u', remove 'bob', add 'carol'
  await patchGroup.handler({
    request: new Request('http://localhost/v1/directory/groups/g', { method: 'PATCH' }),
    params: { id: 'g' },
    query: new URLSearchParams(),
    body: { clientNonce: 'noncedir123456789012', revision: 1, memberUserIds: ['u', 'carol'] },
    user: admin,
    services: f.services,
    requestId: 'req_dir_patch',
    route: patchGroup,
    nonceResourceIds: [],
  });

  // 'bob' was removed -> ended
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_bob').state).toBe('ended');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_bob').endedReason).toBe('membership_changed');
  // 'carol' was added -> ended
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_carol').state).toBe('ended');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_carol').endedReason).toBe('membership_changed');
  // 'u' stayed unchanged -> active
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_u').state).toBe('active');
});

test('DELETE /v1/directory/groups/:id invalidation: ends allowances of all group members with membership_changed', async () => {
  const f = serviceFixture();
  const admin: Principal = { kind: 'user', id: 'admin', userId: 'admin', workspaceId: 'w', role: 'admin', sessionId: 's', deviceId: null, botId: null };
  const localGroup: P.DirectoryGroup = { id: 'g_del', revision: 1, createdAtMs: 1, updatedAtMs: 1, name: 'To Delete', source: 'local', externalId: null, memberUserIds: ['u'] };
  f.services.store.put('directoryGroups', localGroup);

  const memberAllowance = makeAllowance(f.services, 'alw_del_u', { ownerUserId: 'u' });
  const otherAllowance = makeAllowance(f.services, 'alw_del_other', { ownerUserId: 'other_del' });
  f.services.store.put('approvalAllowances', memberAllowance);
  f.services.store.put('approvalAllowances', otherAllowance);

  const routes = createPolicyRoutes(f.services);
  const deleteGroup = routes.find(r => r.method === 'DELETE' && r.path === '/v1/directory/groups/:id')!;

  await deleteGroup.handler({
    request: new Request('http://localhost/v1/directory/groups/g_del', { method: 'DELETE' }),
    params: { id: 'g_del' },
    query: new URLSearchParams(),
    body: { clientNonce: 'noncedel123456789012', revision: 1 },
    user: admin,
    services: f.services,
    requestId: 'req_del',
    route: deleteGroup,
    nonceResourceIds: [],
  });

  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_del_u').state).toBe('ended');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_del_u').endedReason).toBe('membership_changed');
  expect(f.services.store.require<P.ApprovalAllowance>('approvalAllowances', 'alw_del_other').state).toBe('active');
});
