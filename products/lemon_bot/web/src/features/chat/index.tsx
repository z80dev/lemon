import { useEffect, useRef, useState } from 'react';
import type { FeedbackCreate, Run, TranscriptEntry, TranscriptEvent } from '@lemon-bot/sdk';
import { nonce } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import type { Route } from '../../app';
import { EmptyState, ErrorNotice, Field, Loading, PageHeader, formatTime, useQuery } from '../../ui';
import { TranscriptCard } from './cards';
import { Composer } from './composer';
import { ConversationDetails } from './details';
import { AttachmentLink, RichText } from './files';
import { IntentNotice, copyText, mergeEntries, useClock, useIntent } from './common';
import './chat.css';
export { FileViewer } from './files';
export { VoiceOverlay } from './voice';

function EventLine({ event }: { event: TranscriptEvent }) {
  const { snapshot, navigate } = useApp(); const botName = (id: string) => snapshot.bots.find(bot => bot.id === id)?.name || id;
  switch (event.type) {
    case 'name_changed': return <span>Conversation renamed to {event.name}</span>;
    case 'channel_connected': case 'channel_disconnected': return <button onClick={() => navigate({ screen: 'integrations.channels', id: event.channelBindingId })}>{event.type === 'channel_connected' ? 'Channel connected' : 'Channel disconnected'}</button>;
    case 'routine_changed': return <button onClick={() => navigate({ screen: 'routines', id: event.routineId })}>Routine {event.action}</button>;
    case 'task_changed': return <button onClick={() => navigate({ screen: 'conversation', id: event.conversationId })}>Task {event.status.replaceAll('_', ' ')}</button>;
    case 'bot_added': case 'bot_removed': return <button onClick={() => navigate({ screen: 'bot.overview', id: event.botId })}>{botName(event.botId)} · {event.type.replaceAll('_', ' ')}</button>;
    case 'handoff': return <button onClick={() => navigate({ screen: 'conversation', id: event.targetConversationId })}>{botName(event.sourceBotId)} → {botName(event.targetBotId)}: {event.text}</button>;
    case 'machine_moved': return <button onClick={() => navigate({ screen: 'machine.detail', id: event.targetMachineId })}>{botName(event.botId)} moved from {event.sourceMachineId} to {event.targetMachineId}</button>;
    default: return <span>Unsupported activity. Update the client.</span>;
  }
}
function ReplyQuote({ id, jump }: { id: string; jump: (id: string) => void }) {
  const { client } = useApp(); const query = useQuery(`entry:${id}`, () => client.call('GET /entries/:id', { params: { id } })); const entry = query.data;
  return <blockquote className="chat-quote"><button onClick={() => jump(id)}>{entry ? `${entry.actor.displayName}: ${entry.kind === 'message' ? entry.text.slice(0, 180) : entry.kind === 'user_attachment' ? 'File attachment' : entry.kind === 'card' ? entry.card.type.replaceAll('_', ' ') : entry.kind}` : query.error ? 'Quoted entry missing or unavailable to you' : 'Loading quoted entry…'}</button></blockquote>;
}
function EntryActions({ entry, changed, reply }: { entry: TranscriptEntry; changed: (entry: TranscriptEntry) => void; reply: (id: string) => void }) {
  const { client, snapshot, online, reportError } = useApp(); const intent = useIntent(); const [showFeedback, setShowFeedback] = useState(false); const [sentiment, setSentiment] = useState<FeedbackCreate['sentiment']>('good'); const [reasons, setReasons] = useState<NonNullable<FeedbackCreate['reasons']>>([]); const [comment, setComment] = useState(''); const [feedbackSent, setFeedbackSent] = useState(false);
  const text = entry.kind === 'message' ? entry.text : entry.kind === 'card' && entry.card.type === 'text' ? entry.card.text : undefined;
  return <><div className="chat-entry-actions row"><button onClick={() => reply(entry.id)}>Reply</button>{text !== undefined && <button onClick={() => void copyText(text).catch(reportError)}>Copy text</button>}{['👍', '❤️', '🎉', '👀'].map(emoji => { const reaction = entry.reactions.find(item => item.emoji === emoji); const own = !!reaction?.userIds.includes(snapshot.user.id); return <button key={emoji} aria-label={`${own ? 'Remove' : 'Add'} ${emoji} reaction`} aria-pressed={own} disabled={!online || intent.busy || intent.uncertain} onClick={() => void intent.run(async () => changed(await client.call(own ? 'DELETE /entries/:id/reactions' : 'POST /entries/:id/reactions', { params: { id: entry.id }, body: { clientNonce: nonce(), emoji } })))}>{emoji}{reaction?.userIds.length ? ` ${reaction.userIds.length}` : ''}</button>; })}{entry.actor.kind === 'bot' && <button aria-expanded={showFeedback} onClick={() => setShowFeedback(!showFeedback)}>Feedback</button>}</div><IntentNotice intent={intent} reconcile={async () => changed(await client.call('GET /entries/:id', { params: { id: entry.id } }))} />{showFeedback && <form className="panel stack" onSubmit={event => { event.preventDefault(); void intent.run(async () => { await client.call('POST /entries/:id/feedback', { params: { id: entry.id }, body: { clientNonce: nonce(), sentiment, reasons, comment } }); setFeedbackSent(true); }); }}><Field label="Feedback"><select value={sentiment} onChange={event => setSentiment(event.target.value as FeedbackCreate['sentiment'])}><option value="good">Good</option><option value="bad">Bad</option></select></Field><fieldset><legend>Reasons (optional)</legend>{(['not_requested', 'inaccurate', 'low_quality', 'slow'] as const).map(reason => <label key={reason} className="row"><input type="checkbox" checked={reasons.includes(reason)} onChange={event => setReasons(current => event.target.checked ? [...current, reason] : current.filter(value => value !== reason))} />{reason.replaceAll('_', ' ')}</label>)}</fieldset><Field label="Comment"><textarea value={comment} onChange={event => setComment(event.target.value)} /></Field><button disabled={!online || intent.busy || intent.uncertain}>Save my feedback</button>{feedbackSent && <p role="status">Your feedback was saved. It does not approve an action.</p>}</form>}</>;
}
function EntryView({ entry, attachments, jump, reply, changed }: { entry: TranscriptEntry; attachments: string[]; jump: (id: string) => void; reply: (id: string) => void; changed: (entry: TranscriptEntry) => void }) {
  const { snapshot, reportError, navigate } = useApp();
  if (entry.targetedUserId && entry.targetedUserId !== snapshot.user.id) return null;
  let content;
  switch (entry.kind) {
    case 'message': content = <><RichText text={entry.text} />{entry.streaming && <span className="muted small" role="status">Provisional streamed answer — awaiting authoritative completion</span>}{[...new Set([...entry.attachmentIds, ...attachments])].map(id => <AttachmentLink key={id} id={id} />)}</>; break;
    case 'card': {
      const room = snapshot.conversations.find(conversation => conversation.id === entry.conversationId);
      const privateTypes: Record<string, true> = { secret_request: true, human_step: true, email_draft: true, slack_draft: true, message_draft: true, permission_request: true, auto_review_approval: true, local_tool_permission: true, publish_approval: true };
      content = (room?.kind === 'group' || room?.kind === 'channel') && privateTypes[entry.card.type] ? <p className="error-notice">Sensitive requests must be reviewed in your authorized private task or DM, not in this shared room.</p> : <TranscriptCard card={entry.card} />; break;
    }
    case 'user_attachment': content = <AttachmentLink id={entry.attachmentId} />; break;
    case 'tool_call': content = <details className="chat-tool"><summary>{entry.title} · {entry.status}</summary><p>{entry.tool}</p>{entry.detail && <p>{entry.detail}</p>}<p className="muted small">Sanitized activity summary, not raw command arguments.</p></details>; break;
    case 'mcp_app': content = <div className="stack"><h3>MCP app snapshot</h3><span className="badge">{entry.state}</span><p>{entry.resourceUri}</p>{entry.state === 'available' && entry.snapshotAttachmentId ? <AttachmentLink id={entry.snapshotAttachmentId} /> : <p className="muted">Snapshot unavailable or expired. Ask the Bot to rerun it; opening this row executes nothing.</p>}<button onClick={() => navigate({ screen: 'connect.apps', id: entry.connectorId })}>Inspect connector</button></div>; break;
    case 'notice': content = <div className={entry.severity === 'error' ? 'error-notice' : 'chat-notice'} role={entry.severity === 'error' ? 'alert' : 'status'}><p>{entry.text}</p>{entry.requestId && <button onClick={() => void copyText(entry.requestId || '').catch(reportError)}>Copy diagnostic request ID {entry.requestId}</button>}</div>; break;
    case 'event': content = <div className="chat-event"><EventLine event={entry.event} /></div>; break;
    case 'feedback': content = <div><span className="badge">{entry.feedback.sentiment}</span><p>{entry.feedback.reasons.map(reason => reason.replaceAll('_', ' ')).join(', ')}</p><p>{entry.feedback.comment}</p></div>; break;
    case 'voice_call': content = <div className="stack"><h3>Voice call · {entry.voiceSession.state}</h3><p>{Math.floor(entry.voiceSession.durationMs / 1000)}s · ended {formatTime(entry.voiceSession.endedAtMs)} · feedback {entry.voiceSession.feedback || 'None'}</p><div className="row">{entry.voiceSession.transcriptEntryIds.map(id => <button key={id} onClick={() => jump(id)}>Transcript entry {id}</button>)}</div><p className="muted">Voice call summary, not a persisted voice memo. Follow-up work remains in chat.</p></div>; break;
    default: content = <p className="error-notice">Unsupported transcript entry. Update this client. Entry ID is retained; no resolving action is available.</p>;
  }
  return <article className={`chat-entry ${entry.actor.kind === 'user' ? 'chat-user-entry' : ''}`} data-entry-id={entry.id} data-seq={entry.seq} tabIndex={-1} id={`entry-${entry.id}`} aria-label={`${entry.actor.displayName}, ${formatTime(entry.timestampMs)}`}><header className="row spread"><strong>{entry.actor.displayName}</strong><time dateTime={new Date(entry.timestampMs).toISOString()} className="muted small">{formatTime(entry.timestampMs)}</time></header>{entry.replyToEntryId && <ReplyQuote id={entry.replyToEntryId} jump={jump} />}<div className={entry.kind === 'card' ? 'chat-card panel' : 'chat-entry-body'}>{content}</div>{!['event', 'tool_call', 'feedback'].includes(entry.kind) && <EntryActions entry={entry} changed={changed} reply={reply} />}</article>;
}

