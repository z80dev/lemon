import { useState } from 'react';
import { nonce, type Notification, type NotificationTarget } from '@lemon-bot/sdk';
import { useApp, type Route } from '../../app';
import { useQuery, ErrorNotice, Loading, Badge, formatTime } from '../../ui';
import { allPages, useIntent, IntentNotice, Toggle } from './shared';

export function InboxScreen() {
  const { client, snapshot, navigate, refresh, reportError } = useApp();
  const [unread, setUnread] = useState(false); const [showDismissed, setShowDismissed] = useState(false); const [kind, setKind] = useState<Notification['kind'] | ''>('');
  const notices = useQuery(`settings:inbox:${unread}`, () => allPages(cursor => client.call('GET /notifications', { query: { cursor, limit: 200, ...(unread ? { unread: true } : {}) } })));
  const intent = useIntent(async () => { await notices.reload(); await refresh(); });
  async function update(notice: Notification, body: { read?: boolean; dismissed?: boolean }) {
    const saved = await intent.run(() => client.call('PATCH /notifications/:id', { params: { id: notice.id }, body: { ...body, revision: notice.revision, clientNonce: nonce() } }));
    if (saved) { notices.setData(previous => previous?.map(item => item.id === saved.id ? saved : item)); await refresh().catch(reportError); }
  }
  async function open(target: NotificationTarget) {
    await intent.run(async () => {
      let route: Route;
      switch (target.kind) {
        case 'entry': {
          const conversationId = target.taskConversationId ?? target.conversationId;
          const [conversation, entry, bot] = await Promise.all([client.call('GET /conversations/:id', { params: { id: conversationId } }), client.call('GET /entries/:id', { params: { id: target.entryId } }), client.call('GET /bots/:id', { params: { id: target.botId } })]);
          if (entry.conversationId !== conversation.id || !conversation.botIds.includes(bot.id)) throw new Error('Notification target no longer matches this conversation. No alternate target was opened.');
          route = { screen: 'conversation', id: conversation.id, botId: bot.id, entryId: entry.id }; break;
        }
        case 'approval': {
          const [approval, conversation, entry] = await Promise.all([client.call('GET /approvals/:id', { params: { id: target.approvalId } }), client.call('GET /conversations/:id', { params: { id: target.conversationId } }), client.call('GET /entries/:id', { params: { id: target.entryId } })]);
          if (approval.botId !== target.botId || approval.conversationId !== conversation.id || approval.entryId !== entry.id || entry.conversationId !== conversation.id) throw new Error('Approval notification IDs do not match. Nothing was approved or opened.');
          route = { screen: 'conversation', id: conversation.id, botId: target.botId, entryId: entry.id }; break;
        }
        case 'machine': {
          const machine = await client.call('GET /machines/:id', { params: { id: target.machineId } });
          if (target.botId) { const bot = await client.call('GET /bots/:id', { params: { id: target.botId } }); if (bot.machineId !== machine.id) throw new Error('Bot has moved; this notification’s exact machine placement is no longer current.'); }
          route = { screen: 'machine.detail', id: machine.id, ...(target.botId ? { botId: target.botId } : {}) }; break;
        }
        case 'routine': {
          const routine = await client.call('GET /routines/:id', { params: { id: target.routineId } });
          if (routine.botId !== target.botId) throw new Error('Routine notification no longer matches its Bot.');
          if (target.routineRunId) { const run = await client.call('GET /routine-runs/:id', { params: { id: target.routineRunId } }); if (run.routineId !== routine.id) throw new Error('Routine run notification does not match its routine.'); }
          route = { screen: 'routines', id: routine.id, botId: target.botId, ...(target.routineRunId ? { tab: 'runs', entryId: target.routineRunId } : {}) }; break;
        }
      }
      navigate(route);
    });
  }
  const filtered = notices.data?.filter(notice => (showDismissed || notice.dismissedAtMs === null) && (!unread || notice.readAtMs === null) && (!kind || kind === notice.kind));
  return <div className="stack">
    <section className="panel stack">
      <div className="row spread"><h2>Notifications & attention</h2><button onClick={() => navigate({ screen: 'settings.notifications' })}>OS permission & delivery diagnostics</button></div>
      <p className="muted">Reading and dismissing clear notices only. They do not resolve requests, restart machines, undo errors, approve actions or cancel work. Targets are fetched and authorized before navigation; no token-bearing deep link is executed.</p>
      <div className="toolbar">
        <Toggle label="Unread only" checked={unread} onChange={setUnread} />
        <Toggle label="Show dismissed" checked={showDismissed} onChange={setShowDismissed} />
        <label>Kind<select value={kind} onChange={e => setKind(e.target.value as Notification['kind'] | '')}><option value="">All notices</option><option value="approval">Approvals</option><option value="question">Questions</option><option value="human_step">Human steps</option><option value="result">Results</option><option value="error">Errors</option><option value="machine">Machines</option></select></label>
        <button disabled={intent.disabled || !notices.data?.length} onClick={() => void (async () => {
          const throughAtMs = Math.max(...notices.data!.map(notice => notice.createdAtMs));
          const result = await intent.run(() => client.call('POST /notifications/read-all', { body: { throughAtMs, clientNonce: nonce() } }));
          if (result) await Promise.all([notices.reload(), refresh()]).catch(reportError);
        })()}>Mark read through latest loaded notice</button>
        <button disabled={notices.loading} onClick={() => void notices.reload().catch(reportError)}>Refresh inbox</button>
      </div>
    </section>
    <IntentNotice intent={intent} /><ErrorNotice error={notices.error} />{notices.loading && <Loading />}
    <ul className="list settings-inbox">{filtered?.map(notice => <li className={`panel stack ${notice.readAtMs === null ? 'settings-unread' : ''}`} key={notice.id}>
      <div className="row spread"><div className="row"><Badge tone={notice.kind === 'error' ? 'danger' : notice.kind === 'result' ? 'good' : 'warning'}>{notice.kind.replaceAll('_', ' ')}</Badge>{notice.readAtMs === null && <Badge>Unread</Badge>}{notice.dismissedAtMs !== null && <Badge>Dismissed</Badge>}</div><time dateTime={new Date(notice.createdAtMs).toISOString()}>{formatTime(notice.createdAtMs)}</time></div>
      <h3>{notice.title}</h3><p className="settings-notice-body">{notice.body}</p>
      <p className="small muted">{snapshot.bots.find(bot => bot.id === notice.botId)?.name ?? notice.botId ?? 'Workspace'}{notice.requestId && ` · Request ${notice.requestId}`}</p>
      <div className="row">
        <button className="primary" disabled={intent.disabled} onClick={() => void open(notice.target)}>Open exact {notice.target.kind}</button>
        <button disabled={intent.disabled} onClick={() => void update(notice, { read: notice.readAtMs === null })}>{notice.readAtMs === null ? 'Mark read' : 'Mark unread'}</button>
        <button disabled={intent.disabled} onClick={() => void update(notice, { dismissed: notice.dismissedAtMs === null })}>{notice.dismissedAtMs === null ? notice.kind === 'error' ? 'Clear error notice only' : 'Dismiss notice only' : 'Restore notice'}</button>
        {notice.requestId && <button onClick={() => void navigator.clipboard.writeText(`Request: ${notice.requestId}\nNotification: ${notice.id}\nConversation: ${notice.conversationId ?? 'none'}\nAt: ${new Date(notice.createdAtMs).toISOString()}\nKind: ${notice.kind}\nAttempts: not provided`).catch(reportError)}>Copy safe diagnostic IDs</button>}
      </div>
    </li>)}</ul>
    {filtered?.length === 0 && <section className="panel empty-state"><h2>No matching notifications</h2><p>Your inbox was read successfully. Try another filter.</p></section>}
  </div>;
}
