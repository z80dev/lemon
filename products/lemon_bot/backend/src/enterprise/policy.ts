import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, Route } from '../core/services';
import { ApiError } from '../core/errors';
import { principal, userPrincipal } from '../integrations/common';

export const defaultGovernance: P.Governance = { revision: 1, groupAccess: 'all', allowedDirectoryGroupIds: [], allowSudo: false, allowEgress: false, lockNetworkForGroups: true, requireReview: true, allowedChannelAdapters: [], xMentionsEnabled: false, emailEnabled: false, contentExportEnabled: false, inactiveHostPolicy: { enabled: false, afterDays: 30, action: 'suspend' } };
const categories = ['shell', 'files', 'external_message', 'calendar', 'publish', 'purchase', 'permissions', 'connector', 'handoff'] as const;
const category = z.enum(categories); const mode = z.enum(['ask_first', 'auto_review', 'allow']);
const id = z.string().min(1).max(256); const nonce = z.string().regex(/^[A-Za-z0-9_-]{16,128}$/); const update = { clientNonce: nonce, revision: z.number().int().positive() };
const ids = z.array(id).max(1000).refine(values => new Set(values).size === values.length, 'Duplicate IDs are not allowed');
const createGroup = z.object({ clientNonce: nonce, name: z.string().min(1).max(120), memberUserIds: ids }).strict();
const patchGroup = z.object({ ...update, name: z.string().min(1).max(120).optional(), memberUserIds: ids.optional() }).strict();
const patchPolicy = z.object({ ...update, productAccess: z.boolean().optional(), defaultBotIds: ids.optional(), capabilityModes: z.partialRecord(category, mode).optional(), requiredRuleIds: ids.optional(), localExecutionCeiling: z.enum(['deny', 'ask', 'allow']).optional(), allowEgress: z.boolean().optional(), allowSudo: z.boolean().optional(), networkPolicyId: id.nullable().optional(), reviewExempt: z.boolean().optional() }).strict();
const patchGovernance = z.object({ ...update, groupAccess: z.enum(['all', 'selected']).optional(), allowedDirectoryGroupIds: ids.optional(), allowSudo: z.boolean().optional(), allowEgress: z.boolean().optional(), lockNetworkForGroups: z.boolean().optional(), requireReview: z.boolean().optional(), allowedChannelAdapters: z.array(z.enum(['email', 'slack', 'telegram', 'discord', 'whatsapp'])).optional(), xMentionsEnabled: z.boolean().optional(), emailEnabled: z.boolean().optional(), contentExportEnabled: z.boolean().optional(), inactiveHostPolicy: z.object({ enabled: z.boolean(), afterDays: z.number().int().min(1).max(3650), action: z.enum(['suspend', 'stop_worker']) }).strict().optional() }).strict();
const revision = z.object(update).strict();
const ceilingRank: Record<P.GroupPolicy['localExecutionCeiling'], number> = { deny: 0, ask: 1, allow: 2 };
const modeRank: Record<P.PolicyRule['mode'], number> = { ask_first: 0, auto_review: 1, allow: 2 };
export interface PolicyCompositionInput { userId: string; botId: string | null; machineId: string | null; workspaceEnabled: boolean; memberEnabled: boolean; governance: P.Governance; policies: P.Policies; groups: P.DirectoryGroup[]; groupPolicies: P.GroupPolicy[]; rules: P.PolicyRule[]; networkPolicies: P.NetworkPolicy[] }
function directoryAccess(workspaceEnabled: boolean, memberEnabled: boolean, governance: P.Governance, grants: P.GroupPolicy[]): boolean {
  return workspaceEnabled && memberEnabled && (governance.groupAccess === 'all' ? grants.length === 0 || grants.some(policy => policy.productAccess) : grants.some(policy => policy.productAccess));
}
/** Live synchronous access guard for existing sockets/resources; uses the same composition as admission. */
export function hasProductAccess(services: BackendServices, userId: string): boolean {
  const workspaceId = services.store.metadata<string>('workspaceId');
  const workspace = workspaceId ? services.store.get<P.Workspace>('workspaces', workspaceId) : null;
  const member = services.store.list<P.Member>('members', member => member.userId === userId)[0];
  const governance = services.store.metadata<P.Governance>('governance') ?? defaultGovernance;
  const eligible = services.store.list<P.DirectoryGroup>('directoryGroups', group => group.memberUserIds.includes(userId) && (governance.groupAccess === 'all' || governance.allowedDirectoryGroupIds.includes(group.id)));
  const grants = services.store.list<P.GroupPolicy>('groupPolicies', policy => eligible.some(group => group.id === policy.directoryGroupId));
  return directoryAccess(workspace?.enabled ?? false, member?.enabled ?? false, governance, grants);
}
/** Group grants widen ordinary capabilities; locked ceilings and personal restrictions only tighten. */
export function composeEffectivePolicy(input: PolicyCompositionInput): P.EffectivePolicy {
  const ownGroups = input.groups.filter(group => group.memberUserIds.includes(input.userId));
  const eligible = ownGroups.filter(group => input.governance.groupAccess === 'all' || input.governance.allowedDirectoryGroupIds.includes(group.id));
  const grants = eligible.map(group => input.groupPolicies.find(policy => policy.directoryGroupId === group.id)).filter((value): value is P.GroupPolicy => !!value);
  const explanations = ['Workspace and enabled membership are required.', 'Product authorization does not isolate shared host files or OS credentials.'];
  const productAccess = directoryAccess(input.workspaceEnabled, input.memberEnabled, input.governance, grants);
  const activeGrants = grants.filter(policy => policy.productAccess);
  const groupCeiling = activeGrants.reduce<P.GroupPolicy['localExecutionCeiling']>((value, policy) => ceilingRank[policy.localExecutionCeiling] > ceilingRank[value] ? policy.localExecutionCeiling : value, activeGrants.length ? 'deny' : input.policies.localExecutionCeiling);
  const localExecutionCeiling = ceilingRank[groupCeiling] < ceilingRank[input.policies.localExecutionCeiling] ? groupCeiling : input.policies.localExecutionCeiling;
  const requiredIds = new Set(activeGrants.flatMap(policy => policy.requiredRuleIds));
  const applicable = input.rules.filter(rule => (rule.botId === null || rule.botId === input.botId) && (rule.machineId === null || rule.machineId === input.machineId) && (rule.ownerUserId === null || rule.ownerUserId === input.userId));
  const rules: P.PolicyRule[] = [];
  for (const action of categories) {
    const candidates = applicable.filter(rule => rule.category === action); const required = candidates.filter(rule => rule.required || requiredIds.has(rule.id));
    const personal = candidates.filter(rule => rule.ownerUserId === input.userId);
    const groupModes = activeGrants.map(policy => policy.capabilityModes[action]).filter((value): value is P.PolicyRule['mode'] => value !== undefined);
    let chosenMode: P.PolicyRule['mode'] = groupModes.reduce<P.PolicyRule['mode']>((value, item) => modeRank[item] > modeRank[value] ? item : value, groupModes.length ? 'ask_first' : 'allow');
    if (!groupModes.length) for (const rule of candidates.filter(rule => rule.ownerUserId === null && !requiredIds.has(rule.id) && !rule.required)) if (modeRank[rule.mode] < modeRank[chosenMode]) chosenMode = rule.mode;
    for (const rule of personal) if (modeRank[rule.mode] < modeRank[chosenMode]) chosenMode = rule.mode;
    for (const rule of required) if (modeRank[rule.mode] < modeRank[chosenMode]) chosenMode = rule.mode;
    const reviewRequired = input.governance.requireReview && !activeGrants.some(policy => policy.reviewExempt);
    if (reviewRequired && chosenMode === 'allow') chosenMode = 'ask_first';
    const representative = required.find(rule => rule.mode === chosenMode) ?? personal.find(rule => rule.mode === chosenMode) ?? candidates.find(rule => rule.mode === chosenMode);
    if (representative) rules.push({ ...representative, mode: chosenMode, required: required.length > 0 || reviewRequired });
    else rules.push({ id: `effective:${input.userId}:${input.botId ?? 'all'}:${action}`, revision: input.governance.revision, createdAtMs: 0, updatedAtMs: 0, ownerUserId: null, category: action, botId: input.botId, machineId: input.machineId, mode: chosenMode, required: reviewRequired, description: reviewRequired ? 'Workspace requires explicit review.' : 'Composed eligible-group capability and personal restrictions.' });
    if (required.some(rule => rule.mode === 'ask_first')) explanations.push(`${action}: required ask_first rule wins; review exemption cannot override it.`);
    if (personal.length) explanations.push(`${action}: personal preferences may tighten eligible-group grants.`);
  }
  const workspaceNetworks = input.networkPolicies.filter(policy => policy.scope === 'workspace');
  const groupNetworkIds = new Set(activeGrants.map(policy => policy.networkPolicyId).filter((value): value is string => value !== null));
  const groupNetworks = input.networkPolicies.filter(policy => policy.scope === 'directory_group' && groupNetworkIds.has(policy.id));
  const networkPolicies = input.governance.lockNetworkForGroups || !groupNetworks.length ? workspaceNetworks : groupNetworks;
  explanations.push(input.governance.lockNetworkForGroups ? 'Workspace network hard lock overrides group network replacements.' : 'Applicable group network policies replace workspace rules and intersect on destination.');
  if (!productAccess) explanations.push('Workspace, membership or eligible directory group denied product access.');
  explanations.push(`Local execution is ${localExecutionCeiling}; workspace ceiling is ${input.policies.localExecutionCeiling}.`);
  return { userId: input.userId, botId: input.botId, directoryGroupIds: eligible.map(group => group.id).sort(), productAccess, localExecutionCeiling, allowSudo: input.governance.allowSudo && (!activeGrants.length || activeGrants.some(policy => policy.allowSudo)), allowEgress: input.governance.allowEgress && (!activeGrants.length || activeGrants.some(policy => policy.allowEgress)), rules, networkPolicies, explanations };
}