export function ConversationScreen({ route }: { route: Route }) {
  if (!route.id) return <EmptyState title="Select a conversation">Open a Bot or task to read its real conversation.</EmptyState>;
  return <ConversationBody key={route.id} route={route} id={route.id} />;
}
function ConversationBody({ id, route }: { id: string; route: Route }) {
  const { client, realtime, snapshot, online, navigate } = useApp(); const conversationQuery = useQuery(`conversation:${id}`, () => client.call('GET /conversations/:id', { params: { id } })); const history = useQuery(`entries:${id}`, () => client.call('GET /conversations/:id/entries', { params: { id }, query: { limit: 100 } }));
  const runQuery = useQuery(`runs:${id}`, () => client.call('GET /runs', { query: { conversationId: id, limit: 200 } })); const runsRef = useRef<Run[]>([]); const [runs, setRuns] = useState<Run[]>([]);
  const [entries, setEntries] = useState<TranscriptEntry[]>([]); const entriesRef = useRef(entries); entriesRef.current = entries; const [replyId, setReplyId] = useState<string | null>(null); const [showDetails, setShowDetails] = useState(false); const [older, setOlder] = useState(false); const [paging, setPaging] = useState(false); const [pageError, setPageError] = useState<unknown>(); const [liveError, setLiveError] = useState<unknown>(); const [find, setFind] = useState(''); const [findQuery, setFindQuery] = useState(''); const [typing, setTyping] = useState<{ userId: string; expiresAtMs: number }[]>([]); const [jumped, setJumped] = useState(false);
  const scroller = useRef<HTMLDivElement>(null); const end = useRef<HTMLDivElement>(null); const pinned = useRef(true); const initialScroll = useRef(false); const lastRead = useRef(0); const unreadBoundary = useRef<number | undefined>(undefined); const clock = useClock(); const stopIntent = useIntent(); const readFailure = useRef(false); const [readError, setReadError] = useState<unknown>(); const readInFlight = useRef(false); const visibleThrough = useRef(0); const visibleEntries = useRef(new Set<string>()); const [readVersion, setReadVersion] = useState(0); const refetching = useRef(new Set<string>());
  const forwardSeq = useRef(0); const [newer, setNewer] = useState(false);
  const [routePending, setRoutePending] = useState(!!route.entryId); const [routeRejected, setRouteRejected] = useState(false);
  const search = useQuery(`conversation-search:${id}:${findQuery}`, async () => {
    if (!findQuery) return { items: [], nextCursor: null };
    const first = await client.call('GET /search', { query: { q: findQuery, kinds: ['message'], conversationId: id, limit: 200 } });
    const items = [...first.items]; let cursor = first.nextCursor;
    while (cursor) { const page = await client.call('GET /search', { query: { q: findQuery, kinds: ['message'], conversationId: id, limit: 200, cursor } }); items.push(...page.items); cursor = page.nextCursor; }
    return { items, nextCursor: null };
  });
  function upsert(incoming: TranscriptEntry[]) { entriesRef.current = mergeEntries(entriesRef.current, incoming); setEntries(entriesRef.current); if (pinned.current) requestAnimationFrame(() => end.current?.scrollIntoView({ block: 'end', behavior: 'instant' })); }
  function updateRun(run: Run) { const current = runsRef.current.find(value => value.id === run.id); if (current && current.revision > run.revision) return; const next = [...runsRef.current.filter(value => value.id !== run.id), run]; runsRef.current = next; setRuns(next); }
  useEffect(() => { if (runQuery.data) { for (const run of runQuery.data.items) updateRun(run); } }, [runQuery.data]);
  useEffect(() => { if (history.data) { upsert(history.data.items); if (!initialScroll.current) { setOlder(!!history.data.nextCursor); initialScroll.current = true; } } }, [history.data]);
  useEffect(() => { if (conversationQuery.data) { lastRead.current = Math.max(lastRead.current, conversationQuery.data.lastReadSeq); unreadBoundary.current ??= conversationQuery.data.lastReadSeq; } }, [conversationQuery.data?.lastReadSeq]);
  async function fetchEntry(entryId: string) {
    if (refetching.current.has(entryId)) return; refetching.current.add(entryId);
    try { upsert([await client.call('GET /entries/:id', { params: { id: entryId } })]); }
    catch (error) { setLiveError(error); throw error; }
    finally { refetching.current.delete(entryId); }
  }
  useEffect(() => {
    if (!realtime) return;
    return realtime.subscribe(async frame => {
      if (frame.type === 'typing' && frame.conversationId === id) { setTyping(current => [...current.filter(item => item.userId !== frame.userId), ...(frame.active ? [{ userId: frame.userId, expiresAtMs: frame.expiresAtMs }] : [])]); return; }
      if (frame.type === 'caught_up') { void history.reload().catch(setLiveError); void runQuery.reload().catch(setLiveError); }
      if (frame.type !== 'event') return;
      if (frame.event === 'conversation.upserted' && frame.payload.id === id) { const conversation = frame.payload; conversationQuery.setData(current => !current || current.revision <= conversation.revision ? conversation : current); }
      if (frame.event === 'run.upserted' && frame.payload.conversationId === id) updateRun(frame.payload);
      if (frame.event === 'entry.upserted' && frame.payload.conversationId === id) upsert([frame.payload]);
      if (frame.event === 'entry.deleted' && frame.payload.conversationId === id) { const entryId = frame.payload.id; entriesRef.current = entriesRef.current.filter(entry => entry.id !== entryId); setEntries(entriesRef.current); }
      if (frame.event === 'entry.delta' && frame.payload.conversationId === id) {
        const delta = frame.payload; const old = entriesRef.current.find(entry => entry.id === delta.entryId);
        if (old?.kind === 'message' && old.runId === delta.runId && old.text.length > delta.offset && old.text.slice(delta.offset, delta.offset + delta.text.length) === delta.text) return;
        if (!old || old.kind !== 'message' || !old.streaming || old.runId !== delta.runId || old.text.length !== delta.offset) { await fetchEntry(delta.entryId); return; }
        const next = { ...old, text: old.text + delta.text }; entriesRef.current = entriesRef.current.map(entry => entry.id === next.id ? next : entry); setEntries(entriesRef.current);
        if (pinned.current) requestAnimationFrame(() => end.current?.scrollIntoView({ block: 'end', behavior: 'instant' }));
      }
    });
  }, [realtime, id, client]);
  useEffect(() => {
    const notify = () => { if (!document.hidden) for (const entryId of visibleEntries.current) { const entry = entriesRef.current.find(item => item.id === entryId); if (entry) visibleThrough.current = Math.max(visibleThrough.current, entry.seq); } setReadVersion(version => version + 1); };
    document.addEventListener('visibilitychange', notify);
    return () => { document.removeEventListener('visibilitychange', notify); if (realtime?.state === 'live') { try { realtime.send({ type: 'typing', conversationId: id, active: false }); } catch (error) { setLiveError(error); } } };
  }, [realtime, id]);
  useEffect(() => {
    const root = scroller.current; if (!root) return;
    const observer = new IntersectionObserver(changes => { for (const change of changes) { const entryId = (change.target as HTMLElement).dataset.entryId || ''; if (change.isIntersecting) { visibleEntries.current.add(entryId); if (!document.hidden) visibleThrough.current = Math.max(visibleThrough.current, Number((change.target as HTMLElement).dataset.seq) || 0); } else visibleEntries.current.delete(entryId); } setReadVersion(version => version + 1); }, { root, threshold: 0 });
    root.querySelectorAll('[data-entry-id]').forEach(element => observer.observe(element)); return () => observer.disconnect();
  }, [entries.length, online, routePending]);
  useEffect(() => {
    if (!online || document.hidden || readFailure.current || readInFlight.current || visibleThrough.current <= lastRead.current) return;
    const throughSeq = visibleThrough.current; readInFlight.current = true;
    client.call('POST /conversations/:id/read', { params: { id }, body: { clientNonce: nonce(), throughSeq } }).then(conversation => { lastRead.current = Math.max(lastRead.current, throughSeq); conversationQuery.setData(conversation); }).catch(error => { readFailure.current = true; setReadError(error); }).finally(() => { readInFlight.current = false; setReadVersion(version => version + 1); });
  }, [readVersion, online, id, client]);
  async function loadOlder() { const first = entriesRef.current[0]; if (!first || paging) return; setPaging(true); const previousHeight = scroller.current?.scrollHeight || 0; try { const page = await client.call('GET /conversations/:id/entries', { params: { id }, query: { beforeSeq: first.seq, limit: 100 } }); setEntries(current => mergeEntries(current, page.items)); setOlder(!!page.nextCursor); setPageError(undefined); requestAnimationFrame(() => { if (scroller.current) scroller.current.scrollTop += scroller.current.scrollHeight - previousHeight; }); } catch (error) { setPageError(error); } finally { setPaging(false); } }
  async function jump(entryId: string, fromRoute = false) {
    try {
      const target = await client.call('GET /entries/:id', { params: { id: entryId } }); if (target.conversationId !== id) { if (fromRoute) throw new Error('The entry does not belong to the conversation in this link. No mismatched context was opened.'); navigate({ screen: 'conversation', id: target.conversationId, entryId }); return; }
      const [before, after] = await Promise.all([client.call('GET /conversations/:id/entries', { params: { id }, query: { beforeSeq: target.seq, limit: 30 } }), client.call('GET /conversations/:id/entries', { params: { id }, query: { afterSeq: target.seq, limit: 30 } })]);
      pinned.current = false; entriesRef.current = mergeEntries(before.items, [target, ...after.items]); setEntries(entriesRef.current); forwardSeq.current = after.items.at(-1)?.seq || target.seq; setNewer(!!after.nextCursor); setOlder(!!before.nextCursor); setJumped(true); requestAnimationFrame(() => { const element = document.getElementById(`entry-${entryId}`); element?.scrollIntoView({ block: 'center' }); element?.focus({ preventScroll: true }); });
    } catch (error) { setPageError(error); if (fromRoute) setRouteRejected(true); } finally { if (fromRoute) setRoutePending(false); }
  }
  useEffect(() => { setRouteRejected(false); if (route.entryId) { setRoutePending(true); void jump(route.entryId, true); } else setRoutePending(false); }, [route.entryId]);
  async function loadNewer() {
    if (paging || !forwardSeq.current) return; setPaging(true);
    try { const page = await client.call('GET /conversations/:id/entries', { params: { id }, query: { afterSeq: forwardSeq.current, limit: 100 } }); upsert(page.items); forwardSeq.current = page.items.at(-1)?.seq || forwardSeq.current; setNewer(!!page.nextCursor); setPageError(undefined); }
    catch (error) { setPageError(error); } finally { setPaging(false); }
  }
  async function latest() { const page = await client.call('GET /conversations/:id/entries', { params: { id }, query: { limit: 100 } }); pinned.current = true; setEntries(page.items); setOlder(!!page.nextCursor); setJumped(false); requestAnimationFrame(() => end.current?.scrollIntoView({ block: 'end' })); }
  const conversation = conversationQuery.data; const activeRuns = runs.filter(run => ['reserved', 'queued', 'running', 'awaiting_input', 'outcome_unknown'].includes(run.status));
  const grouped = new Map<string, string[]>(); for (const entry of entries) if (entry.kind === 'user_attachment' && entry.batchId) { const message = entries.find(item => item.kind === 'message' && item.batchId === entry.batchId); if (message) { const ids = grouped.get(message.id) || []; ids.push(entry.attachmentId); grouped.set(message.id, ids); } }
  if (routePending) return <section className="page"><PageHeader title="Checking conversation link" /><Loading /></section>;
  const mismatchedContext = conversation && ((route.botId && !conversation.botIds.includes(route.botId)) || (route.taskConversationId && (conversation.kind !== 'task' || conversation.id !== route.taskConversationId)) || (route.conversationId && route.conversationId !== conversation.id && route.conversationId !== conversation.parentConversationId));
  if (routeRejected || mismatchedContext) return <section className="page"><PageHeader title="Conversation link rejected" /><ErrorNotice error={routeRejected ? pageError : new Error('The linked Bot, conversation or task identifiers do not match this authorized context.')} /><button onClick={() => navigate({ screen: 'conversation', id })}>Open this authorized conversation without the mismatched link</button></section>;
  return <section className="page chat-page"><PageHeader title={conversation?.name || 'Conversation'} eyebrow={conversation?.kind === 'task' ? 'Independent task' : 'Workspace conversation'}><button onClick={() => setShowDetails(!showDetails)} aria-expanded={showDetails}>Tasks and details</button>{conversation?.botIds.map(botId => { const bot = snapshot.bots.find(item => item.id === botId); const machine = snapshot.machines.find(item => item.id === bot?.machineId); return <button key={botId} onClick={() => navigate({ screen: 'bot.overview', id: botId })}>{bot?.name || botId} · {bot?.activity.replaceAll('_', ' ') || 'Status unavailable'} · {machine?.name || 'Machine unavailable'}</button>; })}</PageHeader><ErrorNotice error={conversationQuery.error || history.error || runQuery.error} />{!online && <p className="error-notice">Offline. Visible history may be stale. Reads and mutations are not queued.</p>}{conversationQuery.loading && !conversation && <Loading />}{conversation && <div className={showDetails ? 'chat-layout with-details' : 'chat-layout'}><div className="chat-main"><form className="row chat-find" onSubmit={event => { event.preventDefault(); setFindQuery(find.trim()); }}><label htmlFor={`find-${id}`}>Find in this conversation</label><input id={`find-${id}`} value={find} maxLength={512} onChange={event => setFind(event.target.value)} /><button disabled={!online || !find.trim()}>Find</button>{findQuery && <button type="button" onClick={() => { setFind(''); setFindQuery(''); }}>Clear find</button>}</form>{findQuery && <div className="panel stack"><ErrorNotice error={search.error} />{search.loading && <Loading />}{search.data?.items.map(hit => hit.kind === 'message' && <button key={hit.entry.id} onClick={() => void jump(hit.entry.id)}>{hit.entry.actor.displayName}: {hit.snippet}</button>)}{search.data && !search.data.items.length && <p>No matches in authorized history.</p>}{search.data?.nextCursor && <p>More matches exist. Narrow your search.</p>}</div>}<div className="chat-runs stack">{activeRuns.map(run => <div className="row spread" key={run.id}><span>{snapshot.bots.find(bot => bot.id === run.botId)?.name || run.botId} · {run.status.replaceAll('_', ' ')} · {run.id}</span><button className="danger" disabled={!online || stopIntent.busy || stopIntent.uncertain || run.status === 'outcome_unknown'} onClick={() => void stopIntent.run(async () => updateRun(await client.call('POST /runs/:id/cancel', { params: { id: run.id }, body: { clientNonce: nonce(), reason: 'Explicit user Stop' } })))}>Stop actual run</button></div>)}{runs.filter(run => ['failed', 'cancelled', 'outcome_unknown'].includes(run.status)).map(run => <div className="chat-notice" key={run.id}>Run {run.id}: {run.status.replaceAll('_', ' ')}{run.error && <p>{run.error.message} · diagnostic {run.error.requestId}</p>}{run.status === 'cancelled' && <p>Cancellation confirmed. Completed side effects were not rolled back.</p>}</div>)}<IntentNotice intent={stopIntent} reconcile={async () => { const page = await client.call('GET /runs', { query: { conversationId: id, limit: 200 } }); for (const run of page.items) updateRun(run); }} /></div><ErrorNotice error={pageError || liveError || readError} />{!!readError && <button onClick={() => { void client.call('GET /conversations/:id', { params: { id } }).then(actual => { lastRead.current = actual.lastReadSeq; conversationQuery.setData(actual); setReadError(undefined); readFailure.current = false; visibleThrough.current = actual.lastReadSeq; }).catch(setReadError); }}>Reconcile read marker (does not resolve gates)</button>}{!!liveError && <button onClick={() => void history.reload().then(() => setLiveError(undefined)).catch(setLiveError)}>Refetch authoritative transcript</button>}<div className="chat-transcript" ref={scroller} onScroll={() => { const element = scroller.current; if (element) pinned.current = element.scrollHeight - element.scrollTop - element.clientHeight < 100; }} aria-label="Conversation transcript"><div className="row spread">{older && <button disabled={paging || !online} onClick={() => void loadOlder()}>{paging ? 'Loading earlier history…' : 'Load earlier history'}</button>}{jumped && <button onClick={() => void latest().catch(setPageError)}>Return to latest</button>}</div>{history.loading && !entries.length && <Loading />}{!history.loading && !history.error && !entries.length && <EmptyState title="Start with an outcome">Messages, files, questions and real work will appear here.</EmptyState>}{entries.map((entry, index) => {
    if (entry.kind === 'user_attachment' && entry.batchId && entries.some(item => item.kind === 'message' && item.batchId === entry.batchId)) return null;
    const unread = unreadBoundary.current !== undefined && entry.seq > unreadBoundary.current && (index === 0 || entries[index - 1].seq <= unreadBoundary.current);
    return <div key={entry.id}>{unread && <div className="chat-unread" role="separator" aria-label="Unread messages">Unread</div>}<EntryView entry={entry} attachments={grouped.get(entry.id) || []} jump={entryId => void jump(entryId)} reply={setReplyId} changed={entry => upsert([entry])} /></div>;
  })}{jumped && newer && <button disabled={paging || !online} onClick={() => void loadNewer()}>Load newer context</button>}<div ref={end} /></div><div className="muted small" role="status">{conversation.activity.map(activity => `${snapshot.bots.find(bot => bot.id === activity.botId)?.name || activity.botId} ${activity.phase}`).join(' · ')}{typing.filter(item => item.expiresAtMs > clock && item.userId !== snapshot.user.id).length > 0 && ' · Someone is typing…'}</div><Composer key={id} conversation={conversation} replyId={replyId} clearReply={() => setReplyId(null)} accepted={receipt => { upsert(receipt.entries); for (const run of receipt.runs) updateRun(run); }} /></div>{showDetails && <ConversationDetails conversation={conversation} changed={conversationQuery.setData} />}</div>}</section>;
}
