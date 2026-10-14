import { useEffect, useState } from 'react';
import { nonce, type AccessLevel, type Bot, type Confirmation, type Connector, type ConnectorAuth, type ConnectorConsent } from '@lemon-bot/sdk';
import { useApp, type Route } from '../../app';
import { Badge, ConfirmDialog, EmptyState, Field, PageHeader, formatTime, useQuery } from '../../ui';
import { useDeadlineClock, ActionNotice, BotSelect, ExternalLink, QueryState, canManage, usePages, useWorkAction } from './shared';

export function ConnectorsScreen({ route }: { route: Route }) {
  const { client } = useApp();
  const [botId, setBotId] = useState(route.botId ?? '');
  useEffect(() => { setBotId(route.botId ?? ''); }, [route.botId, route.id]);
  const requested = useQuery(`requested-connector:${route.id ?? ''}:${route.botId ?? ''}`, async () => {
    if (!route.id) return null;
    const bots: Bot[] = [];
    if (route.botId) bots.push(await client.call('GET /bots/:id', { params: { id: route.botId } }));
    else {
      let cursor: string | undefined;
      do {
        const page = await client.call('GET /bots', { query: { limit: 200, ...(cursor ? { cursor } : {}) } });
        bots.push(...page.items);
        cursor = page.nextCursor ?? undefined;
      } while (cursor);
    }
    for (const bot of bots) {
      let cursor: string | undefined;
      do {
        const page = await client.call('GET /bots/:id/connectors', { params: { id: bot.id }, query: { limit: 200, ...(cursor ? { cursor } : {}) } });
        const connector = page.items.find(item => item.id === route.id);
        if (connector) return { bot, connector };
        cursor = page.nextCursor ?? undefined;
      } while (cursor);
    }
    throw new Error('The requested connector is unavailable to this account.');
  });
  const selectedId = botId || requested.data?.bot.id || '';
  const selected = useQuery(`connector-selected-bot:${selectedId}`, async () => selectedId ? client.call('GET /bots/:id', { params: { id: selectedId } }) : null);
  const providers = useQuery('connector-provider-discovery', () => client.call('GET /integration-providers'));
  const [providerId, setProviderId] = useState('');
  const provider = providers.data?.find(item => item.kind === 'connector' && item.id === providerId);
  return <div className="page stack">
    <PageHeader title="Connect apps" eyebrow="Real accounts, explicit authority" />
    <BotSelect value={selectedId} onChange={setBotId} />
    <p className="muted">MCP posting/tools and channel listeners are separate connections. Source-service permissions remain the ceiling. Added is not authenticated.</p>
    <QueryState query={providers}>
      <Field label="Registered MCP provider"><select value={providerId} onChange={event => setProviderId(event.target.value)}><option value="">Inspect a registered provider</option>{providers.data?.filter(item => item.kind === 'connector').map(item => <option key={item.id} value={item.id}>{item.label} · {item.configured ? 'Configured' : 'Operator setup required'}</option>)}</select></Field>
      {provider && <section className="card"><h2>{provider.label}</h2><p>{provider.configured ? 'Configured provider; account authentication is separate.' : 'Operator configuration required.'}</p><p>Capabilities: {provider.capabilities.join(', ')}</p><ul>{provider.prerequisites.map(item => <li key={item}>{item}</li>)}</ul></section>}
    </QueryState>
    {route.id && <QueryState query={requested}>{requested.data && requested.data.bot.id === selectedId && <section aria-label="Requested connector"><h2>Requested account</h2><ConnectorDetails key={requested.data.connector.id} bot={requested.data.bot} connector={requested.data.connector} onSaved={requested.reload} /></section>}</QueryState>}
    <QueryState query={selected}>{selected.data && <BotConnectors key={selected.data.id} bot={selected.data} />}</QueryState>
    <Consents />
  </div>;
}

