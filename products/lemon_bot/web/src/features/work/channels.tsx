import { useEffect, useState } from 'react';
import { nonce, type ChannelBinding, type ChannelLinkFlow, type ChannelPrincipalLink, type ChannelSetupFlow } from '@lemon-bot/sdk';
import { useApp, type Route } from '../../app';
import { Badge, EmptyState, Field, PageHeader, formatTime, useQuery } from '../../ui';
import { useDeadlineClock, ActionNotice, BotSelect, CopyButton, ExternalLink, QueryState, canManage, usePages, useWorkAction } from './shared';

export function ChannelsScreen({ route }: { route: Route }) {
  const { client, snapshot, online } = useApp();
  const action = useWorkAction();
  const [botId, setBotId] = useState(route.botId ?? '');
  const [adapter, setAdapter] = useState<ChannelBinding['adapter']>('slack');
  const [providerId, setProviderId] = useState('');
  const [accountLabel, setAccountLabel] = useState('');
  const [accountId, setAccountId] = useState('');
  const [target, setTarget] = useState('');
  const [flow, setFlow] = useState<ChannelSetupFlow>();
  const selectedBot = useQuery(`channel-bot:${botId}`, async () => botId ? client.call('GET /bots/:id', { params: { id: botId } }) : null);
  const bot = selectedBot.data ?? undefined;
  const managed = !!bot && canManage(bot, snapshot.user.id);
  const bindings = usePages(`channels:${botId}`, query => client.call('GET /channels', { query: { ...query, ...(botId ? { botId } : {}) } }));
  const links = usePages('channel-principal-links', query => client.call('GET /channels/principal-links', { query }));
  const providers = useQuery('channel-providers', () => client.call('GET /channels/providers'));
  const provider = providers.data?.find(item => item.id === providerId);
  const requested = useQuery(`requested-channel:${route.id ?? ''}:${route.botId ?? ''}`, async () => {
    if (!route.id) return null;
    let cursor: string | undefined;
    do {
      const page = await client.call('GET /channels', { query: { limit: 200, ...(cursor ? { cursor } : {}), ...(route.botId ? { botId: route.botId } : {}) } });
      const binding = page.items.find(item => item.id === route.id);
      if (binding) return binding;
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    throw new Error('The requested channel binding is unavailable to this account.');
  });
  useEffect(() => { setBotId(route.botId ?? ''); }, [route.botId, route.id]);
  useEffect(() => { if (requested.data) setBotId(requested.data.botId); }, [requested.data?.id]);
  useEffect(() => {
    if (!flow || !['pending', 'awaiting_admin'].includes(flow.state)) return;
    let stopped = false;
    let timer: number;
    const poll = async () => { try { const current = await client.call('GET /channels/setup/:id', { params: { id: flow.id } }); if (!stopped) { setFlow(current); if (current.state === 'connected') await bindings.reload(); else if (['pending', 'awaiting_admin'].includes(current.state)) timer = window.setTimeout(poll, 4000); } } catch (error) { if (!stopped) await action.read(async () => { throw error; }); } };
    timer = window.setTimeout(poll, 4000);
    return () => { stopped = true; clearTimeout(timer); };
  }, [flow?.id, flow?.state]);
  return <div className="page stack">
    <PageHeader title="Channels" eyebrow="Real provider installations and verified principals" />
    <p className="muted">Slack per-Bot apps require an owned Bot, registered OAuth/signing/app-install provider, provider workspace administrator approval and actual provider permissions. Other adapters require configured Lemon accounts. Channel installation is separate from MCP posting and routine listeners.</p>
    <ActionNotice action={action} reconcile={async () => { await client.call('GET /channels'); if (flow) setFlow(await client.call('GET /channels/setup/:id', { params: { id: flow.id } })); await bindings.reload(); }} />
    <BotSelect value={botId} onChange={setBotId} />
    <QueryState query={selectedBot}>{selectedBot.data && <p>Selected Bot: {selectedBot.data.name}</p>}</QueryState>
    {route.id && <QueryState query={requested}>{requested.data && <section aria-label="Requested channel binding"><h2>Requested channel</h2><BindingEditor key={requested.data.id} binding={requested.data} reload={async () => { await requested.reload(); await bindings.reload(); }} /></section>}</QueryState>}
    <section className="panel stack">
      <h2>Discovered channel providers</h2>
      <QueryState query={providers}>
        <Field label="Registered provider"><select required value={providerId} onChange={event => {
          setProviderId(event.target.value);
          const selected = providers.data?.find(item => item.id === event.target.value);
          if (selected) setAdapter(selected.adapter);
        }}><option value="">Choose a real provider</option>{providers.data?.map(item => <option key={item.id} value={item.id}>{item.label} · {item.adapter} · {item.configured ? 'Configured' : 'Operator setup required'}</option>)}</select></Field>
        {!providers.data?.length && <EmptyState title="No eligible channel providers registered">Your operator must configure adapter credentials, inbound verification, OAuth/install permissions and allowed callbacks.</EmptyState>}
        {provider && <div className="card stack"><Badge tone={provider.configured ? 'good' : 'warning'}>{provider.configured ? 'Configured, not necessarily connected' : 'Operator setup required'}</Badge><p>Capabilities: {provider.capabilities.join(', ') || 'None'}</p><p>Per-Bot app installation: {provider.supportsBotAppInstall ? 'Supported' : 'Not supported'}</p><ul>{provider.prerequisites.map(item => <li key={item}>{item}</li>)}</ul></div>}
      </QueryState>
      <form className="stack" onSubmit={event => { event.preventDefault(); if (!provider) return; void action.run(async () => setFlow(await client.call('POST /channels/setup', { body: { botId, adapter: provider.adapter, providerId: provider.id, accountLabel, redirectUri: window.location.origin, clientNonce: nonce() } }))); }}>
        <fieldset className="stack" disabled={!managed || !online || action.blocked || !provider?.configured}>
          <Field label="Account label"><input required value={accountLabel} onChange={event => setAccountLabel(event.target.value)} /></Field>
          <button className="primary" disabled={provider?.adapter === 'slack' && !provider.supportsBotAppInstall}>Authorize / install actual provider app</button>
        </fieldset>
      </form>
      {!managed && <p className="muted">Select a Bot you own to change channel setup.</p>}
      {flow && <div className="card stack">
        <Badge tone={flow.state === 'connected' ? 'good' : 'warning'}>{flow.state.replaceAll('_', ' ')}</Badge>
        {flow.state === 'awaiting_admin' && <p>Provider workspace administrator approval is still pending. Installation is not complete.</p>}
        {flow.error && <p className="error-notice" role="alert">{flow.error}</p>}
        {['pending', 'awaiting_admin'].includes(flow.state) && <ExternalLink url={flow.authorizationUrl}>Open / reopen provider install</ExternalLink>}
        <button onClick={() => void action.reconcile(async () => { setFlow(await client.call('GET /channels/setup/:id', { params: { id: flow.id } })); await bindings.reload(); })}>Poll actual installation status</button>
        {flow.channelBindingId && <p>Actual binding: {flow.channelBindingId}</p>}
      </div>}
    </section>
    <section className="panel stack">
      <h2>Bind an existing configured adapter account</h2>
      <form className="stack" onSubmit={event => { event.preventDefault(); void action.run(async () => { await client.call('POST /channels', { body: { botId, adapter, accountId, target, enabled: true, clientNonce: nonce() } }); await bindings.reload(); }); }}>
        <fieldset className="stack" disabled={!managed || !online || action.blocked || !provider?.configured}>
          <p>Adapter: {adapter}. Use a real provider-configured account and destination; adding a row does not authenticate it.</p>
          <Field label="Configured adapter account ID"><input required value={accountId} onChange={event => setAccountId(event.target.value)} /></Field>
          <Field label="Provider channel / destination"><input required value={target} onChange={event => setTarget(event.target.value)} /></Field>
          <button>Bind configured account</button>
        </fieldset>
      </form>
    </section>
    <QueryState query={bindings}>
      {bindings.data?.items.map(binding => <BindingEditor key={binding.id} binding={binding} reload={bindings.reload} />)}
      {!bindings.data?.items.length && <EmptyState title="No channel bindings">Install a provider app or bind a genuinely configured adapter account.</EmptyState>}
      {bindings.controls}
    </QueryState>
    <section className="panel stack">
      <h2>Verified principal links</h2>
      <PrincipalLinkForm reload={links.reload} bindings={bindings.data?.items ?? []} />
      <QueryState query={links}>{links.data?.items.map(link => <PrincipalLinkRow key={link.id} link={link} reload={links.reload} />)}{links.controls}</QueryState>
      <p className="muted">Mapped DMs wake the Bot. A top-level explicit mention begins channel participation; subsequent replies use the same thread context. Unlinked users cannot borrow the owner's authority or spend. Private OAuth credentials are never automatically lent.</p>
    </section>
  </div>;
}

function BindingEditor({ binding, reload }: { binding: ChannelBinding; reload: () => Promise<void> }) {
  const { client, snapshot, online } = useApp();
  const action = useWorkAction();
  const [target, setTarget] = useState(binding.target);
  const [enabled, setEnabled] = useState(binding.enabled);
  const [removing, setRemoving] = useState(false);
  const selectedBot = useQuery(`binding-bot:${binding.botId}`, () => client.call('GET /bots/:id', { params: { id: binding.botId } }));
  const bot = selectedBot.data;
  const managed = !!bot && canManage(bot, snapshot.user.id);
  return <article className="panel stack"><div className="spread"><><h3>{bot?.name ?? binding.botId} · {binding.adapter} · {binding.accountId}</h3><QueryState query={selectedBot}>{selectedBot.data && <p>Maintained Bot: {selectedBot.data.name}</p>}</QueryState></><Badge tone={binding.state === 'connected' ? 'good' : 'warning'}>{binding.state}</Badge></div><p>Inbound: {binding.capabilities.inbound ? 'Supported' : 'Unavailable'} · Outbound: {binding.capabilities.outbound ? 'Supported' : 'Unavailable'} · Events: {binding.capabilities.events.join(', ') || 'None advertised'}</p>{binding.lastError && <p className="error-notice" role="alert">{binding.lastError}</p>}<ActionNotice action={action} reconcile={async () => { await client.call('GET /channels', { query: { botId: binding.botId } }); await reload(); }} /><form className="stack" onSubmit={event => { event.preventDefault(); void action.run(async () => { await client.call('PATCH /channels/:id', { params: { id: binding.id }, body: { target, enabled, revision: binding.revision, clientNonce: nonce() } }); await reload(); }); }}><fieldset disabled={!managed || !online || action.blocked} className="stack"><Field label="Channel / target"><input required value={target} onChange={event => setTarget(event.target.value)} /></Field><label className="row"><input type="checkbox" checked={enabled} onChange={event => setEnabled(event.target.checked)} />Enabled (separate from provider connection state)</label><button>Save binding</button></fieldset></form>{removing ? <div className="stack"><p>Remove this binding and request actual provider uninstall / revoke? The product Bot and its history remain. Provider failure may require workspace-admin cleanup; it is not a successful removal.</p><button className="danger" disabled={!managed || !online || action.blocked} onClick={() => void action.run(async () => { await client.call('DELETE /channels/:id', { params: { id: binding.id }, body: { revision: binding.revision, clientNonce: nonce() } }); await reload(); })}>Confirm remove channel</button><button onClick={() => setRemoving(false)}>Keep channel</button></div> : <button className="danger" disabled={!managed} onClick={() => setRemoving(true)}>Remove channel…</button>}</article>;
}

function PrincipalLinkForm({ bindings, reload }: { bindings: ChannelBinding[]; reload: () => Promise<void> }) { useDeadlineClock(); const { client, online } = useApp();
const action = useWorkAction();
const [bindingId, setBindingId] = useState('');
const [flow, setFlow] = useState<ChannelLinkFlow>();
useEffect(() => {
  if (!flow || !['issued', 'awaiting_external'].includes(flow.state) || flow.expiresAtMs <= Date.now()) return;
  let stopped = false;
  let timer: number;
  const poll = async () => {
    try {
      const current = await client.call('GET /channels/principal-links/flows/:id', { params: { id: flow.id } });
      if (!stopped) {
        setFlow(current);
        if (['issued', 'awaiting_external'].includes(current.state) && current.expiresAtMs > Date.now()) timer = window.setTimeout(poll, 3000);
      }
    } catch (error) { if (!stopped) await action.read(async () => { throw error; }); }
  };
  timer = window.setTimeout(poll, 3000);
  return () => { stopped = true; clearTimeout(timer); };
}, [flow?.id, flow?.state]);
return <div className="stack">
  <ActionNotice action={action} reconcile={async () => { if (flow) setFlow(await client.call('GET /channels/principal-links/flows/:id', { params: { id: flow.id } })); await client.call('GET /channels/principal-links'); await reload(); }} />
  <Field label="Channel binding"><select required disabled={!!flow && flow.expiresAtMs > Date.now() && !['expired', 'completed', 'cancelled'].includes(flow.state)} value={bindingId} onChange={event => setBindingId(event.target.value)}><option value="">Select real binding</option>{bindings.map(binding => <option key={binding.id} value={binding.id}>{binding.adapter} · {binding.accountId} · {binding.target}</option>)}</select></Field>
  <button disabled={!bindingId || !online || action.blocked || (!!flow && !['expired', 'completed', 'cancelled'].includes(flow.state) && flow.expiresAtMs > Date.now())} onClick={() => void action.run(async () => setFlow(await client.call('POST /channels/principal-links/start', { body: { channelBindingId: bindingId, clientNonce: nonce() } })))}>Issue my one-use external linking code</button>
  {flow && <section className="card stack">
    <Badge>{flow.expiresAtMs <= Date.now() && flow.state !== 'completed' ? 'Expired' : flow.state.replaceAll('_', ' ')}</Badge>
    <p>{flow.instructions}</p><p>Expires: {formatTime(flow.expiresAtMs)}</p>
    {flow.linkCode && flow.expiresAtMs > Date.now() && <><Field label="Present this one-use code in your actual private provider DM"><input readOnly value={flow.linkCode} /></Field><CopyButton value={flow.linkCode} label="Copy my link code" /></>}
    <button disabled={action.busy} onClick={() => void action.reconcile(async () => setFlow(await client.call('GET /channels/principal-links/flows/:id', { params: { id: flow.id } })))}>Check verified external identity</button>
    {flow.state === 'verified' && <><p>Observed provider identity: <strong>{flow.externalDisplayName ?? flow.externalUserId}</strong> ({flow.externalUserId}). Confirm that this is your own account.</p><button className="primary" disabled={!online || action.blocked || !flow.externalUserId || !flow.verificationCode || flow.expiresAtMs <= Date.now()} onClick={() => void action.run(async () => {
      if (!flow.externalUserId || !flow.verificationCode) return;
      await client.call('POST /channels/principal-links', { body: { channelBindingId: flow.channelBindingId, externalUserId: flow.externalUserId, verificationCode: flow.verificationCode, clientNonce: nonce() } });
      setFlow(await client.call('GET /channels/principal-links/flows/:id', { params: { id: flow.id } }));
      await reload();
    })}>Confirm my verified provider account</button></>}
  </section>}
  <p className="muted">The signed provider DM supplies your identity; you cannot type an arbitrary user mapping. Initial link codes and final verification proofs are distinct. No link code grants execution authority until explicit verified-account confirmation.</p>
</div>; }

function PrincipalLinkRow({ link, reload }: { link: ChannelPrincipalLink; reload: () => Promise<void> }) {
  const { client, snapshot, online } = useApp();
  const action = useWorkAction();
  const [remove, setRemove] = useState(false);
  const context = useQuery(`principal-link-binding:${link.channelBindingId}`, async () => {
    let cursor: string | undefined;
    do {
      const page = await client.call('GET /channels', { query: { limit: 200, ...(cursor ? { cursor } : {}) } });
      const binding = page.items.find(item => item.id === link.channelBindingId);
      if (binding) return { binding, bot: await client.call('GET /bots/:id', { params: { id: binding.botId } }) };
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    throw new Error('This linked channel is unavailable. Only your own verified principal link can be removed.');
  });
  const permitted = link.userId === snapshot.user.id;
  return <article className="card stack"><><p>{link.externalUserId} → {link.userId === snapshot.user.id ? 'You' : link.userId} · {link.verified ? 'Verified' : 'Not verified'} · binding {link.channelBindingId}</p><QueryState query={context}>{context.data && <p>Channel: {context.data.binding.adapter} · {context.data.binding.accountId} · {context.data.binding.target} · Bot: {context.data.bot.name}</p>}</QueryState></><ActionNotice action={action} reconcile={async () => { await client.call('GET /channels/principal-links'); await reload(); }} />{remove ? <><p>Unlink this external identity? Future messages cannot use its product principal.</p><button className="danger" disabled={!permitted || !online || action.blocked} onClick={() => void action.run(async () => { await client.call('DELETE /channels/principal-links/:id', { params: { id: link.id }, body: { revision: link.revision, clientNonce: nonce() } }); await reload(); })}>Confirm unlink</button><button onClick={() => setRemove(false)}>Keep link</button></> : <button disabled={!permitted} onClick={() => setRemove(true)}>Unlink…</button>}</article>;
}
