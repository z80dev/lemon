import { useEffect, useState } from 'react';
import { nonce } from '@lemon-bot/sdk';
import type { Confirmation, Machine, MachineInvite } from '@lemon-bot/sdk';
import { useApp, type Route } from '../../app';
import { Badge, ConfirmDialog, EmptyState, ErrorNotice, Field, Loading, PageHeader, formatBytes, formatTime, useQuery } from '../../ui';
import { MachineFiles } from './files';
import { MachineTerminal } from './terminal';
import { MachineSecrets } from './secrets';
import { HostOperations } from './operations';
import { IntentNotice, MachineTabs, PrivilegeWarning, useIntent, usePages, usePoll } from './shared';
import './machines.css';

export function MachinesScreen({ route }: { route: Route }) {
  if (route.screen === 'machines.operations') return <HostOperations />;
  if (route.screen === 'machine.attach') return <AttachMachine key={route.id || 'new'} machineId={route.id} />;
  if (route.id) return <MachineScreen key={route.id} route={route} />;
  return <MachineList />;
}

function MachineList() {
  const { client, navigate, snapshot } = useApp();
  const machines = usePages('machines', cursor => client.call('GET /machines', { query: { cursor, limit: 50 } }), item => item.id);
  const admin = snapshot.workspace.ownerUserId === snapshot.user.id;
  return <main className="page stack"><PageHeader title="Machines" eyebrow="Your trusted machines">{admin && <><button onClick={() => navigate({ screen: 'machines.operations' })}>Machine operations</button><button className="primary" onClick={() => navigate({ screen: 'machine.attach' })}>Connect a machine</button></>}</PageHeader><PrivilegeWarning /><ErrorNotice error={machines.error} />{machines.loading && !machines.data && <Loading />}{machines.data?.items.length === 0 && <EmptyState title="No connected machines">Connect a machine you own. Bots continue working there when this browser closes, but cannot work while that machine is offline.</EmptyState>}<div className="grid">{machines.data?.items.map(machine => <article className="card stack" key={machine.id}><div className="row spread"><h2>{machine.name}</h2><Badge tone={machine.status === 'online' ? 'good' : 'warning'}>{machine.status}</Badge></div><code>{machine.nodeName}</code><p className="muted">Last seen {formatTime(machine.lastSeenAtMs)} · {machine.botIds.length} assigned Bots</p><div className="row">{Object.entries(machine.labels).map(([key, value]) => <span className="badge" key={key}>{key}: {value}</span>)}</div><button onClick={() => navigate({ screen: 'machine.detail', id: machine.id })}>Inspect machine</button></article>)}</div><ErrorNotice error={machines.moreError} />{machines.data?.nextCursor && <button disabled={machines.moreBusy} onClick={() => void machines.loadMore()}>Load more machines</button>}</main>;
}

