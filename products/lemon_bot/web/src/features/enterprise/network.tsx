import { useState } from 'react';
import { nonce, type EffectivePolicy, type Machine, type NetworkPolicy, type NetworkRule } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, EmptyState, Field, formatTime, useQuery } from '../../ui';
import { IntentInputError, AccessNotice, DeleteButton, IntentNotice, label, machineOptions, QueryNotice, Toggle, useCollection, useIntent, words } from './shared'

export function EffectivePolicyPanel() {
  const { client } = useApp();
  const [botId, setBotId] = useState('');
  const bots = useCollection('effective-visible-bots', query => client.call('GET /bots', { query }));
  const query = useQuery(`enterprise-effective:${botId}`, () => client.call('GET /policies/effective', { query: { ...(botId ? { botId } : {}) } }));
  return <section className="panel stack"><h2>Effective permissions and reasons</h2><p className="muted">This is the server's actual composition, not a predicted permission from local checkboxes. Source-service grants and OS access still constrain execution.</p><div className="row"><Field label="Bot context"><select value={botId} onChange={event => setBotId(event.target.value)}><option value="">Workspace / no bot</option>{bots.data?.map(bot => <option key={bot.id} value={bot.id}>{bot.name}</option>)}</select></Field></div><QueryNotice query={bots} /><QueryNotice query={query} />{query.data && <EffectiveDetails policy={query.data} />}</section>;
}