export function createPolicyServices(services: BackendServices) {
  function governance(): P.Governance { return services.store.metadata<P.Governance>('governance') ?? structuredClone(defaultGovernance); }
  async function effectivePolicy(who: Principal, botId?: string): Promise<P.EffectivePolicy> {
    const bot = botId ? services.auth.bot(who, botId) : null;
    const workspaceId = services.store.metadata<string>('workspaceId'); const workspace = workspaceId ? services.store.get<P.Workspace>('workspaces', workspaceId) : null;
    const base = services.store.metadata<P.Policies>('policies') ?? { revision: 1, publicTemplates: false, allowedMcpOrigins: null, localExecutionCeiling: 'ask', actionRecording: false, auditRetentionDays: 90, rules: [] };
    return composeEffectivePolicy({ userId: who.userId, botId: bot?.id ?? null, machineId: bot?.machineId ?? null, workspaceEnabled: workspace?.enabled ?? false, memberEnabled: services.auth.member(who.userId).enabled, governance: governance(), policies: base, groups: services.store.list<P.DirectoryGroup>('directoryGroups'), groupPolicies: services.store.list<P.GroupPolicy>('groupPolicies'), rules: services.store.list<P.PolicyRule>('policyRules'), networkPolicies: services.store.list<P.NetworkPolicy>('networkPolicies') });
  }
  async function defaultBotIds(who: Principal): Promise<string[]> {
    const policy = await effectivePolicy(who); if (!policy.productAccess) return [];
    const ids = new Set(services.store.list<P.GroupPolicy>('groupPolicies', group => policy.directoryGroupIds.includes(group.directoryGroupId) && group.productAccess).flatMap(group => group.defaultBotIds));
    return [...ids].filter(id => { try { const bot = services.auth.bot(who, id); return bot.visibility === 'team' && bot.published; } catch { return false; } }).sort();
  }
  async function sharedProfilePolicy(botId: string): Promise<P.EffectivePolicy> {
    const bot = services.store.require<P.Bot>('bots', botId);
    const workspaceId = services.store.metadata<string>('workspaceId');
    const workspace = workspaceId ? services.store.get<P.Workspace>('workspaces', workspaceId) : null;
    const base: P.Policies = services.store.metadata<P.Policies>('policies') ?? { revision: 1, publicTemplates: false, allowedMcpOrigins: null, localExecutionCeiling: 'ask', actionRecording: false, auditRetentionDays: 90, rules: [] };
    const hardRules = services.store.list<P.PolicyRule>('policyRules', rule => rule.required && rule.ownerUserId === null);
    const floor = composeEffectivePolicy({ userId: bot.ownerUserId, botId, machineId: bot.machineId, workspaceEnabled: workspace?.enabled ?? false, memberEnabled: true, governance: { ...governance(), groupAccess: 'all', allowedDirectoryGroupIds: [], requireReview: false }, policies: base, groups: [], groupPolicies: [], rules: hardRules, networkPolicies: services.store.list<P.NetworkPolicy>('networkPolicies', policy => policy.scope === 'workspace') });
    floor.explanations.push('Shared profile floor excludes owner personal choices and directory-group grants; every placed invocation applies the actual initiating principal policy.');
    return floor;
  }
  return { governance, effectivePolicy, sharedProfilePolicy, defaultBotIds, requiredNetworkPolicies: async (who: Principal, botId?: string) => (await effectivePolicy(who, botId)).networkPolicies };
}