function AttachMachine({ machineId }: { machineId?: string }) {
  const { client, navigate, online, realtime, snapshot, reportError } = useApp();
  const [target, setTarget] = useState(machineId);
  const [name, setName] = useState('');
  const [purpose, setPurpose] = useState('');
  const [labels, setLabels] = useState<{ key: string; value: string }[]>([]);
  const [expiry, setExpiry] = useState(15);
  const [destination, setDestination] = useState('other');
  const [invite, setInvite] = useState<MachineInvite>();
  const [copied, setCopied] = useState(false);
  const intent = useIntent();
  const preflight = useQuery('machine-enrollment-preview', () => client.call('GET /machines/enrollment-preview'));
  const state = useQuery(`enrollment:${target || 'new'}`, async () => {
    if (!target) return null;
    const [machine, invites] = await Promise.all([client.call('GET /machines/:id', { params: { id: target } }), client.call('GET /machines/:id/invites', { params: { id: target }, query: { limit: 200 } })]);
    return { machine, invites };
  });
  const current = state.data?.invites.items.find(item => item.id === invite?.id) || invite || state.data?.invites.items[0];
  const machine = state.data?.machine;
  const canManage = target ? machine?.ownerUserId === snapshot.user.id : snapshot.workspace.ownerUserId === snapshot.user.id;
  usePoll(state.reload, !!target && online, 3000);
  useEffect(() => realtime?.subscribe(frame => {
    if (frame.type !== 'event') return;
    if ((frame.event === 'machine.upserted' && frame.payload.id === target) || (frame.event === 'machine_invite.upserted' && frame.payload.machineId === target)) void state.reload().catch(reportError);
  }), [realtime, target]);
  const expired = !!current && current.expiresAtMs <= Date.now() && current.status === 'pending';
  const verified = !state.error && online && machine?.status === 'online' && machine.nodeId !== null;
  const progress = state.error ? 'verification_unavailable' : verified ? 'online' : machine?.status === 'offline' && current?.status === 'joined' ? 'offline' : expired ? 'expired' : current?.enrollment || 'invited';
  const loopbackOnly = preflight.data?.reachability === 'loopback_only';
  const canIssue = online && canManage && !intent.disabled && !preflight.error && !!preflight.data && (!loopbackOnly || destination === 'this') && expiry >= 1 && expiry <= 1440;
  async function checkReachability() {
    const preview = await client.call('GET /machines/enrollment-preview');
    if (preview.reachability === 'loopback_only' && destination !== 'this') {
      await preflight.reload();
      throw new Error('This controller only accepts same-computer joins. Choose This computer or configure a reachable wss:// controller.');
    }
  }
  const reachability = <section className="stack" aria-label="Controller reachability">
    <ErrorNotice error={preflight.error} />
    {!preflight.data && !preflight.error && <Loading label="Checking controller reachability…" />}
    {loopbackOnly && <>
      <p>This controller is loopback-only. Its join command works only on the computer running the controller, which may not be the computer running this browser.</p>
      <fieldset className="stack"><legend>Where will you run the join command?</legend>
        <label className="row"><input type="radio" name="destination" value="this" checked={destination === 'this'} onChange={() => setDestination('this')} />This computer — the controller’s computer</label>
        <label className="row"><input type="radio" name="destination" value="other" checked={destination === 'other'} onChange={() => setDestination('other')} />Another computer</label>
      </fieldset>
      <p>Other computers need a reachable <code>wss://</code> controller before you issue an invite. <a href="https://lemon.food/user-guide/attaching-a-bot-machine#prepare-the-controller" target="_blank" rel="noopener noreferrer">Set up controller TLS and routing</a>.</p>
    </>}
    {preflight.data?.reachability === 'routable' && <p className="muted">The controller advertises a secure network address. The destination must be able to reach it; this check does not test its network connection.</p>}
    <button type="button" disabled={preflight.loading || !online} onClick={() => void preflight.reload().catch(reportError)}>Check controller reachability</button>
  </section>;
  return <main className="page stack">
    <PageHeader title={target ? 'Connect this computer' : 'Connect a computer'} eyebrow="Add a machine you control" />
    <ErrorNotice error={state.error} />
    <IntentNotice intent={intent} reconcile={async () => { if (target) await state.reload(); else { await client.call('GET /machines', { query: { limit: 200 } }); navigate({ screen: 'machines' }); } }} />
    {!target ? <form className="panel stack" onSubmit={event => { event.preventDefault(); if (!canIssue) return; void intent.run(async () => {
      const labelMap: Record<string, string> = {};
      for (const label of labels) { if (!label.key || label.key in labelMap) throw new Error('Label keys must be nonempty and unique.'); labelMap[label.key] = label.value; }
      if (purpose) { if ('purpose' in labelMap) throw new Error('Purpose already has a label entry. Use the Purpose field or one purpose label, not both.'); labelMap.purpose = purpose; }
      await checkReachability();
      const nodeName = name.toLowerCase().replace(/[^a-z0-9._-]/g, '').replace(/^[^a-z0-9]+/, '').slice(0, 64) || 'lemon-host';
      const result = await client.call('POST /machines', { body: { clientNonce: nonce(), name: name.trim(), nodeName, labels: labelMap, expiresInMs: expiry * 60000 } });
      setTarget(result.machine.id); setInvite(result.invite);
    }); }}>
      <Field label="Friendly name"><input required maxLength={120} value={name} onChange={event => setName(event.target.value)} /></Field>
      <details><summary>Advanced</summary><div className="stack">
        <Field label="Purpose"><input maxLength={256} value={purpose} onChange={event => setPurpose(event.target.value)} /></Field>
        <fieldset className="stack"><legend>Machine labels</legend>{labels.map((label, index) => <div className="row" key={index}>
          <input aria-label={`Label ${index + 1} key`} maxLength={256} value={label.key} onChange={event => setLabels(values => values.map((value, position) => position === index ? { ...value, key: event.target.value } : value))} />
          <input aria-label={`Label ${index + 1} value`} maxLength={256} value={label.value} onChange={event => setLabels(values => values.map((value, position) => position === index ? { ...value, value: event.target.value } : value))} />
          <button type="button" onClick={() => setLabels(values => values.filter((_, position) => position !== index))}>Remove</button>
        </div>)}<button type="button" disabled={labels.length >= 31} onClick={() => setLabels(values => [...values, { key: '', value: '' }])}>Add label</button></fieldset>
        <Field label="Invite lifetime (minutes)"><input type="number" min={1} max={1440} value={expiry} onChange={event => setExpiry(Number(event.target.value))} /></Field>
      </div></details>
      {reachability}
      <p>By connecting, you confirm you own or administer this computer and accept that Bots work as its computer user, with access to its files, tools and logins.</p>
      <button className="primary" disabled={!canIssue || !name.trim()}>Issue one-use join command</button>
    </form> : <section className="panel stack">
      <div className="row spread"><h2>{machine?.name || 'Enrollment'}</h2><Badge tone={verified ? 'good' : 'warning'}>{progress.replaceAll('_', ' ')}</Badge></div>
      <p role="status" aria-live="polite">{verified ? 'This computer is confirmed online.' : state.error ? 'Connection status could not be verified.' : 'Waiting for this computer to connect. Copying the command does not install or connect it.'}</p>
      {verified && <button className="primary" onClick={() => { const route = { screen: 'bot.create', machineId: target }; navigate(route); }}>Online — Create a Bot here</button>}
      {current && <>
        <Field label="Exact server join command"><textarea readOnly rows={4} spellCheck={false} value={current.joinCommand} /></Field>
        <p className="small">One-use code: <code>{current.inviteCode}</code> · Expires {formatTime(current.expiresAtMs)} · {current.status}</p>
        <button disabled={expired || current.status !== 'pending'} onClick={() => { void navigator.clipboard.writeText(current.joinCommand).then(() => setCopied(true)).catch(error => { setCopied(false); reportError(error); }); }}>{copied ? 'Command copied (not enrollment proof)' : 'Copy exact join command'}</button>
        {current.lastError && <p className="error-notice" role="alert">{current.lastError}</p>}
        {canManage && current.status === 'pending' && <button className="danger" disabled={intent.disabled} onClick={() => void intent.run(async () => { await client.call('DELETE /machines/:id/invites/:inviteId', { params: { id: target, inviteId: current.id }, body: { clientNonce: nonce() } }); await state.reload(); setInvite(undefined); })}>Revoke this invite</button>}
      </>}
      {canManage && <details><summary>Reconnect this computer</summary><div className="stack">
        {reachability}
        <Field label="Repair invite lifetime (minutes)"><input type="number" min={1} max={1440} value={expiry} onChange={event => setExpiry(Number(event.target.value))} /></Field>
        <button disabled={!canIssue} onClick={() => void intent.run(async () => { await checkReachability(); setInvite(await client.call('POST /machines/:id/reconnect', { params: { id: target }, body: { clientNonce: nonce(), expiresInMs: expiry * 60000 } })); setCopied(false); await state.reload(); })}>Reissue / reconnect same identity</button>
      </div></details>}
      <button onClick={() => navigate({ screen: 'machine.detail', id: target })}>Inspect machine</button>
    </section>}
    <section className="panel"><h2>On the destination computer</h2><ol>
      <li>Run the command shown above on your computer. It installs Lemon if needed and connects using a one-use invite.</li>
      <li>Configure model/provider authentication and the default working directory locally. Do not paste provider credentials into chat.</li>
      <li>Ensure this computer can reach Lemon and your Lemon Bot server, including its MCP address.</li>
      <li>Keep the Lemon worker running with your computer’s service manager. Closing this browser does not stop Bots; stopping the worker does.</li>
    </ol></section>
  </main>;
}

