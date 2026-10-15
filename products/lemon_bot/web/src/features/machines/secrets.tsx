import { useRef, useState } from 'react';
import { nonce } from '@lemon-bot/sdk';
import type { Machine, Secret } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, EmptyState, ErrorNotice, Field, Loading } from '../../ui';
import { IntentNotice, useIntent, usePages } from './shared';

export function MachineSecrets({ machine }: { machine: Machine }) {
  const { client, online, reportError } = useApp()
  const secrets = usePages(`secrets:${machine.id}`, cursor => client.call('GET /machines/:id/secrets', { params: { id: machine.id }, query: { cursor, limit: 100 } }), item => item.name);
  const bots = usePages(`secret-scope-bots:${machine.id}`, cursor => client.call('GET /bots', { query: { machineId: machine.id, cursor, limit: 100 } }), item => item.id);
  const [replacement, setReplacement] = useState<Secret>();
  const [name, setName] = useState('');
  const [description, setDescription] = useState('');
  const [scope, setScope] = useState<Secret['scope']>('machine');
  const [botId, setBotId] = useState('');
  const [replaceAccepted, setReplaceAccepted] = useState(false);
  const value = useRef<HTMLInputElement>(null);
  const intent = useIntent();
  const available = online && machine.status === 'online';
  function edit(secret?: Secret) {
    if (value.current) value.current.value = '';
    setReplacement(secret); setName(secret?.name || ''); setDescription(secret?.description || ''); setScope(secret?.scope || 'machine'); setBotId(secret?.botId || ''); setReplaceAccepted(false);
    value.current?.focus();
  }
  return <div className="stack"><IntentNotice intent={intent} reconcile={async () => { await client.call('GET /machines/:id/secrets', { params: { id: machine.id }, query: { limit: 200 } }); await secrets.reload(); if (value.current) value.current.value = ''; }} /><section className="panel stack"><div className="row spread"><h2>Secret names, never values</h2><button disabled={secrets.loading} onClick={() => void secrets.reload().catch(reportError)}>Refresh store</button></div><p className="machine-warning">Machine secrets may be reached by co-resident Bots and privileged OS users. Bot scope labels intended use; it is not OS isolation. Product responses, transcripts and events never reveal values. No browser auto-fill or credential copying is implied.</p><ErrorNotice error={secrets.error} />{secrets.loading && !secrets.data && <Loading />}{secrets.data?.items.length === 0 && <EmptyState title="No secret names in this store" />}<ul className="list">{secrets.data?.items.map(secret => <li className="list-row" key={secret.name}><div className="stack"><strong><code>{secret.name}</code> <span aria-label="Value hidden">••••••••</span></strong><span>{secret.description}</span><Badge>{secret.scope === 'machine' ? 'Shared machine scope' : `Bot: ${bots.data?.items.find(bot => bot.id === secret.botId)?.name || secret.botId}`}</Badge></div><div className="row"><button disabled={!available || intent.busy} onClick={() => edit(secret)}>Replace value / metadata</button><button className="danger" disabled={!available || intent.disabled} onClick={() => { if (!window.confirm(`Delete secret ${secret.name} from ${machine.name}? This removes the stored credential for its ${secret.scope} scope. It does not revoke any provider session or account.`)) return; void intent.run(async () => { await client.call('DELETE /machines/:id/secrets/:name', { params: { id: machine.id, name: secret.name }, body: { clientNonce: nonce() } }); await secrets.reload(); if (replacement?.name === secret.name) edit(); }); }}>Delete name</button></div></li>)}</ul><ErrorNotice error={secrets.moreError} />{secrets.data?.nextCursor && <button disabled={secrets.moreBusy} onClick={() => void secrets.loadMore()}>Load more secret names</button>}</section><form className="panel stack" autoComplete="off" onSubmit={event => { event.preventDefault(); void intent.run(async () => {
    const input = value.current;
    if (!input) return;
    const secretValue = input.value;
    if (!secretValue || new TextEncoder().encode(secretValue).length > 32768) throw new Error('Enter a nonempty secret no larger than 32 KiB.');
    let cursor: string | undefined;
    do {
      const page = await client.call('GET /machines/:id/secrets', { params: { id: machine.id }, query: { limit: 200, cursor } });
      if (!replacement && page.items.some(secret => secret.name === name)) throw new Error('This name already exists. Select Replace and explicitly approve replacement.');
      cursor = page.nextCursor || undefined;
    } while (cursor);
    try {
      await client.call('PUT /machines/:id/secrets/:name', { params: { id: machine.id, name }, body: { clientNonce: nonce(), description, value: secretValue, scope, ...(scope === 'bot' ? { botId } : {}) } });
      edit(); await secrets.reload();
    } finally { input.value = ''; }
  }); }}><div className="row spread"><h2>{replacement ? `Replace ${replacement.name}` : 'Add a named secret'}</h2>{replacement && <button type="button" onClick={() => edit()}>Cancel replacement</button>}</div><Field label="Secret name" hint="Uppercase letters, digits and underscores; starts with a letter; up to 64 characters."><input required pattern="[A-Z][A-Z0-9_]{0,63}" value={name} disabled={!!replacement || intent.busy} onChange={event => setName(event.target.value)} /></Field><Field label="Description (not secret)"><input value={description} disabled={intent.busy} onChange={event => setDescription(event.target.value)} /></Field><Field label="Scope"><select value={scope} disabled={intent.busy} onChange={event => setScope(event.target.value as Secret['scope'])}><option value="machine">Machine — shared destination store</option><option value="bot">Named Bot — still on this machine</option></select></Field>{scope === 'bot' && <><ErrorNotice error={bots.error} /><Field label="Bot on this host"><select required value={botId} disabled={intent.busy} onChange={event => setBotId(event.target.value)}><option value="">Choose Bot</option>{bots.data?.items.map(bot => <option key={bot.id} value={bot.id}>{bot.name}</option>)}</select></Field><ErrorNotice error={bots.moreError} />{bots.data?.nextCursor && <button type="button" disabled={bots.moreBusy} onClick={() => void bots.loadMore()}>Load more Bots</button>}</>}<Field label="Write-only secret value" hint="Entered only for this explicit request; cleared after dispatch. Never saved in browser storage or automatically retried."><input ref={value} type="password" required autoComplete="new-password" maxLength={32768} disabled={intent.busy} spellCheck={false} /></Field>{replacement && <label className="row"><input type="checkbox" checked={replaceAccepted} onChange={event => setReplaceAccepted(event.target.checked)} />Replace the existing stored value and scope for {replacement.name}.</label>}<button className="primary" disabled={intent.disabled || !available || (scope === 'bot' && !botId) || (!!replacement && !replaceAccepted)}>{replacement ? 'Replace securely' : 'Add securely'}</button></form></div>;
}
