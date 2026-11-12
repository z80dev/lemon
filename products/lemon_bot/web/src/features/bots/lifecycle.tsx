import { useState } from 'react';
import { LemonBotError, nonce, type Bot, type Confirmation } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ConfirmDialog, ErrorNotice, useAction } from '../../ui';
import { canManage, IntentNotice, type Intent, useIntent } from './shared';

export function BotRecovery({ bot, reload }: { bot: Bot; reload: () => Promise<void> }) {
  const [review, setReview] = useState(0);
  if (!bot.lifecycle) return null;
  const check = async () => { await reload(); setReview(value => value + 1); };
  return <BotRecoveryPanel key={`${bot.id}:${review}`} bot={bot} reload={reload} check={check} />;
}

function BotRecoveryPanel({ bot, reload, check }: { bot: Bot; reload: () => Promise<void>; check: () => Promise<void> }) {
  const { client, online, snapshot } = useApp();
  const intent = useIntent();
  const read = useAction();
  const lifecycle = bot.lifecycle!;
  const editable = canManage(bot, snapshot.user.id);
  const setup = lifecycle.action === 'create' || lifecycle.action === 'import';
  const title = setup ? 'Bot setup' : lifecycle.action === 'readdress' ? 'Bot address' : lifecycle.action === 'delete' ? 'Bot deletion' : 'Bot change';
  const recover = (endpoint: 'POST /bots/:id/finish-setup' | 'POST /bots/:id/readdress') => void intent.run(async () => {
    const updated = await client.call(endpoint, { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision } });
    if (updated.lifecycle?.status === 'outcome_unknown') intent.markUnknown();
    await reload();
  });
  return <section className="panel stack" aria-label={`${title} status`}>
    <h2>{title} {lifecycle.status === 'running' ? 'in progress' : 'needs attention'}</h2>
    <p role={lifecycle.status === 'failed' ? 'alert' : 'status'}>{lifecycle.message}</p>
    {lifecycle.step && <p>Step: {lifecycle.step}</p>}
    {lifecycle.status === 'outcome_unknown' && <p className="error-notice" role="alert">Blocked: the previous step’s receipt is not confirmed. Nothing will be retried without confirmation.</p>}
    {setup && <p className="muted">Finish setup continues this Bot in place, keeping its identity and private conversation. Do not create another Bot to retry setup.</p>}
    <div className="row">
      {lifecycle.canFinishSetup && <button className="primary" disabled={!editable || intent.disabled} onClick={() => recover('POST /bots/:id/finish-setup')}>Finish setup</button>}
      {lifecycle.canReaddress && <button className="primary" disabled={!editable || intent.disabled} onClick={() => recover('POST /bots/:id/readdress')}>Update address</button>}
      {lifecycle.canDelete && <BotDeleteButton bot={bot} intent={intent} disabled={!editable || intent.disabled} />}
      {!intent.error && !intent.uncertain && <button disabled={!online || read.busy || intent.busy} onClick={() => void read.run(check)}>Check status</button>}
    </div>
    <ErrorNotice error={read.error} />
    <IntentNotice intent={intent} reconcile={check} />
  </section>;
}

export function BotDeleteButton({ bot, intent, disabled, label = 'Delete' }: { bot: Bot; intent: Intent; disabled: boolean; label?: string }) {
  const { client, refresh, navigate } = useApp();
  const [confirmation, setConfirmation] = useState<Confirmation>();
  return <>
    <button className="danger" disabled={disabled || bot.lifecycle?.canDelete === false} onClick={() => void intent.run(async () => {
      const preview = await client.call('POST /bots/:id/preview', { params: { id: bot.id }, body: { clientNonce: nonce(), action: 'delete' } });
      setConfirmation(preview);
    })}>{label}</button>
    {confirmation && <ConfirmDialog title="Review delete and residual data" confirmation={confirmation} disabled={intent.disabled || bot.lifecycle?.canDelete === false} onCancel={() => setConfirmation(undefined)} onConfirm={async confirm => {
      await intent.run(async () => {
        await client.call('DELETE /bots/:id', { params: { id: bot.id }, body: { ...confirm, clientNonce: nonce() } });
        await refresh();
        navigate({ screen: 'bot.create' });
      });
    }} />}
  </>;
}

export function createdBotId(error: unknown): string | undefined {
  return error instanceof LemonBotError ? error.resourceIds[0] : undefined;
}

export function BotCreationRecovery({ intent }: { intent: Intent }) {
  const { snapshot, navigate } = useApp();
  const id = createdBotId(intent.error);
  if (!id && !intent.uncertain) return null;
  return <section className="panel stack">
    <h2>{id ? 'Bot saved — finish its setup' : 'Current Bots — check before creating another'}</h2>
    <p>Do not create another Bot to retry setup. Open the saved Bot to check its status, finish setup or review deletion.</p>
    {id ? <button onClick={() => navigate({ screen: 'bot.overview', id })}>Open Bot setup</button> : snapshot.bots.map(bot => <button key={bot.id} onClick={() => navigate({ screen: 'bot.overview', id: bot.id })}>{bot.name}</button>)}
  </section>;
}