export function createPolicyRoutes(services: BackendServices, hooks: { governanceChanged?: (previous: P.Governance, next: P.Governance) => Promise<void>; cancelContent?: () => void } = {}): Route[] {
  const policyServices = createPolicyServices(services);
  function groupPolicy(group: P.DirectoryGroup): P.GroupPolicy {
    const existing = services.store.list<P.GroupPolicy>('groupPolicies', item => item.directoryGroupId === group.id)[0];
    if (existing) return existing;
    const created = services.resource('gpolicy', { directoryGroupId: group.id, productAccess: true, defaultBotIds: [], capabilityModes: {}, requiredRuleIds: [], localExecutionCeiling: 'ask' as const, allowEgress: false, allowSudo: false, networkPolicyId: null, reviewExempt: false });
    services.store.put('groupPolicies', created); return created;
  }
  function validateMembers(memberIds: string[]) { for (const userId of memberIds) services.auth.member(userId); }
  return [
    { method: 'GET', path: '/v1/directory/groups', auth: 'admin', handler: context => services.page(context, services.store.list<P.DirectoryGroup>('directoryGroups')) },
    { method: 'POST', path: '/v1/directory/groups', auth: 'admin', status: 201, handler: context => { const body = createGroup.parse(context.body); validateMembers(body.memberUserIds); const value = services.resource('dir', { name: body.name, memberUserIds: body.memberUserIds, source: 'local' as const, externalId: null }); return services.store.transaction(() => { services.store.put('directoryGroups', value); groupPolicy(value); services.events.emit('directory_group.upserted', value, { admin: true }); services.audit(principal(context), 'directory.create', value.id, 'succeeded', {}, context.requestId); return value; }); } },
    { method: 'PATCH', path: '/v1/directory/groups/:id', auth: 'admin', handler: context => { const who = principal(context); const body = patchGroup.parse(context.body); const value = services.store.require<P.DirectoryGroup>('directoryGroups', context.params.id!); services.mutations.checkRevision(value, body.revision); if (value.source !== 'local' && !(who.role === 'owner' && services.config.operatorExtras?.managedDirectoryOwnerOverride === true)) throw new ApiError('policy_denied', 'Managed OIDC or SCIM group memberships must be changed in their directory source unless an explicit operator Owner override is enabled.'); if (body.memberUserIds) validateMembers(body.memberUserIds); const { clientNonce: _nonce, revision: _revision, ...changes } = body; return services.store.transaction(() => { const result = services.update(value, changes); services.store.put('directoryGroups', result); services.events.emit('directory_group.upserted', result, { admin: true }); services.audit(who, value.source === 'local' ? 'directory.update' : 'directory.owner_override', result.id, 'succeeded', { source: value.source }, context.requestId); return result; }); } },
    { method: 'DELETE', path: '/v1/directory/groups/:id', auth: 'admin', handler: context => { const body = revision.parse(context.body); const value = services.store.require<P.DirectoryGroup>('directoryGroups', context.params.id!); services.mutations.checkRevision(value, body.revision); if (value.source !== 'local') throw new ApiError('policy_denied', 'Managed group deletion must occur in its directory source.'); if (services.store.list<P.NetworkPolicy>('networkPolicies', policy => policy.directoryGroupId === value.id).length || services.store.list<P.SetupManifest>('setupManifests', manifest => manifest.directoryGroupId === value.id).length) throw new ApiError('conflict', 'Remove group network policies and setup manifests first.'); return services.store.transaction(() => { services.store.remove('directoryGroups', value.id); for (const policy of services.store.list<P.GroupPolicy>('groupPolicies', item => item.directoryGroupId === value.id)) services.store.remove('groupPolicies', policy.id); services.events.emit('directory_group.deleted', { id: value.id, deleted: true }, { admin: true }); services.audit(principal(context), 'directory.delete', value.id, 'succeeded', {}, context.requestId); return { id: value.id, deleted: true }; }); } },
    { method: 'GET', path: '/v1/directory/groups/:id/policy', auth: 'admin', handler: context => groupPolicy(services.store.require<P.DirectoryGroup>('directoryGroups', context.params.id!)) },
    { method: 'PATCH', path: '/v1/directory/groups/:id/policy', auth: 'admin', handler: context => { const who = principal(context); const body = patchPolicy.parse(context.body); const value = groupPolicy(services.store.require<P.DirectoryGroup>('directoryGroups', context.params.id!)); services.mutations.checkRevision(value, body.revision); for (const botId of body.defaultBotIds ?? []) { const bot = services.auth.bot(who, botId, true); if (bot.visibility !== 'team' || !bot.published) throw new ApiError('invalid_request', 'Default bots must be published Team Bots under explicit management authority.'); } for (const ruleId of body.requiredRuleIds ?? []) { const rule = services.store.require<P.PolicyRule>('policyRules', ruleId); if (!rule.required || rule.ownerUserId !== null) throw new ApiError('invalid_request', 'Group required rules must reference required workspace rules.'); } if (body.networkPolicyId) { const network = services.store.require<P.NetworkPolicy>('networkPolicies', body.networkPolicyId); if (network.scope !== 'directory_group' || network.directoryGroupId !== value.directoryGroupId) throw new ApiError('invalid_request', 'Network policy must belong to this directory group.'); } const { clientNonce: _nonce, revision: _revision, ...changes } = body; return services.store.transaction(() => { const result = services.update(value, changes); services.store.put('groupPolicies', result); services.events.emit('group_policy.upserted', result, { admin: true }); services.audit(who, 'directory.policy', result.id, 'succeeded', {}, context.requestId); return result; }); } },
    { method: 'GET', path: '/v1/governance', auth: 'admin', handler: () => policyServices.governance() },
    { method: 'PATCH', path: '/v1/governance', auth: 'admin', handler: async context => { const body = patchGovernance.parse(context.body); const previous = policyServices.governance(); services.mutations.checkRevision(previous, body.revision); for (const groupId of body.allowedDirectoryGroupIds ?? []) services.store.require<P.DirectoryGroup>('directoryGroups', groupId); const { clientNonce: _nonce, revision: _revision, ...changes } = body; const next: P.Governance = { ...previous, ...changes, revision: previous.revision + 1 }; services.store.transaction(() => { services.store.setMetadata('governance', next); if (previous.contentExportEnabled && !next.contentExportEnabled) hooks.cancelContent?.(); services.events.emit('governance.updated', next, { admin: true }); services.audit(principal(context), 'governance.update', 'governance', 'succeeded', {}, context.requestId); }); await hooks.governanceChanged?.(previous, next); return next; } },
    { method: 'GET', path: '/v1/policies/effective', auth: 'member', handler: context => { let who = principal(context); const target = context.query.get('userId'); if (target && target !== who.userId) { services.auth.requireRole(who, 'admin'); who = userPrincipal(services, target); } const botId = context.query.get('botId') ?? undefined; return policyServices.effectivePolicy(who, botId); } },
  ];
}