function BotConnectors({ bot }: { bot: Bot }) {
  const { client, snapshot, online, navigate } = useApp();
  const [adding, setAdding] = useState(false);
  const list = usePages(`connectors:${bot.id}`, query => client.call('GET /bots/:id/connectors', { params: { id: bot.id }, query }));
  const grants = usePages(`connector-grants:${bot.id}`, query => client.call('GET /bots/:id/grants', { params: { id: bot.id }, query }));
  const host = useQuery(`connector-host:${bot.machineId}`, () => client.call('GET /machines/:id', { params: { id: bot.machineId } }));
  const machine = host.data;
  const managed = canManage(bot, snapshot.user.id);
  return <><div className="panel spread"><div><><h2>{bot.name}</h2><QueryState query={host}>{host.data && <p>Assigned host: {host.data.name} · {host.data.status}</p>}</QueryState></><p>Machine: {machine?.name ?? bot.machineId} · {machine?.status ?? 'unavailable'}</p></div><button disabled={!managed || !online} onClick={() => setAdding(!adding)}>{adding ? 'Close setup' : 'Add HTTPS MCP server'}</button></div>{adding && <ConnectorEditor bot={bot} onSaved={async () => { setAdding(false); await list.reload(); await grants.reload(); }} />}<QueryState query={list}><div className="stack">{list.data?.items.map(connector => <ConnectorDetails key={connector.id} bot={bot} connector={connector} onSaved={async () => { await list.reload(); await grants.reload(); }} />)}</div>{!list.data?.items.length && <EmptyState title="No apps added">Connect a real streamable HTTPS MCP server. OAuth and host-secret setup are explicit.</EmptyState>}{list.controls}</QueryState><section className="panel stack"><h3>Actual Bot grants on {machine?.name ?? 'assigned host'}</h3><QueryState query={grants}>{grants.data?.items.map(grant => <div className="card" key={grant.id}><strong>{grant.capabilityId}</strong><p>Requested: {grant.requestedLevel} · Effective: {grant.effectiveLevel}</p><p>{grant.reasons.join(' · ')}</p></div>)}{grants.controls}</QueryState><button onClick={() => navigate({ screen: 'machine.secrets', id: bot.machineId, botId: bot.id })}>Manage host secrets (names only)</button></section></>;
}

function ConnectorDetails({ bot, connector, onSaved }: { bot: Bot; connector: Connector; onSaved: () => Promise<void> }) { useDeadlineClock(); const { client, snapshot, online } = useApp();
const action = useWorkAction();
const [editing, setEditing] = useState(false);
const [auth, setAuth] = useState<ConnectorAuth>();
const [confirmation, setConfirmation] = useState<Confirmation>();
const permitted = connector.ownerUserId === snapshot.user.id || (connector.shared && canManage(bot, snapshot.user.id));
useEffect(() => {
  if (!auth || auth.state !== 'pending') return;
  let stopped = false;
  let timer: number;
  const poll = async () => {
    try { const current = await client.call('GET /connector-auth/:id', { params: { id: auth.id } }); if (!stopped) { setAuth(current); if (current.state === 'connected') await onSaved(); else if (current.state === 'pending' && current.expiresAtMs > Date.now()) timer = window.setTimeout(poll, 3000); } }
    catch (error) { if (!stopped) await action.read(async () => { throw error; }); }
  };
  timer = window.setTimeout(poll, 3000);
  return () => { stopped = true; clearTimeout(timer); };
}, [auth?.id, auth?.state]);
return <article className="panel stack"><div className="spread"><h3>{connector.name} · {connector.accountLabel}</h3><Badge tone={connector.state === 'connected' ? 'good' : connector.state === 'blocked' || connector.state === 'failed' ? 'danger' : 'warning'}>{connector.state.replaceAll('_', ' ')}</Badge></div><p>{connector.url}</p><p>Account owner: {connector.ownerUserId === snapshot.user.id ? 'You' : connector.ownerUserId} · {connector.shared ? 'Deliberately shared service account' : 'Personal account; consent required for Team use'} · {connector.authKind}</p>{connector.lastError && <p className="error-notice" role="alert">{connector.lastError}</p>}<ActionNotice action={action} reconcile={async () => { await client.call('GET /bots/:id/connectors', { params: { id: bot.id } }); if (auth) setAuth(await client.call('GET /connector-auth/:id', { params: { id: auth.id } })); await onSaved(); }} /><div className="row"><button disabled={!permitted || !online || action.blocked || connector.state === 'blocked'} onClick={() => void action.run(async () => setAuth(await client.call('POST /connectors/:id/auth', { params: { id: connector.id }, body: { clientNonce: nonce() } })))}>{connector.state === 'connected' ? 'Reconnect / change account' : 'Authenticate / reconnect'}</button><button disabled={!permitted} onClick={() => setEditing(!editing)}>Edit account and bindings</button><button className="danger" disabled={!permitted || !online || action.blocked} onClick={() => void action.run(async () => setConfirmation(await client.call('POST /connectors/:id/preview', { params: { id: connector.id }, body: { action: 'disconnect', clientNonce: nonce() } })))}>Preview remove</button></div>{auth && <div className="card stack"><p>Authorization: {auth.state} · Expires {formatTime(auth.expiresAtMs)}</p>{auth.state === 'pending' && auth.expiresAtMs > Date.now() && <ExternalLink url={auth.authorizationUrl}>Open / reopen provider authorization</ExternalLink>}<button disabled={action.busy} onClick={() => void action.reconcile(async () => { setAuth(await client.call('GET /connector-auth/:id', { params: { id: auth.id } })); await onSaved(); })}>Check actual authorization status</button><p className="muted">Provider denial, admin restrictions and product policy blocks are not successful connections.</p></div>}{editing && <ConnectorEditor bot={bot} connector={connector} onSaved={async () => { setEditing(false); await onSaved(); }} />}<fieldset disabled={!permitted || !online || action.blocked}><legend>Enabled tools</legend>{connector.tools.map(tool => <label className="row" key={tool.name}><input type="checkbox" checked={tool.enabled} onChange={event => void action.run(async () => { await client.call('PATCH /connectors/:id', { params: { id: connector.id }, body: { revision: connector.revision, clientNonce: nonce(), tools: connector.tools.map(item => item.name === tool.name ? { ...item, enabled: event.target.checked } : item) } }); await onSaved(); })} />{tool.name}</label>)}{!connector.tools.length && <p className="muted">No tools discovered yet. Authenticate and check the real server.</p>}</fieldset>{confirmation && <ConfirmDialog title="Disconnect connector" confirmation={confirmation} onCancel={() => setConfirmation(undefined)} onConfirm={async confirm => { const result = await action.run(async () => { await client.call('DELETE /connectors/:id', { params: { id: connector.id }, body: { ...confirm, clientNonce: nonce() } }); await onSaved(); return true; }); if (result) setConfirmation(undefined); }} />}</article>; }

