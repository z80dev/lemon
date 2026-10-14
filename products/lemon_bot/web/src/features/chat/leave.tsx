import { useEffect, useState } from 'react';
import { LemonBotError, nonce, type Conversation, type GroupLeave, type Member, type Run } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, Field, formatTime } from '../../ui';
import { IntentNotice, useIntent } from './common';

interface PendingLeave { request: GroupLeave; provenRefusal: boolean; runIds: string[] }
export function GroupLeavePanel({ conversation, members, changed, onDelete }: {
  conversation: Conversation; members?: Member[]; changed: (room: Conversation) => void; onDelete: () => void;
}) {
  const { client, snapshot, realtime, online, forgetConversation, refresh, navigate } = useApp();
  const key = `lemonbot.leave:${snapshot.workspace.id}:${snapshot.user.id}:${conversation.id}`;
  const [pending, setPending] = useState<PendingLeave | undefined>(() => {
    try {
      const value: unknown = JSON.parse(sessionStorage.getItem(key) || 'null');
      if (!value || typeof value !== 'object' || !('request' in value) || !value.request || typeof value.request !== 'object' || !('clientNonce' in value.request) || typeof value.request.clientNonce !== 'string') return;
      const request: GroupLeave = { clientNonce: value.request.clientNonce };
      if ('newOwnerUserId' in value.request && typeof value.request.newOwnerUserId === 'string') request.newOwnerUserId = value.request.newOwnerUserId;
      const runIds = 'runIds' in value && Array.isArray(value.runIds) ? value.runIds.filter((id): id is string => typeof id === 'string') : [];
      return { request, runIds, provenRefusal: 'provenRefusal' in value && value.provenRefusal === true };
    } catch { return; }
  });
  const [review, setReview] = useState(!!pending);
  const [successor, setSuccessor] = useState(pending?.request.newOwnerUserId || '');
  const [acceptedScope, setAcceptedScope] = useState(false);
  const [runs, setRuns] = useState<Run[]>([]);
  const intent = useIntent();
  const read = useIntent();
  const stop = useIntent();
  const owner = conversation.ownerUserId === snapshot.user.id;
  const participant = conversation.humanUserIds.includes(snapshot.user.id);
  const otherIds = conversation.humanUserIds.filter(id => id !== snapshot.user.id);
  const eligible = members?.filter(member => member.enabled && otherIds.includes(member.userId)) || [];
  useEffect(() => {
    if (pending) sessionStorage.setItem(key, JSON.stringify(pending)); else sessionStorage.removeItem(key);
  }, [pending, key]);
  useEffect(() => {
    if (!realtime) return;
    return realtime.subscribe(frame => {
      if (frame.type === 'event' && frame.event === 'run.upserted') {
        const run = frame.payload;
        setRuns(current => current.some(item => item.id === run.id) ? current.map(item => item.id === run.id && item.revision <= run.revision ? run : item) : current);
      }
    });
  }, [realtime]);
  if (conversation.kind !== 'group' || !participant) return null;

  async function reconcile() {
    let actual: Conversation;
    try { actual = await client.call('GET /conversations/:id', { params: { id: conversation.id } }); }
    catch (failure) {
      if (failure instanceof LemonBotError && (failure.code === 'not_found' || failure.code === 'forbidden')) {
        sessionStorage.removeItem(key); forgetConversation(conversation.id); navigate({ screen: 'home' }); return;
      }
      throw failure;
    }
    if (!actual.humanUserIds.includes(snapshot.user.id)) {
      sessionStorage.removeItem(key); forgetConversation(conversation.id); navigate({ screen: 'home' }); return;
    }
    changed(actual);
    const fixed = pending?.runIds || [];
    const current = await Promise.all(fixed.map(id => client.call('GET /runs/:id', { params: { id } })));
    setRuns(current);
    if (current.some(run => !['succeeded', 'failed', 'cancelled'].includes(run.status))) throw new Error('Membership is retained. The displayed fixed runs have not reached authoritative terminal state; cancellation acknowledgment is not sufficient.');
    if (pending && !pending.provenRefusal) throw new Error('You are still a member, but the original Leave outcome is not confirmed. Its nonce is retained. Keep checking membership; no new Leave is submitted automatically.');
    setPending(undefined); setAcceptedScope(false);
  }
  async function leave() {
    if (pending || !acceptedScope || !otherIds.length || (owner && !eligible.some(member => member.userId === successor))) return;
    const request: GroupLeave = { clientNonce: nonce(), ...(owner ? { newOwnerUserId: successor } : {}) };
    const record: PendingLeave = { request, provenRefusal: false, runIds: [] };
    setPending(record); sessionStorage.setItem(key, JSON.stringify(record));
    const result = await intent.run(() => client.call('POST /conversations/:id/leave', { params: { id: conversation.id }, body: request }));
    if (result) {
      sessionStorage.removeItem(key); setPending(undefined); forgetConversation(conversation.id); navigate({ screen: 'home' });
      await refresh(); return;
    }
    const failure = intent.lastError.current;
    if (failure instanceof LemonBotError) {
      const ids = failure.details?.runIds;
      const runIds = Array.isArray(ids) ? ids.filter((id): id is string => typeof id === 'string') : [];
      const next = { request, provenRefusal: !failure.outcomeUnknown && (failure.code === 'conflict' || failure.retrySafe), runIds };
      setPending(next); sessionStorage.setItem(key, JSON.stringify(next));
      if (runIds.length) await read.run(async () => setRuns(await Promise.all(runIds.map(id => client.call('GET /runs/:id', { params: { id } })))));
    }
  }
  return <section className="stack">
    <button type="button" onClick={() => setReview(value => !value)} aria-expanded={review}>Leave this group</button>
    {review && <div className="card stack">
      <h3>Leave without deleting everyone’s work</h3>
      <p>You lose access to this room’s history and composer, and future room notifications stop. Remaining members keep the room, Bots, files and history. Independent memory, private chats and already-delivered external content remain.</p>
      <p>The backend must establish terminal state for your room work and delegated work returning here, and cancel your pending gates, before departure. It does not cancel another participant’s work or undo completed external effects.</p>
      {!otherIds.length ? <><p role="status">You are the last human participant. Leaving cannot create an ownerless room. Review an explicit conversation deletion instead.</p>{owner && <button className="danger" disabled={!online || !!pending} onClick={onDelete}>Preview deleting this last-member room</button>}</> : <>
        {owner && <Field label="Explicit new group creator" hint="Only an enabled existing human participant can receive group maintenance. No workspace ownership or private Bot authority transfers.">
          <select required value={successor} disabled={!!pending || intent.busy} onChange={event => { setSuccessor(event.target.value); setAcceptedScope(false); }}>
            <option value="">Choose an existing participant</option>{eligible.map(member => <option key={member.userId} value={member.userId}>{member.displayName} · {member.email}</option>)}
          </select>
        </Field>}
        <label className="row"><input type="checkbox" checked={acceptedScope} disabled={!!pending || intent.busy} onChange={event => setAcceptedScope(event.target.checked)}/>I reviewed my access loss{owner ? ' and this explicit group-maintenance successor' : ''}.</label>
        <button className="danger" disabled={!online || !!pending || intent.busy || intent.uncertain || !acceptedScope || (owner && !eligible.some(member => member.userId === successor))} onClick={() => void leave().catch(error => void read.run(async () => { throw error; }))}>Confirm my departure</button>
      </>}
      <IntentNotice intent={intent} reconcile={reconcile}/><IntentNotice intent={read} reconcile={reconcile}/>
      {pending && <div className="error-notice"><p>{pending.provenRefusal ? 'Departure refused; membership remains until your fixed work is terminal and you review a new explicit Leave.' : 'Departure outcome is not confirmed. Do not submit a new nonce or assume you left.'}</p><p className="small">Preserved intent: <code>{pending.request.clientNonce}</code></p><button disabled={!online || read.busy} onClick={() => void intent.reconcile(reconcile)}>Read membership and fixed run state</button>{pending.runIds.map(id => <p key={id}>Affected run <code>{id}</code></p>)}</div>}
      {runs.map(run => <div className="panel stack" key={run.id}><p><code>{run.id}</code> · {run.status.replaceAll('_', ' ')} · {formatTime(run.completedAtMs)}</p>{run.error && <ErrorNotice error={new LemonBotError(run.error)}/>}<div className="row"><button onClick={() => navigate({ screen: 'conversation', id: run.conversationId })}>Inspect this authorized work</button>{run.initiatorUserId === snapshot.user.id && !['succeeded', 'failed', 'cancelled'].includes(run.status) && <button disabled={!online || stop.busy || stop.uncertain || run.status === 'outcome_unknown'} onClick={() => void stop.run(async () => { const actual = await client.call('POST /runs/:id/cancel', { params: { id: run.id }, body: { clientNonce: nonce(), reason: 'Explicitly stop my work before group departure' } }); setRuns(current => current.map(item => item.id === actual.id ? actual : item)); })}>Request Stop for my run</button>}</div></div>)}
      <IntentNotice intent={stop} reconcile={reconcile}/>
    </div>}
  </section>;
}