function EffectiveDetails({ policy }: { policy: EffectivePolicy }) {
  return <><dl className="enterprise-facts"><dt>Product access</dt><dd>{policy.productAccess ? 'Granted' : 'Denied'}</dd><dt>Local execution ceiling</dt><dd>{label(policy.localExecutionCeiling)}</dd><dt>Sudo</dt><dd>{policy.allowSudo ? 'Allowed under source and host authority' : 'Denied'}</dd><dt>Egress</dt><dd>{policy.allowEgress ? 'Explicit authorized routes permitted' : 'Centrally denied'}</dd></dl><h3>Why these permissions apply</h3><ul>{policy.explanations.map((reason, index) => <li key={index}>{reason}</li>)}</ul><h3>Effective action rules</h3>{policy.rules.map(rule => <p key={rule.id}><Badge tone={rule.required ? 'warning' : 'muted'}>{rule.required ? 'required' : 'personal'}</Badge> {label(rule.category)} · {label(rule.mode)} · {rule.description}</p>)}<h3>Effective network policies</h3>{policy.networkPolicies.map(network => <div className="card" key={network.id}><strong>{label(network.scope)} · {label(network.mode)} · revision {network.revision}</strong><RulesList title="Configured destinations" rules={network.rules} /><RulesList title="Operator-owned runtime destinations" rules={network.requiredRuntimeDestinations} /></div>)}</>;
}
function RulesList({ title, rules }: { title: string; rules: NetworkRule[] }) {
  return <div><h4>{title}</h4>{!rules.length ? <p className="small muted">None returned by the server.</p> : <ul>{rules.map((rule, index) => <li key={index}><code>{rule.value}</code> · {label(rule.kind)} · {rule.protocol} · {rule.ports.length ? `ports ${rule.ports.join(', ')}` : 'all ports'}</li>)}</ul>}</div>;
}
interface RuleDraft { key: string; kind: NetworkRule['kind']; value: string; ports: string; protocol: NetworkRule['protocol'] }
function policyRules(drafts: RuleDraft[]): NetworkRule[] {
  return drafts.map(draft => {
    const ports = words(draft.ports).map(Number);
    if (ports.some(port => !Number.isInteger(port) || port < 1 || port > 65535)) throw new IntentInputError('Each network port must be an integer from 1 to 65535.');
    if (!draft.value.trim()) throw new IntentInputError('Every network destination needs an exact domain, explicit *. suffix or canonical IP CIDR.');
    return { kind: draft.kind, value: draft.value.trim(), ports, protocol: draft.protocol };
  });
}
function NetworkEditor({ policy, onSaved, onClose }: { policy?: NetworkPolicy; onSaved: () => Promise<void>; onClose: () => void }) {
  const { client, reportError } = useApp();
  const intent = useIntent();
  const [mode, setMode] = useState<NetworkPolicy['mode']>(policy?.mode ?? 'defaults_plus_allowlist');
  const [rules, setRules] = useState<RuleDraft[]>(() => policy?.rules.map(rule => ({ ...rule, key: nonce(), ports: rule.ports.join(', ') })) ?? []);
  const update = (key: string, patch: Partial<RuleDraft>) => setRules(current => current.map(rule => rule.key === key ? { ...rule, ...patch } : rule));
  return <form className="panel stack" onSubmit={event => { event.preventDefault(); void intent.perform(() => { const parsed = policyRules(rules); return policy ? client.call('PATCH /network-policies/:id', { params: { id: policy.id }, body: { clientNonce: nonce(), revision: policy.revision, mode, rules: parsed } }) : client.call('POST /network-policies', { body: { clientNonce: nonce(), scope: 'workspace', mode, rules: parsed } }); }).then(result => { if (result) { onClose(); void onSaved().catch(reportError); } }); }}><h2>{policy ? 'Edit network policy' : 'Create network policy'}</h2><p className="muted">Domain matching is exact or explicit *. suffix, never substring. IP rules use canonical IPv4/IPv6 CIDR. Required runtime destinations are operator-owned; saving desired policy is not proof of applied enforcement.</p><p className="small muted">Scope: your workspace</p><Field label="Network mode"><select value={mode} onChange={event => setMode(event.target.value as NetworkPolicy['mode'])}><option value="allow_all">Allow all within host/operator policy</option><option value="defaults_plus_allowlist">Defaults plus allowlist</option><option value="allowlist_only">Allowlist only plus required runtime</option></select></Field>
    <fieldset className="stack"><legend>Destination rules</legend>{rules.map((rule, index) => <div className="card stack" key={rule.key}><h3>Rule {index + 1}</h3><div className="grid"><Field label="Destination kind"><select value={rule.kind} onChange={event => update(rule.key, { kind: event.target.value as NetworkRule['kind'] })}><option value="domain">Domain</option><option value="ip_cidr">IP CIDR</option></select></Field><Field label={rule.kind === 'domain' ? 'Exact domain or *. suffix' : 'Canonical IP CIDR'}><input required value={rule.value} onChange={event => update(rule.key, { value: event.target.value })} /></Field><Field label="Ports (comma-separated; empty means all)"><input inputMode="numeric" value={rule.ports} onChange={event => update(rule.key, { ports: event.target.value })} /></Field><Field label="Protocol"><select value={rule.protocol} onChange={event => update(rule.key, { protocol: event.target.value as NetworkRule['protocol'] })}><option value="tcp">TCP</option><option value="udp">UDP</option><option value="both">TCP and UDP</option></select></Field></div><button type="button" onClick={() => setRules(current => current.filter(item => item.key !== rule.key))}>Remove rule {index + 1}</button></div>)}<button type="button" onClick={() => setRules(current => [...current, { key: nonce(), kind: 'domain', value: '', ports: '', protocol: 'tcp' }])}>Add destination rule</button></fieldset>{policy && <RulesList title="Required runtime destinations (read only)" rules={policy.requiredRuntimeDestinations} />}<IntentNotice intent={intent} reconcile={onSaved} /><div className="row"><button className="primary" disabled={intent.disabled}>Save desired policy</button><button type="button" onClick={onClose}>Close editor</button></div></form>;
}

function ManagedMachineChoice({ machine, capability, selected, onChange }: { machine: Machine; capability: 'supportsNetworkPolicy' | 'supportsSetup'; selected: boolean; onChange: (selected: boolean) => void }) {
  const { client } = useApp();
  const query = useQuery(`enterprise-host-management:${machine.id}`, () => client.call('GET /machines/:id/management', { params: { id: machine.id } }));
  return <div className="card"><label className="row"><input type="checkbox" checked={selected} disabled={!selected && (!query.data?.[capability] || machine.status === 'revoked')} onChange={event => onChange(event.target.checked)} /><span>{machine.name} · {machine.status} · {query.data ? `${query.data.provider} · ${query.data[capability] ? 'driver supported' : 'driver not configured'}` : 'checking driver'}</span></label><QueryNotice query={query} /></div>;
}
export function ManagedMachinePicker({ machines, value, onChange, capability }: { machines: Machine[]; value: string[]; onChange: (ids: string[]) => void; capability: 'supportsNetworkPolicy' | 'supportsSetup' }) {
  return <fieldset className="stack"><legend>Explicit target machines</legend>{machines.map(machine => <ManagedMachineChoice key={machine.id} machine={machine} capability={capability} selected={value.includes(machine.id)} onChange={checked => onChange(checked ? [...value, machine.id] : value.filter(id => id !== machine.id))} />)}</fieldset>;
}