function ConnectorEditor({ bot, connector, onSaved }: { bot: Bot; connector?: Connector; onSaved: () => Promise<void> }) {
  const { client, snapshot, online, navigate } = useApp();
  const action = useWorkAction();
  const [name, setName] = useState(connector?.name ?? '');
  const [url, setUrl] = useState(connector?.url ?? '');
  const [accountLabel, setAccountLabel] = useState(connector?.accountLabel ?? '');
  const [authKind, setAuthKind] = useState<Connector['authKind']>(connector?.authKind ?? 'oauth');
  const [shared, setShared] = useState(connector?.shared ?? false);
  const [level, setLevel] = useState<AccessLevel>('read_only');
  const [bindings, setBindings] = useState<{ header: string; secretName: string }[]>([]);
  const [replaceBindings, setReplaceBindings] = useState(!connector);
  const host = useQuery(`connector-setup-host:${bot.machineId}`, () => client.call('GET /machines/:id', { params: { id: bot.machineId } }));
  const machine = host.data;
  const hostAccess = !!machine && (machine.ownerUserId === snapshot.user.id || machine.accessUserIds.includes(snapshot.user.id));
  const secrets = usePages(`connector-secrets:${bot.machineId}:${hostAccess}`, async query => hostAccess ? client.call('GET /machines/:id/secrets', { params: { id: bot.machineId }, query }) : { items: [], nextCursor: null });
  return <form className="card stack" onSubmit={event => { event.preventDefault(); void action.run(async () => { if (connector) await client.call('PATCH /connectors/:id', { params: { id: connector.id }, body: { name, accountLabel, ...(replaceBindings ? { secretBindings: bindings } : {}), revision: connector.revision, clientNonce: nonce() } }); else if (bot.ownerUserId === snapshot.user.id && hostAccess) await client.call('POST /bots/:id/connectors/setup', { params: { id: bot.id }, body: { name, url, accountLabel, shared, authKind, machineId: bot.machineId, secretBindings: bindings, requestedLevel: level, clientNonce: nonce() } }); else await client.call('POST /bots/:id/connectors', { params: { id: bot.id }, body: { name, url, accountLabel, shared, authKind, secretBindings: bindings, clientNonce: nonce() } }); await onSaved(); }); }}><><h3>{connector ? 'Update configuration' : 'Machine-labelled MCP setup'}</h3><QueryState query={host}>{host.data && <p>Assigned host: {host.data.name} · {host.data.status}</p>}</QueryState></><p>Destination: {machine?.name ?? bot.machineId}. Host credentials can be reachable by co-resident Bots; a persona is not a sandbox.</p><ActionNotice action={action} reconcile={async () => { await client.call('GET /bots/:id/connectors', { params: { id: bot.id } }); await onSaved(); }} /><fieldset className="stack" disabled={!online || action.blocked}><Field label="Server name"><input required value={name} onChange={event => setName(event.target.value)} /></Field><Field label="HTTPS streamable MCP URL"><input required type="url" pattern="https://.*" disabled={!!connector} value={url} onChange={event => setUrl(event.target.value)} /></Field><Field label="Account label" hint="Identify the actual account. Renaming is not switching OAuth identity; reconnect separately."><input required value={accountLabel} onChange={event => setAccountLabel(event.target.value)} /></Field>{!connector && <><Field label="Authentication"><select value={authKind} onChange={event => setAuthKind(event.target.value as Connector['authKind'])}><option value="oauth">Provider OAuth</option><option value="secret_headers">Named host-secret headers</option><option value="none">No authentication</option></select></Field><label className="row"><input type="checkbox" checked={shared} onChange={event => setShared(event.target.checked)} />Intentionally share a service account (never a borrowed private login)</label>{bot.ownerUserId === snapshot.user.id && hostAccess && <Field label="Requested host grant"><select value={level} onChange={event => setLevel(event.target.value as AccessLevel)}><option value="off">Off</option><option value="read_only">Read only</option><option value="read_interact">Read and interact</option></select></Field>}</>}{connector && <><p>Current secret header names: {connector.secretHeaderNames.join(', ') || 'None'}. Existing secret values and bindings are not disclosed.</p><label className="row"><input type="checkbox" checked={replaceBindings} onChange={event => setReplaceBindings(event.target.checked)} />Replace the complete header-to-secret-name mapping</label></>}{(authKind === 'secret_headers' || connector) && replaceBindings && <fieldset><legend>Secret bindings — names only</legend><QueryState query={secrets}>{bindings.map((binding, index) => <div className="row" key={index}><Field label={`HTTP header ${index + 1}`}><input required value={binding.header} onChange={event => setBindings(bindings.map((item, i) => i === index ? { ...item, header: event.target.value } : item))} /></Field><Field label={`Host secret name ${index + 1}`}><select required value={binding.secretName} onChange={event => setBindings(bindings.map((item, i) => i === index ? { ...item, secretName: event.target.value } : item))}><option value="">Choose existing secret name</option>{secrets.data?.items.map(secret => <option key={secret.id} value={secret.name}>{secret.name} · {secret.scope} · {secret.description}</option>)}</select></Field><button type="button" onClick={() => setBindings(bindings.filter((_, i) => i !== index))}>Remove binding {index + 1}</button></div>)}{secrets.controls}</QueryState><button type="button" disabled={!hostAccess} onClick={() => setBindings([...bindings, { header: '', secretName: '' }])}>Add named-secret binding</button>{!hostAccess && <p className="muted">Explicit machine access is required to list or select host secrets.</p>}<button type="button" onClick={() => navigate({ screen: 'machine.secrets', id: bot.machineId, botId: bot.id })}>Create / replace masked host secret</button><p className="muted">Only destination encrypted secrets resolve ${'{LEMON_SECRET:NAME}'}. Never enter tokens in header fields or chat.</p></fieldset>}<button className="primary">{connector ? 'Save configuration' : 'Add actual connector'}</button></fieldset></form>;
}