function MachineScreen({ route }: { route: Route }) {
  const { client, online } = useApp();
  const query = useQuery(`machine:${route.id}`, () => client.call('GET /machines/:id', { params: { id: route.id! } }));
  usePoll(query.reload, online);
  return <main className="page stack"><ErrorNotice error={query.error}/>{!query.data ? (query.loading ? <Loading/> : <EmptyState title="Couldn’t load this machine" action={<button onClick={() => void query.reload().catch(() => undefined)}>Try again</button>}>Check your connection, then try again.</EmptyState>) : <><PageHeader title={query.data.name} eyebrow={`Machine · ${query.data.status === 'online' ? 'Online' : query.data.status === 'offline' ? 'Offline' : query.data.status === 'revoked' ? 'Access revoked' : 'Waiting to connect'}`}/><MachineTabs machine={query.data} selected={route.screen.split('.')[1] || 'detail'}/><PrivilegeWarning/>{route.screen === 'machine.files' ? <MachineFiles machine={query.data}/> : route.screen === 'machine.terminal' ? <MachineTerminal machine={query.data} terminalId={route.entryId}/> : route.screen === 'machine.secrets' ? <MachineSecrets machine={query.data}/> : <MachineDetail machine={query.data} reload={query.reload}/>}</>}</main>;
}

