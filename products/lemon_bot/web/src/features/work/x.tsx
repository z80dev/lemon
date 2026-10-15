import { useEffect, useState } from 'react';
import { nonce, type LemonBotClient, type XConnection, type XConnectResult } from '@lemon-bot/sdk';
import { useApp, type Route } from '../../app';
import { Badge, EmptyState, Field, PageHeader, useQuery } from '../../ui';
import { ActionNotice, BotSelect, ExternalLink, QueryState, usePages, useWorkAction } from './shared';

export function XScreen({ route }: { route: Route }) {
  const { client, snapshot, online } = useApp();
  const action = useWorkAction();
  const [botId, setBotId] = useState(route.botId ?? '');
  const [auth, setAuth] = useState<XConnectResult>();
  const provider = useQuery('x-provider', () => client.call('GET /x/provider'));
  const connections = usePages('x-connections', query => client.call('GET /x/connections', { query }));
  const selectedMainBot = useQuery(`x-owned-selection:${botId}`, async () => botId ? client.call('GET /bots/:id', { params: { id: botId } }) : null);
  useEffect(() => {
    if (!auth || auth.connection.state !== 'pending') return;
    let stopped = false;
    let timer: number;
    const poll = async () => { try { const current = await readConnection(client, auth.connection.id);  if (!stopped) { if (current) setAuth({ ...auth, connection: current }); await connections.reload(); if (!current || current.state === 'pending') timer = window.setTimeout(poll, 4000); } } catch (error) { if (!stopped) await action.read(async () => { throw error; }); } };
    timer = window.setTimeout(poll, 4000);
    return () => { stopped = true; clearTimeout(timer); };
  }, [auth?.connection.id, auth?.connection.state]);
  return <div className="page stack"><PageHeader title="X mentions" eyebrow="Explicit OAuth, private Bot work" /><ActionNotice action={action} reconcile={async () => { await client.call('GET /x/connections'); await connections.reload(); }} /><QueryState query={provider}>{provider.data ? <section className="panel stack"><h2>{provider.data.label}</h2><Badge tone={provider.data.configured ? 'good' : 'warning'}>{provider.data.configured ? 'Ready to connect' : 'Not available on this server'}</Badge><p>Mention {provider.data.publicHandle} on X to ask your Bot to work.</p><p>Permissions requested: {provider.data.oauthScopes.join(', ') || 'None'}</p>{!provider.data.configured && <p>Ask your administrator to set up X.</p>}<p>Supported media: {provider.data.allowedMedia.join(', ') || 'None'} · Region restrictions: {provider.data.deniedCountries.join(', ') || 'None advertised'}</p><ul>{provider.data.prerequisites.map(item => <li key={item}>{item}</li>)}</ul><p>Capabilities: {provider.data.capabilities.join(', ')}</p><form className="stack" onSubmit={event => { event.preventDefault(); void action.run(async () => { setAuth(await client.call('POST /x/connections', { body: { mainBotId: botId, redirectUri: window.location.origin, clientNonce: nonce() } })); await connections.reload(); }); }}><><BotSelect value={botId} onChange={setBotId} label="Your owned main Bot" /><QueryState query={selectedMainBot}>{selectedMainBot.data && <p>Selected owned main Bot: {selectedMainBot.data.name}</p>}</QueryState></><button className="primary" disabled={!botId || !online || action.blocked || !provider.data.configured || !(selectedMainBot.data?.ownerUserId === snapshot.user.id)}>Connect my X account through OAuth</button></form></section> : <EmptyState title="X is not available on this server">Ask your administrator to set up X.</EmptyState>}</QueryState>{auth && <section className="card stack"><p>Actual account connection: {auth.connection.state}</p>{auth.connection.state === 'pending' && <ExternalLink url={auth.authorizationUrl}>Open / reopen X authorization</ExternalLink>}<button disabled={action.busy} onClick={() => void action.reconcile(async () => { const current = await readConnection(client, auth.connection.id);  if (current) setAuth({ ...auth, connection: current }); await connections.reload(); })}>Check actual OAuth result</button></section>}<QueryState query={connections}>{connections.data?.items.map(connection => <ConnectionEditor onAuthorize={setAuth} key={connection.id} connection={connection} reload={connections.reload} />)}{!connections.data?.items.length && <EmptyState title="No X accounts connected" />}{connections.controls}</QueryState><section className="panel stack"><h2>What wakes your Bot</h2><p>Only a verified mention from your connected account explicitly tagging the configured public handle can start accepted work. Replied/quoted posts and photos are contextual, untrusted inputs. Accepted public confirmation is posted by the provider only after a real run receipt; results stay in your selected private Bot conversation.</p><p className="muted">Disabled accounts, unsupported media, moderation, region and spend limits can refuse or ignore work with a real reason. Public-source browsing needs no private login. Protected X account tools require separate explicit MCP scopes and native tool-policy review; this is not blanket read-all authorization.</p></section></div>;
}