function Applications({ policy, machines }: { policy: NetworkPolicy; machines: Machine[] }) {
  const { client, reportError } = useApp();
  const query = useCollection(`network-applications:${policy.id}`, query => client.call('GET /network-policies/:id/applications', { params: { id: policy.id }, query }));
  const [machineIds, setMachineIds] = useState<string[]>([]);
  const intent = useIntent();
  return <section className="panel stack"><h3>Actual application status · desired policy revision {policy.revision}</h3><p className="muted">A pending receipt is not applied. Enforced-network work is blocked while pending, failed or unsupported. Sleeping machines must apply before admission on return.</p><QueryNotice query={query} /><button type="button" disabled={query.loading} onClick={() => void intent.reconcile(query.reload)}>Read current applied state</button>{query.data?.map(application => <article key={application.machineId} className="card"><strong>{machines.find(machine => machine.id === application.machineId)?.name ?? application.machineId}</strong> <Badge tone={application.state === 'applied' ? 'good' : 'warning'}>{application.state}</Badge><p>Desired {application.desiredRevision} · applied {application.appliedRevision ?? 'not acknowledged'} · measured {formatTime(application.measuredAtMs)}</p>{application.error && <p role="alert">{application.error}</p>}</article>)}<ManagedMachinePicker machines={machines} value={machineIds} onChange={setMachineIds} capability="supportsNetworkPolicy" /><IntentNotice intent={intent} reconcile={query.reload} /><button type="button" className="primary" disabled={intent.disabled || !machineIds.length} onClick={() => void intent.perform(() => client.call('POST /network-policies/:id/apply', { params: { id: policy.id }, body: { clientNonce: nonce(), machineIds } })).then(result => { if (result) void query.reload().catch(reportError); })}>Request application to selected machines</button></section>;
}

function EgressPanel() {
  const { client, snapshot, reportError } = useApp();
  const routes = useCollection('enterprise-egress-routes', query => client.call('GET /egress-routes', { query }));
  const machines = useCollection('enterprise-egress-machines', query => client.call('GET /machines', { query }));
  const effective = useQuery('enterprise-egress-effective', () => client.call('GET /policies/effective'));
  const [source, setSource] = useState('');
  const [through, setThrough] = useState('');
  const [enabled, setEnabled] = useState(true);
  const intent = useIntent();
  const admin = snapshot.workspace.ownerUserId === snapshot.user.id;
  const allowed = Boolean(effective.data?.allowEgress);
  return <section className="panel stack"><h2>Explicit egress routes</h2><p className="muted">Routes require owner authority over the source and through machines and a configured encrypted host tunnel driver. No exposed unauthenticated proxy. Routes affect new connections, not another bot's destination automatically.</p><QueryNotice query={routes} /><QueryNotice query={machines} /><QueryNotice query={effective} />{effective.data && <p role="status">{allowed ? 'Central policy permits separately authorized routes.' : 'Egress is centrally disabled. Controls are locked; remembered preferences are not a new trust grant.'}</p>}{routes.data?.map(route => <article className="card stack" key={route.id}><strong>{machines.data?.find(machine => machine.id === route.machineId)?.name ?? route.machineId} → {machines.data?.find(machine => machine.id === route.throughMachineId)?.name ?? route.throughMachineId}</strong><div className="row"><Badge tone={route.state === 'active' ? 'good' : 'warning'}>{route.state}</Badge><span>{route.enabled ? 'Enabled' : 'Disabled'} · remembered choice {route.rememberedPreference ? 'yes' : 'no'}</span></div>{route.error && <p role="alert">{route.error}</p>}<div className="row"><button type="button" disabled={intent.disabled || !admin || !allowed} onClick={() => void intent.perform(() => client.call('PATCH /egress-routes/:id', { params: { id: route.id }, body: { revision: route.revision, clientNonce: nonce(), enabled: !route.enabled } })).then(result => { if (result) void routes.reload().catch(reportError); })}>{route.enabled ? 'Disable route' : 'Enable route explicitly'}</button>{admin && <DeleteButton name={`route ${route.id}`} disabled={intent.disabled} onDelete={() => void intent.perform(() => client.call('DELETE /egress-routes/:id', { params: { id: route.id }, body: { revision: route.revision, clientNonce: nonce() } })).then(result => { if (result) void routes.reload().catch(reportError); })} />}</div></article>)}
    {admin && machines.data && <form className="stack" onSubmit={event => { event.preventDefault(); void intent.perform(() => client.call('POST /egress-routes', { body: { clientNonce: nonce(), machineId: source, throughMachineId: through, enabled } })).then(result => { if (result) void routes.reload().catch(reportError); }); }}><div className="grid"><Field label="Source machine"><select required value={source} onChange={event => setSource(event.target.value)}><option value="">Choose source</option>{machineOptions(machines.data).map(machine => <option key={machine.id} value={machine.id}>{machine.name} · {machine.detail}</option>)}</select></Field><Field label="Through authorized machine"><select required value={through} onChange={event => setThrough(event.target.value)}><option value="">Choose tunnel destination</option>{machineOptions(machines.data).filter(machine => machine.id !== source).map(machine => <option key={machine.id} value={machine.id}>{machine.name} · {machine.detail}</option>)}</select></Field></div><Toggle checked={enabled} onChange={setEnabled}>Enable this explicitly selected route</Toggle><button className="primary" disabled={intent.disabled || !allowed || !source || !through || source === through}>Create authorized route</button></form>}<IntentNotice intent={intent} reconcile={async () => { await routes.reload(); await effective.reload(); }} />
  </section>;
}