function MachineDetail({ machine, reload }: { machine: Machine; reload: () => Promise<void> }) {
  const { client, snapshot, navigate, online, reportError } = useApp()
  const host = useQuery(`host:${machine.id}`, () => client.call('GET /machines/:id/host', { params: { id: machine.id } }));
  const caps = useQuery(`machine-capabilities:${machine.id}`, () => client.call('GET /machines/:id/capabilities', { params: { id: machine.id } }));
  const bots = usePages(`machine-bots:${machine.id}`, cursor => client.call('GET /bots', { query: { machineId: machine.id, cursor, limit: 50 } }), item => item.id);
  const [editing, setEditing] = useState(false);
  const [editRevision, setEditRevision] = useState(machine.revision);
  const [name, setName] = useState(machine.name);
  const [labels, setLabels] = useState(Object.entries(machine.labels).map(([key, value]) => ({ key, value })));
  const [confirmation, setConfirmation] = useState<Confirmation>();
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 15000);
    return () => window.clearInterval(timer);
  }, []);
  const intent = useIntent();
  const manager = machine.ownerUserId === snapshot.user.id;
  usePoll(host.reload, online && machine.status === 'online');
  usePoll(caps.reload, online);
  const measured = host.data;
  return <><IntentNotice intent={intent} reconcile={reload} /><section className="panel stack"><div className="row spread"><h2>Host measurements</h2><button onClick={() => void host.reload().catch(reportError)}>Refresh measurements</button></div><ErrorNotice error={host.error} />{measured && <><p className="muted">Last updated {formatTime(measured.measuredAtMs)}{machine.status !== 'online' || host.error || now - measured.measuredAtMs > 30000 ? ' · may be out of date' : ''}</p><dl className="machine-metrics">{[['Host', measured.hostname], ['OS', `${measured.os} ${measured.osVersion} · ${measured.arch}`], ['CPU', `${measured.cpuCount} cores`], ['Memory', `${formatBytes(measured.memFreeBytes)} free / ${formatBytes(measured.memTotalBytes)}`], ['Disk', `${formatBytes(measured.diskFreeBytes)} free / ${formatBytes(measured.diskTotalBytes)}`], ['Uptime', `${Math.floor(measured.uptimeSec / 60)} minutes`], ['Lemon', measured.lemonVersion], ['OS user', measured.user], ['Working directory', measured.defaultCwd]].map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>{measured.diskTotalBytes > 0 && measured.diskFreeBytes / measured.diskTotalBytes < .1 && <p className="error-notice">Low host disk space. Inspect Files and preview specific cleanup; deleting conversations does not free host disk.</p>}</>}</section><section className="panel stack"><h2>Capabilities and OS grants</h2><ErrorNotice error={caps.error} />{caps.data && <><p className="muted">{caps.data.os} · measured {formatTime(caps.data.measuredAtMs)} · {caps.data.stale || machine.status !== 'online' ? 'Stale / offline: do not infer permission' : 'Measured host configuration'}</p><div className="table-wrap"><table><thead><tr><th>Capability</th><th>Support</th><th>Configured access</th><th>OS grant</th><th>Tools / reason</th><th>Measurement</th></tr></thead><tbody>{caps.data.items.map(item => <tr key={item.id}><th scope="row">{item.name}</th><td>{item.supported ? 'Supported' : 'Unavailable'}</td><td>{item.configuredLevel.replaceAll('_', ' ')}</td><td>{item.osGrant.replaceAll('_', ' ')}</td><td>{item.tools.join(', ')}<br />{item.reason}</td><td>{formatTime(item.measuredAtMs)}{item.stale || machine.status !== 'online' ? ' · stale' : ''}</td></tr>)}</tbody></table></div><p className="small muted">Bot effective grants may be narrower than host configuration. OS access prompts must be approved on the relevant host, not this browser.</p></>}</section><section className="panel stack"><h2>Bots on this machine</h2><ErrorNotice error={bots.error} />{bots.data?.items.map(bot => <div className="list-row" key={bot.id}><button onClick={() => navigate({ screen: 'bot.overview', id: bot.id })}>{bot.name}</button><Badge>{machine.status === 'online' ? bot.activity.replaceAll('_', ' ') : 'offline'}</Badge></div>)}{bots.data?.items.length === 0 && <p className="muted">No visible Bots assigned.</p>}<ErrorNotice error={bots.moreError} />{bots.data?.nextCursor && <button disabled={bots.moreBusy} onClick={() => void bots.loadMore()}>Load more Bots</button>}</section><section className="panel stack"><h2>Owner host</h2><p>Owner: {machine.ownerUserId === snapshot.user.id ? 'You' : machine.ownerUserId}. Host access belongs to its owner.</p>{!manager && <p className="muted">Only this host’s owner may edit or detach it.</p>}{manager && <button onClick={() => { setEditRevision(machine.revision); setName(machine.name); setLabels(Object.entries(machine.labels).map(([key, value]) => ({ key, value }))); setEditing(!editing); }}>{editing ? 'Cancel editing' : 'Edit name and labels'}</button>}{editing && manager && <form className="stack" onSubmit={event => { event.preventDefault(); void intent.run(async () => { const labelMap: Record<string, string> = {}; for (const label of labels) { if (!label.key || label.key in labelMap) throw new Error('Label keys must be nonempty and unique.'); labelMap[label.key] = label.value; } await client.call('PATCH /machines/:id', { params: { id: machine.id }, body: { clientNonce: nonce(), revision: editRevision, name, labels: labelMap } }); await reload(); setEditing(false); }); }}><Field label="Machine name"><input required maxLength={120} value={name} onChange={event => setName(event.target.value)} /></Field><fieldset><legend>Machine labels</legend>{labels.map((label, index) => <div className="row" key={index}><input aria-label={`Label ${index + 1} key`} maxLength={256} required value={label.key} onChange={event => setLabels(values => values.map((item, position) => position === index ? { ...item, key: event.target.value } : item))} /><input aria-label={`Label ${index + 1} value`} maxLength={256} value={label.value} onChange={event => setLabels(values => values.map((item, position) => position === index ? { ...item, value: event.target.value } : item))} /><button type="button" onClick={() => setLabels(values => values.filter((_, position) => position !== index))}>Remove</button></div>)}<button type="button" disabled={labels.length >= 32} onClick={() => setLabels(values => [...values, { key: '', value: '' }])}>Add label</button></fieldset><button className="primary" disabled={intent.disabled}>Save current revision</button></form>}{manager && <div className="row"><button disabled={!online} onClick={() => navigate({ screen: 'machine.attach', id: machine.id })}>Reconnect same machine</button>{manager && <button onClick={() => navigate({ screen: 'machines.operations', id: machine.id })}>Machine operations</button>}<button className="danger" disabled={intent.disabled} onClick={() => void intent.run(async () => setConfirmation(await client.call('POST /machines/:id/preview', { params: { id: machine.id }, body: { clientNonce: nonce(), action: 'detach' } })))}>Preview detach</button></div>}<p className="small muted">Detach revokes execution trust and pauses affected work. It does not uninstall Lemon, erase host files/browser logins, remove SSH, or rebuild the machine.</p></section>{confirmation && <ConfirmDialog title="Detach machine" confirmation={confirmation} onCancel={() => setConfirmation(undefined)} onConfirm={async confirm => { await intent.run(async () => { await client.call('DELETE /machines/:id', { params: { id: machine.id }, body: { ...confirm, clientNonce: nonce() } }); setConfirmation(undefined); navigate({ screen: 'machines' }); }); }} disabled={intent.disabled} />}</>;
}
