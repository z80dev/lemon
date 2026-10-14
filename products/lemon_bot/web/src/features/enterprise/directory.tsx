import { useState } from 'react';
import { nonce, type DirectoryGroup, type Governance, type GroupPolicy, type Bot, type Member, type NetworkPolicy, type PolicyRule } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, EmptyState, Field, useQuery } from '../../ui';
import { AccessNotice, categories, Checks, DeleteButton, IntentNotice, label, QueryNotice, Toggle, useCollection, useIntent } from './shared';

export function GovernanceEditor({ initial, groups, onSaved }: { initial: Governance; groups: DirectoryGroup[]; onSaved: () => Promise<void> }) {
  const { client, reportError } = useApp();
  const [draft, setDraft] = useState(initial);
  const intent = useIntent();
  const update = <K extends keyof Governance>(key: K, value: Governance[K]) => setDraft(current => ({ ...current, [key]: value }));
  return <form className="panel stack" onSubmit={event => { event.preventDefault(); void intent.perform(async () => { const saved = await client.call('PATCH /governance', { body: { ...draft, clientNonce: nonce() } }); setDraft(saved); return saved; }).then(saved => { if (saved) void onSaved().catch(reportError); }); }}>
    <h2>Workspace governance</h2><p className="muted">Central ceilings constrain all eligible groups. Required ask-first rules win conflicts. Product policies are not an OS sandbox.</p>
    <Field label="Product access"><select value={draft.groupAccess} onChange={event => update('groupAccess', event.target.value as Governance['groupAccess'])}><option value="all">All enabled members</option><option value="selected">Selected directory groups</option></select></Field>
    {draft.groupAccess === 'selected' && <Checks legend="Groups with access" options={groups.map(group => ({ id: group.id, name: group.name, detail: group.source }))} value={draft.allowedDirectoryGroupIds} onChange={value => update('allowedDirectoryGroupIds', value)} />}
    <div className="grid"><Toggle checked={draft.allowSudo} onChange={value => update('allowSudo', value)}>Allow privileged execution (sudo)</Toggle><Toggle checked={draft.allowEgress} onChange={value => update('allowEgress', value)}>Allow explicitly authorized egress routes</Toggle><Toggle checked={draft.lockNetworkForGroups} onChange={value => update('lockNetworkForGroups', value)}>Lock workspace network policy for groups</Toggle><Toggle checked={draft.requireReview} onChange={value => update('requireReview', value)}>Enforce action review</Toggle><Toggle checked={draft.xMentionsEnabled} onChange={value => update('xMentionsEnabled', value)}>Enable verified X mentions</Toggle><Toggle checked={draft.emailEnabled} onChange={value => update('emailEnabled', value)}>Enable configured email integration</Toggle><Toggle checked={draft.contentExportEnabled} onChange={value => update('contentExportEnabled', value)}>Allow participant-consented conversation content exports</Toggle></div>
    <Checks legend="Allowed channel adapters" options={['telegram', 'discord', 'slack', 'email', 'whatsapp'].map(id => ({ id, name: label(id) }))} value={draft.allowedChannelAdapters} onChange={value => update('allowedChannelAdapters', value as Governance['allowedChannelAdapters'])} />
    <fieldset className="stack"><legend>Inactive host policy</legend><p className="muted small">Off by default. Only verified idle or sleeping hosts with configured suspend/stop support are eligible. Awake work, host files, disk and execution trust are retained.</p><Toggle checked={draft.inactiveHostPolicy.enabled} onChange={enabled => update('inactiveHostPolicy', { ...draft.inactiveHostPolicy, enabled })}>Enable inactivity action</Toggle><Field label="Inactive days"><input type="number" min="1" step="1" required value={draft.inactiveHostPolicy.afterDays} onChange={event => update('inactiveHostPolicy', { ...draft.inactiveHostPolicy, afterDays: event.target.valueAsNumber })} /></Field><Field label="Action"><select value={draft.inactiveHostPolicy.action} onChange={event => update('inactiveHostPolicy', { ...draft.inactiveHostPolicy, action: event.target.value as 'suspend' | 'stop_worker' })}><option value="suspend">Suspend supported environment</option><option value="stop_worker">Stop Lemon worker</option></select></Field></fieldset>
    <button type="button" disabled={intent.busy} onClick={() => { if (window.confirm('Discard this unsaved governance draft and load the current server revision?')) void intent.reconcile(async () => { setDraft(await client.call('GET /governance')); }); }}>Discard draft and load latest governance</button>
    <IntentNotice intent={intent} reconcile={onSaved} /><button className="primary" disabled={intent.disabled}>Save governance · revision {draft.revision}</button>
  </form>;
}