function NetworkAdmin() {
  const { client, reportError } = useApp();
  const policies = useCollection('enterprise-networks', query => client.call('GET /network-policies', { query }));
  const machines = useCollection('enterprise-network-machines', query => client.call('GET /machines', { query }));
  const [editing, setEditing] = useState<NetworkPolicy | 'new' | null>(null);
  const [applicationId, setApplicationId] = useState<string>();
  const intent = useIntent();
  const applicationPolicy = policies.data?.find(policy => policy.id === applicationId);
  return <><section className="panel stack"><div className="row spread"><h2>Network policies</h2><button type="button" disabled={intent.disabled} onClick={() => setEditing('new')}>Create policy</button></div>{[policies, machines].map((query, index) => <QueryNotice key={index} query={query} />)}<IntentNotice intent={intent} reconcile={policies.reload} />{policies.data?.length === 0 && <EmptyState title="No desired network policies" />}{policies.data?.map(policy => <article className="card stack" key={policy.id}><div className="row spread"><strong>{label(policy.scope)}</strong><Badge>{label(policy.mode)}</Badge></div><p className="small muted">Policy {policy.id} · desired revision {policy.revision}</p><RulesList title="Destination rules" rules={policy.rules} /><RulesList title="Required runtime allowlist (operator owned)" rules={policy.requiredRuntimeDestinations} /><div className="row"><button type="button" onClick={() => setEditing(policy)}>Edit desired policy</button><button type="button" onClick={() => setApplicationId(policy.id)}>Apply / inspect revisions</button><DeleteButton name={`policy ${policy.id}`} disabled={intent.disabled} onDelete={() => void intent.perform(() => client.call('DELETE /network-policies/:id', { params: { id: policy.id }, body: { revision: policy.revision, clientNonce: nonce() } })).then(result => { if (result) void policies.reload().catch(reportError); })} /></div></article>)}</section>{editing && <NetworkEditor key={editing === 'new' ? 'new' : editing.id} policy={editing === 'new' ? undefined : editing} onSaved={policies.reload} onClose={() => setEditing(null)} />}{applicationPolicy && machines.data && <Applications key={applicationPolicy.id} policy={applicationPolicy} machines={machines.data} />}</>;
}

export function NetworkScreen() {
  const { snapshot } = useApp();
  return <div className="stack"><EffectivePolicyPanel />{snapshot.workspace.ownerUserId !== snapshot.user.id ? <AccessNotice /> : <NetworkAdmin />}<EgressPanel /></div>;
}