function Consents() {
  const { client } = useApp();
  const action = useWorkAction();
  const [expiryHours, setExpiryHours] = useState('');
  
  const list = usePages('connector-consents', query => client.call('GET /consents', { query }));
  return <section className="panel stack"><h2>Your account consent grants</h2><ActionNotice action={action} reconcile={async () => { await client.call('GET /consents'); await list.reload(); }} /><Field label="Optional remembered grant expiry (hours)"><input type="number" min="1" value={expiryHours} onChange={event => setExpiryHours(event.target.value)} /></Field><QueryState query={list}>{list.data?.items.map(consent => <ConsentCard key={consent.id} consent={consent} expiryHours={expiryHours} reload={list.reload} />)}{!list.data?.items.length && <EmptyState title="No account consent requests or remembered grants" />}{list.controls}</QueryState></section>;
}

function ConsentCard({ consent, expiryHours, reload }: { consent: ConnectorConsent; expiryHours: string; reload: () => Promise<void> }) { useDeadlineClock(); const { client, snapshot, online, navigate } = useApp();
const action = useWorkAction();
const [revoking, setRevoking] = useState(false);
const context = useQuery(`consent-context:${consent.id}`, async () => {
  const bot = await client.call('GET /bots/:id', { params: { id: consent.botId } });
  let cursor: string | undefined;
  do {
    const page = await client.call('GET /bots/:id/connectors', { params: { id: bot.id }, query: { limit: 200, ...(cursor ? { cursor } : {}) } });
    const connector = page.items.find(item => item.id === consent.connectorId);
    if (connector) return { bot, connector };
    cursor = page.nextCursor ?? undefined;
  } while (cursor);
  throw new Error('The account for this consent is no longer available. Reconcile the request before granting access.');
});
const pending = consent.gate.state === 'pending' && consent.gate.expiresAtMs > Date.now();
const targeted = consent.accountOwnerUserId === snapshot.user.id && consent.gate.targetUserId === snapshot.user.id;
return <article className="card stack">
  <QueryState query={context}>{context.data && <><h3>{context.data.connector.name} · {context.data.connector.accountLabel}</h3><p>Server: {context.data.connector.url} · Bot: {context.data.bot.name} · Account owner: {consent.accountOwnerUserId === snapshot.user.id ? 'You' : consent.accountOwnerUserId}</p><p>{context.data.connector.shared ? 'Intentionally shared service account' : 'Personal OAuth account; no implicit Team credential lending'}</p></>}</QueryState>
  <p>{consent.gate.state} · Scope: {consent.scope} · Grant expiry: {formatTime(consent.expiresAtMs)} · Request expiry: {formatTime(consent.gate.expiresAtMs)}</p>
  <ActionNotice action={action} reconcile={async () => { await client.call('GET /consents'); await reload(); }} />
  <button onClick={() => navigate({ screen: 'conversation', id: consent.conversationId, entryId: consent.entryId, botId: consent.botId })}>Review exact private request</button>
  {pending && <div className="row">{(['allow_once', 'allow_bot', 'decline'] as const).map(decision => <button key={decision} disabled={!targeted || !online || action.blocked || !context.data || !!context.error || (decision === 'allow_bot' && !!expiryHours && (!Number.isFinite(Number(expiryHours)) || Number(expiryHours) < 1))} onClick={() => void action.run(async () => {
    await client.call('POST /consents/:id/resolve', { params: { id: consent.id }, body: { decision, revision: consent.revision, clientNonce: nonce(), ...(decision === 'allow_bot' && expiryHours ? { expiresAtMs: Date.now() + Number(expiryHours) * 3600000 } : {}) } });
    await reload();
  })}>{decision === 'allow_once' ? 'Allow once' : decision === 'allow_bot' ? 'Allow this Bot' : 'Decline'}</button>)}</div>}
  {consent.gate.state === 'approved' && (revoking ? <div className="stack"><p>Revoke future use of this exact account grant? Prior actions are not undone.</p><button className="danger" disabled={!targeted || !online || action.blocked} onClick={() => void action.run(async () => {
    await client.call('DELETE /consents/:id', { params: { id: consent.id }, body: { revision: consent.revision, clientNonce: nonce() } });
    setRevoking(false); await reload();
  })}>Confirm revoke grant</button><button onClick={() => setRevoking(false)}>Keep grant</button></div> : <button disabled={!targeted} onClick={() => setRevoking(true)}>Revoke future account access…</button>)}
</article>; }