function ConnectionEditor({ connection, reload, onAuthorize }: { connection: XConnection; reload: () => Promise<void>; onAuthorize: (result: XConnectResult) => void }) {
  const { client, snapshot, online, navigate } = useApp();
  const action = useWorkAction();
  const [botId, setBotId] = useState(connection.mainBotId);
  const [enabled, setEnabled] = useState(connection.enabled);
  const [remove, setRemove] = useState(false);
  const owned = connection.userId === snapshot.user.id;
  const selectedBot = useQuery(`x-main-bot:${connection.mainBotId}`, () => client.call('GET /bots/:id', { params: { id: connection.mainBotId } }));
  const bot = selectedBot.data;
  return <section className="panel stack"><div className="spread"><><h2>{connection.username && connection.externalAccountId ? connection.state === 'connected' ? `@${connection.username}` : `Previously verified @${connection.username}` : 'Account not yet verified'}</h2><QueryState query={selectedBot}>{selectedBot.data && <p>Private results Bot: {selectedBot.data.name}</p>}</QueryState></><Badge tone={connection.state === 'connected' ? 'good' : 'warning'}>{connection.state.replaceAll('_', ' ')}</Badge></div><p>External account: {connection.externalAccountId || 'Not verified yet'} · Main Bot: {bot?.name ?? connection.mainBotId}</p>{connection.lastError && <p className="error-notice" role="alert">{connection.lastError}</p>}<ActionNotice action={action} reconcile={async () => { await client.call('GET /x/connections'); await reload(); }} /><form className="stack" onSubmit={event => { event.preventDefault(); void action.run(async () => { await client.call('PATCH /x/connections/:id', { params: { id: connection.id }, body: { mainBotId: botId, enabled, revision: connection.revision, clientNonce: nonce() } }); await reload(); }); }}><fieldset className="stack" disabled={!owned || !online || action.blocked}><BotSelect value={botId} onChange={setBotId} label="Owned main Bot for private results" /><label className="row"><input type="checkbox" checked={enabled} onChange={event => setEnabled(event.target.checked)} />Enable verified mention dispatch</label><button>Save main Bot and mention state</button></fieldset></form><div className="row"><button disabled={!owned || !online || action.blocked} onClick={() => void action.run(async () => { const result = await client.call('POST /x/connections', { body: { mainBotId: connection.mainBotId, redirectUri: window.location.origin, clientNonce: nonce() } }); onAuthorize(result); await reload(); })}>Reconnect through real OAuth</button>{bot && <button onClick={() => navigate({ screen: 'conversation', id: bot.mainConversationId, botId: bot.id })}>Open private Bot results</button>}</div>{remove ? <><p>Disconnect @{connection.username}? Future mention dispatch stops. External provider sessions/cleanup are governed by the provider; product history remains.</p><button className="danger" disabled={!owned || !online || action.blocked} onClick={() => void action.run(async () => { await client.call('DELETE /x/connections/:id', { params: { id: connection.id }, body: { revision: connection.revision, clientNonce: nonce() } }); await reload(); })}>Confirm disconnect X</button><button onClick={() => setRemove(false)}>Keep connection</button></> : <button className="danger" disabled={!owned} onClick={() => setRemove(true)}>Disconnect…</button>}</section>;
}

async function readConnection(client: LemonBotClient, id: string) {
  let cursor: string | undefined;
  do {
    const page = await client.call('GET /x/connections', { query: { limit: 200, ...(cursor ? { cursor } : {}) } });
    const connection = page.items.find(item => item.id === id);
    if (connection) return connection;
    cursor = page.nextCursor ?? undefined;
  } while (cursor);
  throw new Error('This X account connection is unavailable. Do not assume authorization or dispatch succeeded.');
}