function GroupEditor({ group, members, onSaved, onCancel }: { group?: DirectoryGroup; members: Member[]; onSaved: () => Promise<void>; onCancel: () => void }) {
  const { client, reportError } = useApp();
  const [name, setName] = useState(group?.name ?? '');
  const [memberIds, setMemberIds] = useState(group?.memberUserIds ?? []);
  const intent = useIntent();
  const managed = group && group.source !== 'local';
  return <form className="panel stack" onSubmit={event => { event.preventDefault(); void intent.perform(() => group ? client.call('PATCH /directory/groups/:id', { params: { id: group.id }, body: { revision: group.revision, clientNonce: nonce(), name, memberUserIds: memberIds } }) : client.call('POST /directory/groups', { body: { clientNonce: nonce(), name, memberUserIds: memberIds } })).then(saved => { if (saved) { onCancel(); void onSaved().catch(reportError); } }); }}>
    <h2>{group ? `Edit ${group.name}` : 'Create directory group'}</h2>{managed && <p role="note">Membership is managed by {group.source.toUpperCase()}. Change it at the source provider. Configured external ID: {group.externalId ?? 'not supplied'}.</p>}
    <fieldset disabled={Boolean(managed) || intent.busy} className="stack"><Field label="Group name"><input required maxLength={120} value={name} onChange={event => setName(event.target.value)} /></Field><Checks legend="Members" options={members.map(member => ({ id: member.userId, name: member.displayName, detail: `${member.email} · ${member.enabled ? member.role : 'disabled'}` }))} value={memberIds} onChange={setMemberIds} /></fieldset>
    <IntentNotice intent={intent} reconcile={onSaved} /><div className="row">{!managed && <button className="primary" disabled={intent.disabled}>Save group</button>}<button type="button" onClick={onCancel}>Close</button></div>
  </form>;
}

function GroupPolicyEditor({ initial, bots, rules, networks, onSaved }: { initial: GroupPolicy; bots: Bot[]; rules: PolicyRule[]; networks: NetworkPolicy[]; onSaved: () => Promise<void> }) {
  const { client, reportError } = useApp();
  const [draft, setDraft] = useState(initial);
  const intent = useIntent();
  const update = <K extends keyof GroupPolicy>(key: K, value: GroupPolicy[K]) => setDraft(current => ({ ...current, [key]: value }));
  return <form className="panel stack" onSubmit={event => { event.preventDefault(); const { revision, productAccess, defaultBotIds, capabilityModes, requiredRuleIds, localExecutionCeiling, allowEgress, allowSudo, networkPolicyId, reviewExempt } = draft; void intent.perform(() => client.call('PATCH /directory/groups/:id/policy', { params: { id: initial.directoryGroupId }, body: { clientNonce: nonce(), revision, productAccess, defaultBotIds, capabilityModes, requiredRuleIds, localExecutionCeiling, allowEgress, allowSudo, networkPolicyId, reviewExempt } })).then(saved => { if (saved) { setDraft(saved); void onSaved().catch(reportError); } }); }}>
    <h3>Group access and ceilings</h3><Toggle checked={draft.productAccess} onChange={value => update('productAccess', value)}>Grant product access</Toggle><Checks legend="Default team bots" hint="Defaults are added for eligible members; required bots cannot be hidden by collaborators." options={bots.filter(bot => bot.visibility === 'team' && bot.published).map(bot => ({ id: bot.id, name: bot.name, detail: bot.required ? 'required' : 'published' }))} value={draft.defaultBotIds} onChange={value => update('defaultBotIds', value)} />
    <fieldset className="grid"><legend>Capability review modes</legend>{categories.map(category => <Field key={category} label={label(category)}><select value={draft.capabilityModes[category] ?? ''} onChange={event => { const capabilityModes = { ...draft.capabilityModes }; if (event.target.value) capabilityModes[category] = event.target.value as 'ask_first' | 'auto_review' | 'allow'; else delete capabilityModes[category]; update('capabilityModes', capabilityModes); }}><option value="">Inherit</option><option value="ask_first">Ask first</option><option value="auto_review">Auto review</option><option value="allow">Allow within hard ceilings</option></select></Field>)}</fieldset>
    <Checks legend="Required policy rules" options={rules.filter(rule => rule.required).map(rule => ({ id: rule.id, name: rule.description, detail: `${label(rule.category)} · ${label(rule.mode)}` }))} value={draft.requiredRuleIds} onChange={value => update('requiredRuleIds', value)} />
    <Field label="Local execution ceiling"><select value={draft.localExecutionCeiling} onChange={event => update('localExecutionCeiling', event.target.value as GroupPolicy['localExecutionCeiling'])}><option value="deny">Deny</option><option value="ask">Ask for each proposal</option><option value="allow">Allow within required policy</option></select></Field><Field label="Network policy"><select value={draft.networkPolicyId ?? ''} onChange={event => update('networkPolicyId', event.target.value || null)}><option value="">Inherit workspace</option>{networks.map(network => <option key={network.id} value={network.id}>{network.id} · {label(network.mode)}</option>)}</select></Field>
    <button type="button" disabled={intent.busy} onClick={() => { if (window.confirm('Discard this unsaved group policy draft and load the current server revision?')) void intent.reconcile(async () => { setDraft(await client.call('GET /directory/groups/:id/policy', { params: { id: initial.directoryGroupId } })); }); }}>Discard draft and load latest group policy</button>
    <Toggle checked={draft.allowSudo} onChange={value => update('allowSudo', value)}>Allow sudo under central ceiling</Toggle><Toggle checked={draft.allowEgress} onChange={value => update('allowEgress', value)}>Allow egress under central ceiling</Toggle><Toggle checked={draft.reviewExempt} onChange={value => update('reviewExempt', value)}>Explicit exemption from enforced reviewer lock (required ask-first still applies)</Toggle><IntentNotice intent={intent} reconcile={onSaved} /><button className="primary" disabled={intent.disabled}>Save group policy · revision {draft.revision}</button>
  </form>;
}

function PolicyPanel({ groupId, bots, rules, networks }: { groupId: string; bots: Bot[]; rules: PolicyRule[]; networks: NetworkPolicy[] }) {
  const { client } = useApp();
  const query = useQuery(`group-policy:${groupId}`, () => client.call('GET /directory/groups/:id/policy', { params: { id: groupId } }));
  return <><QueryNotice query={query} />{query.data && <GroupPolicyEditor initial={query.data} bots={bots} rules={rules} networks={networks} onSaved={query.reload} />}</>;
}

export function DirectoryScreen() {
  const { snapshot } = useApp();
  const admin = snapshot.member.role !== 'member';
  return admin ? <DirectoryAdmin /> : <AccessNotice />;
}

function DirectoryAdmin() {
  const { client, reportError } = useApp();
  const groups = useCollection('directory-groups', query => client.call('GET /directory/groups', { query }));
  const members = useCollection('enterprise-members', query => client.call('GET /members', { query }));
  const bots = useCollection('enterprise-team-bots', query => client.call('GET /bots', { query: { ...query, visibility: 'team' } }));
  const networks = useCollection('enterprise-networks', query => client.call('GET /network-policies', { query }));
  const policies = useQuery('enterprise-policy-rules', () => client.call('GET /policies'));
  const governance = useQuery('enterprise-governance', () => client.call('GET /governance'));
  const [editing, setEditing] = useState<DirectoryGroup | 'new' | null>(null);
  const [policyGroup, setPolicyGroup] = useState<string>();
  const intent = useIntent();
  return <div className="stack"><p className="muted">Directory groups grant workspace access; they are not chat groups. Source-managed identities and memberships stay provider-owned.</p>{[groups, members, bots, networks, policies, governance].map((query, index) => <QueryNotice key={index} query={query} />)}
    <IntentNotice intent={intent} reconcile={groups.reload} />
    {groups.data && <section className="panel stack"><div className="row spread"><h2>Directory groups</h2><button type="button" disabled={intent.disabled} onClick={() => setEditing('new')}>Create group</button></div>{!groups.data.length && <EmptyState title="No directory groups" />}{groups.data.map(group => <article className="list-row" key={group.id}><div><strong>{group.name}</strong> <Badge>{group.source}</Badge><p className="muted small">{group.memberUserIds.length} members · external group mapping {group.externalId ?? 'local group'} · revision {group.revision}</p></div><div className="row"><button type="button" onClick={() => setEditing(group)}>{group.source === 'local' ? 'Edit members' : 'Inspect membership'}</button><button type="button" onClick={() => setPolicyGroup(group.id)}>Edit access policy</button>{group.source === 'local' && <DeleteButton name={group.name} disabled={intent.disabled} onDelete={() => void intent.perform(() => client.call('DELETE /directory/groups/:id', { params: { id: group.id }, body: { revision: group.revision, clientNonce: nonce() } })).then(result => { if (result) void groups.reload().catch(reportError); })} />}</div></article>)}</section>}
    {editing && members.data && <GroupEditor key={editing === 'new' ? 'new' : editing.id} group={editing === 'new' ? undefined : editing} members={members.data} onSaved={groups.reload} onCancel={() => setEditing(null)} />}
    {policyGroup && bots.data && policies.data && networks.data && <section className="stack"><div className="row spread"><h2>Policy for {groups.data?.find(group => group.id === policyGroup)?.name ?? policyGroup}</h2><button type="button" onClick={() => setPolicyGroup(undefined)}>Close policy editor</button></div><PolicyPanel key={policyGroup} groupId={policyGroup} bots={bots.data} rules={policies.data.rules} networks={networks.data} /></section>}
    {governance.data && groups.data && <GovernanceEditor initial={governance.data} groups={groups.data} onSaved={governance.reload} />}
  </div>;
}
