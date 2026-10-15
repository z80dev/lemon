import { useEffect, useRef, useState } from 'react';
import type { FeedbackCreate, Run, TranscriptEntry, TranscriptEvent } from '@lemon-bot/sdk';
import { nonce } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import type { Route } from '../../app';
import { AlertCircle, Check, ChevronLeft, Copy, MessageSquareMore, PanelRight, Reply, Search, Square, X } from 'lucide-react';
import { BotAvatar, EmptyState, ErrorNotice, Field, LemonFace, Loading, PageHeader, botColor, formatTime, presenceLabel, useQuery } from '../../ui';
import { TranscriptCard } from './cards';
import { Composer } from './composer';
import { BotPanel, type PanelTab } from './panel';
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
const quickReactions = ['👍', '❤️', '🎉', '👀'];
/** Hover toolbar (pointer) or long-press / context menu (touch). Reactions with counts stay visible under the bubble. */
function EntryActions({ entry, changed, reply }: { entry: TranscriptEntry; changed: (entry: TranscriptEntry) => void; reply: (id: string) => void }) {
  const { client, snapshot, online, reportError } = useApp(); const intent = useIntent(); const [showFeedback, setShowFeedback] = useState(false); const [sentiment, setSentiment] = useState<FeedbackCreate['sentiment']>('good'); const [reasons, setReasons] = useState<NonNullable<FeedbackCreate['reasons']>>([]); const [comment, setComment] = useState(''); const [feedbackSent, setFeedbackSent] = useState(false); const [copied, setCopied] = useState(false);
  const text = entry.kind === 'message' ? entry.text : entry.kind === 'card' && entry.card.type === 'text' ? entry.card.text : undefined;
  const react = (emoji: string, own: boolean) => void intent.run(async () => changed(await client.call(own ? 'DELETE /entries/:id/reactions' : 'POST /entries/:id/reactions', { params: { id: entry.id }, body: { clientNonce: nonce(), emoji } })));
  const reactionDisabled = !online || intent.busy || intent.uncertain;
  return <>
    <div className="chat-actions" role="toolbar" aria-label="Message actions">
      {quickReactions.map(emoji => { const own = !!entry.reactions.find(item => item.emoji === emoji)?.userIds.includes(snapshot.user.id); return <button key={emoji} className="chat-action-emoji" aria-label={`${own ? 'Remove' : 'Add'} ${emoji} reaction`} aria-pressed={own} disabled={reactionDisabled} onClick={() => react(emoji, own)}>{emoji}</button>; })}
      <span className="chat-actions-sep" aria-hidden="true"/>
      <button aria-label="Reply" title="Reply" onClick={() => reply(entry.id)}><Reply size={16}/></button>
      {text !== undefined && <button aria-label={copied ? 'Copied' : 'Copy text'} title={copied ? 'Copied' : 'Copy text'} onClick={() => void copyText(text).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1400); }).catch(reportError)}>{copied ? <Check size={16}/> : <Copy size={16}/>}</button>}
      {entry.actor.kind === 'bot' && <button aria-label="Feedback" title="Feedback" aria-expanded={showFeedback} onClick={() => setShowFeedback(!showFeedback)}><MessageSquareMore size={16}/></button>}
    </div>
    {entry.reactions.some(reaction => reaction.userIds.length > 0) && <div className="chat-reactions">{entry.reactions.filter(reaction => reaction.userIds.length > 0).map(reaction => { const own = reaction.userIds.includes(snapshot.user.id); return <button key={reaction.emoji} className={own ? 'own' : ''} aria-pressed={own} aria-label={`${reaction.emoji} ${reaction.userIds.length}. ${own ? 'Remove your reaction' : 'Add reaction'}`} disabled={reactionDisabled} onClick={() => react(reaction.emoji, own)}>{reaction.emoji}{reaction.userIds.length > 1 && <span>{reaction.userIds.length}</span>}</button>; })}</div>}
    <IntentNotice intent={intent} reconcile={async () => changed(await client.call('GET /entries/:id', { params: { id: entry.id } }))} />
    {showFeedback && <form className="chat-feedback stack" onSubmit={event => { event.preventDefault(); void intent.run(async () => { await client.call('POST /entries/:id/feedback', { params: { id: entry.id }, body: { clientNonce: nonce(), sentiment, reasons, comment } }); setFeedbackSent(true); }); }}><Field label="Feedback"><select value={sentiment} onChange={event => setSentiment(event.target.value as FeedbackCreate['sentiment'])}><option value="good">Good</option><option value="bad">Bad</option></select></Field><fieldset><legend>Reasons (optional)</legend>{(['not_requested', 'inaccurate', 'low_quality', 'slow'] as const).map(reason => <label key={reason} className="row"><input type="checkbox" checked={reasons.includes(reason)} onChange={event => setReasons(current => event.target.checked ? [...current, reason] : current.filter(value => value !== reason))} />{reason.replaceAll('_', ' ')}</label>)}</fieldset><Field label="Comment"><textarea value={comment} onChange={event => setComment(event.target.value)} /></Field><div className="row"><button className="primary" disabled={!online || intent.busy || intent.uncertain}>Save my feedback</button><button type="button" onClick={() => setShowFeedback(false)}>Close</button></div>{feedbackSent && <p role="status">Your feedback was saved. It does not approve an action.</p>}</form>}
  </>;
}
const finishedRun: Record<string, true> = { failed: true, cancelled: true, outcome_unknown: true };
/** A failed, stopped or unconfirmed run, shown as one quiet inline row. Raw run and diagnostic IDs live only under Details. */
export function RunOutcomeRow({ run, retryText, showTime = false }: { run: Run; retryText?: string; showTime?: boolean }) {
  const { reportError } = useApp();
  const label = run.status === 'cancelled' ? 'Stopped.' : run.status === 'outcome_unknown' ? 'Not sure this finished.' : 'Couldn’t finish this.';
  return <div className={`chat-outcome ${run.status}`} role="status">
    <AlertCircle size={15} aria-hidden="true"/><span>{label}</span>{showTime && <span className="chat-outcome-time">{formatTime(run.completedAtMs ?? run.createdAtMs)}</span>}
    {retryText !== undefined && run.status !== 'outcome_unknown' && <><button className="chat-link" title="Puts your message back in the composer so you can review and send it again" onClick={() => window.dispatchEvent(new CustomEvent('lemonbot:draft-prompt', { detail: { conversationId: run.conversationId, text: retryText } }))}>Retry</button><span aria-hidden="true">·</span></>}
    <details className="chat-outcome-details"><summary className="chat-link">Details</summary><dl>
      <dt>Status</dt><dd>{run.status.replaceAll('_', ' ')}{run.completedAtMs !== null && ` · ${formatTime(run.completedAtMs)}`}</dd>
      {run.error && <><dt>Reason</dt><dd>{run.error.message}</dd><dt>Code</dt><dd><code>{run.error.code}</code></dd></>}
      <dt>Run</dt><dd><code>{run.id}</code></dd>
      {run.error?.requestId && <><dt>Diagnostic</dt><dd><code>{run.error.requestId}</code> <button className="chat-link" onClick={() => void copyText(run.error?.requestId || '').catch(reportError)}>Copy</button></dd></>}
      {run.status === 'cancelled' && <dd className="chat-outcome-note">Cancellation confirmed. Completed side effects were not rolled back.</dd>}
      {run.status === 'outcome_unknown' && <dd className="chat-outcome-note">Work may already have happened. Check the Activity panel before sending again.</dd>}
    </dl></details>
  </div>;
}
function TypingBubble({ label }: { label: string }) { return <div className="chat-bubble chat-typing" role="status" aria-label={label}><i/><i/><i/></div>; }
interface EntryContext { run?: Run; retryText?: string; grouped: boolean; showName: boolean }
function EntryView({ entry, attachments, jump, reply, changed, context }: { entry: TranscriptEntry; attachments: string[]; jump: (id: string) => void; reply: (id: string) => void; changed: (entry: TranscriptEntry) => void; context: EntryContext }) {
  const { snapshot, reportError, navigate } = useApp();
  if (entry.targetedUserId && entry.targetedUserId !== snapshot.user.id) return null;
  const mine = entry.actor.kind === 'user';
  const anchor = { 'data-entry-id': entry.id, 'data-seq': entry.seq, tabIndex: -1, id: `entry-${entry.id}` };
  const fileIds = entry.kind === 'message' ? [...new Set([...entry.attachmentIds, ...attachments])] : [];
  if (entry.kind === 'message' && !mine && !entry.text && !fileIds.length) {
    if (context.run && finishedRun[context.run.status]) return <article className="chat-entry chat-entry-system" {...anchor} aria-label={`${entry.actor.displayName}, ${formatTime(entry.timestampMs)}`}><RunOutcomeRow run={context.run} retryText={context.retryText}/></article>;
    if (entry.streaming || (context.run && context.run.status !== 'succeeded')) return <article className={`chat-entry chat-bot-entry ${context.grouped ? 'grouped' : ''}`} {...anchor}><TypingBubble label={`${entry.actor.displayName} is replying`}/></article>;
    return <article className="chat-entry chat-entry-system" {...anchor}><p className="chat-system">{entry.actor.displayName} sent an empty reply.</p></article>;
  }
  let content; let shape: 'bubble' | 'card' | 'system' = 'bubble';
  switch (entry.kind) {
    case 'message': content = <><RichText text={entry.text} />{entry.streaming && <span className="chat-caret" role="status" aria-label="Still writing. Provisional streamed answer, awaiting authoritative completion."/>}{fileIds.map(id => <AttachmentLink key={id} id={id} />)}</>; break;
    case 'card': {
      shape = 'card';
      const room = snapshot.conversations.find(conversation => conversation.id === entry.conversationId);
      const privateTypes: Record<string, true> = { secret_request: true, human_step: true, email_draft: true, slack_draft: true, message_draft: true, permission_request: true, auto_review_approval: true, local_tool_permission: true, publish_approval: true };
      content = (room?.kind === 'group' || room?.kind === 'channel') && privateTypes[entry.card.type] ? <p className="error-notice">Sensitive requests must be reviewed in your authorized private task or DM, not in this shared room.</p> : <TranscriptCard card={entry.card} />; break;
    }
    case 'user_attachment': content = <AttachmentLink id={entry.attachmentId} />; break;
    case 'tool_call': shape = 'system'; content = <details className="chat-tool"><summary><span className={`chat-tool-dot ${entry.status}`} aria-hidden="true"/>{entry.title}<span className="chat-tool-state">{entry.status === 'started' ? 'running' : entry.status}</span></summary><p><code>{entry.tool}</code></p>{entry.detail && <p>{entry.detail}</p>}<p className="muted small">Sanitized activity summary, not raw command arguments.</p></details>; break;
    case 'mcp_app': shape = 'card'; content = <div className="stack"><h3>MCP app snapshot</h3><span className="badge">{entry.state}</span><p>{entry.resourceUri}</p>{entry.state === 'available' && entry.snapshotAttachmentId ? <AttachmentLink id={entry.snapshotAttachmentId} /> : <p className="muted">Snapshot unavailable or expired. Ask the Bot to rerun it; opening this row executes nothing.</p>}<button onClick={() => navigate({ screen: 'connect.apps', id: entry.connectorId })}>Inspect connector</button></div>; break;
    case 'notice': shape = 'system'; content = <div className={`chat-outcome ${entry.severity === 'error' ? 'failed' : entry.severity}`} role={entry.severity === 'error' ? 'alert' : 'status'}>{entry.severity !== 'info' && <AlertCircle size={15} aria-hidden="true"/>}<span>{entry.text}</span>{entry.requestId && <details className="chat-outcome-details"><summary className="chat-link">Details</summary><dl><dt>Diagnostic</dt><dd><code>{entry.requestId}</code> <button className="chat-link" onClick={() => void copyText(entry.requestId || '').catch(reportError)}>Copy</button></dd></dl></details>}</div>; break;
    case 'event': shape = 'system'; content = <div className="chat-event"><EventLine event={entry.event} /></div>; break;
    case 'feedback': shape = 'system'; content = <div className="chat-event"><span>Feedback · {entry.feedback.sentiment}{entry.feedback.reasons.length > 0 && ` · ${entry.feedback.reasons.map(reason => reason.replaceAll('_', ' ')).join(', ')}`}{entry.feedback.comment && ` · “${entry.feedback.comment}”`}</span></div>; break;
    case 'voice_call': shape = 'card'; content = <div className="stack"><h3>Voice call · {entry.voiceSession.state}</h3><p>{Math.floor(entry.voiceSession.durationMs / 1000)}s · ended {formatTime(entry.voiceSession.endedAtMs)} · feedback {entry.voiceSession.feedback || 'None'}</p><div className="row">{entry.voiceSession.transcriptEntryIds.map(id => <button key={id} onClick={() => jump(id)}>Transcript entry {id}</button>)}</div><p className="muted">Voice call summary, not a persisted voice memo. Follow-up work remains in chat.</p></div>; break;
    default: shape = 'system'; content = <p className="error-notice">Unsupported transcript entry. Update this client. Entry ID is retained; no resolving action is available.</p>;
  }
  const when = formatTime(entry.timestampMs);
  if (shape === 'system') return <article className="chat-entry chat-entry-system" {...anchor} aria-label={`${entry.actor.displayName}, ${when}`}>{content}</article>;
  const actions = !['event', 'tool_call', 'feedback'].includes(entry.kind);
  return <article className={`chat-entry ${mine ? 'chat-user-entry' : 'chat-bot-entry'} ${context.grouped ? 'grouped' : ''} ${shape === 'card' ? 'chat-card-entry' : ''}`} {...anchor} aria-label={`${entry.actor.displayName}, ${when}`} onMouseEnter={event => { const article = event.currentTarget; const bubble = article.querySelector<HTMLElement>(':scope > .chat-bubble, :scope > .chat-card'); const toolbar = article.querySelector<HTMLElement>(':scope > .chat-actions'); const column = article.closest<HTMLElement>('.chat-transcript'); if (!bubble || !toolbar || !column) return; const box = bubble.getBoundingClientRect(), area = column.getBoundingClientRect(); const room = mine ? box.left - area.left : area.right - box.right; article.dataset.actions = room >= toolbar.offsetWidth + 12 ? 'side' : 'below'; }} onContextMenu={event => { if (matchMedia('(hover: none)').matches) { event.preventDefault(); event.currentTarget.classList.add('actions-open'); } }} onTouchStart={event => { const target = event.currentTarget; const timer = window.setTimeout(() => { target.classList.add('actions-open'); const close = (outside: Event) => { if (!target.contains(outside.target as Node)) { target.classList.remove('actions-open'); document.removeEventListener('touchstart', close); } }; document.addEventListener('touchstart', close); }, 450); const cancel = () => { clearTimeout(timer); target.removeEventListener('touchend', cancel); target.removeEventListener('touchmove', cancel); }; target.addEventListener('touchend', cancel); target.addEventListener('touchmove', cancel); }}>
    {context.showName && !context.grouped && !mine && <header className="chat-name">{entry.actor.displayName}</header>}
    {entry.replyToEntryId && <ReplyQuote id={entry.replyToEntryId} jump={jump} />}
    <div className={shape === 'card' ? 'chat-card' : 'chat-bubble'} title={when}>{content}</div>
    <time className="sr-only" dateTime={new Date(entry.timestampMs).toISOString()}>{when}</time>
    {actions && <EntryActions entry={entry} changed={changed} reply={reply} />}
  </article>;
}
function dayLabel(ms: number, now: number) {
  const date = new Date(ms); const today = new Date(now); const yesterday = new Date(now - 86400000);
  const time = new Intl.DateTimeFormat(undefined, { timeStyle: 'short' }).format(date);
  if (date.toDateString() === today.toDateString()) return `Today ${time}`;
  if (date.toDateString() === yesterday.toDateString()) return `Yesterday ${time}`;
  return `${new Intl.DateTimeFormat(undefined, { weekday: 'short', month: 'short', day: 'numeric', ...(date.getFullYear() !== today.getFullYear() ? { year: 'numeric' } : {}) }).format(date)} ${time}`;
}

export function ConversationScreen({ route }: { route: Route }) {
  if (!route.id) return <EmptyState title="Select a conversation">Open a Bot or task to read its real conversation.</EmptyState>;
  return <ConversationBody key={route.id} route={route} id={route.id} />;
}
function ConversationBody({ id, route }: { id: string; route: Route }) {
  const { client, realtime, snapshot, online, navigate } = useApp(); const conversationQuery = useQuery(`conversation:${id}`, () => client.call('GET /conversations/:id', { params: { id } })); const history = useQuery(`entries:${id}`, () => client.call('GET /conversations/:id/entries', { params: { id }, query: { limit: 100 } }));
  const runQuery = useQuery(`runs:${id}`, () => client.call('GET /runs', { query: { conversationId: id, limit: 200 } })); const runsRef = useRef<Run[]>([]); const [runs, setRuns] = useState<Run[]>([]);
  const [entries, setEntries] = useState<TranscriptEntry[]>([]); const entriesRef = useRef(entries); entriesRef.current = entries; const [replyId, setReplyId] = useState<string | null>(null); const [panel, setPanel] = useState<PanelTab | null>(null); const [findOpen, setFindOpen] = useState(false); const findInput = useRef<HTMLInputElement>(null); const [older, setOlder] = useState(false); const [paging, setPaging] = useState(false); const [pageError, setPageError] = useState<unknown>(); const [liveError, setLiveError] = useState<unknown>(); const [find, setFind] = useState(''); const [findQuery, setFindQuery] = useState(''); const [typing, setTyping] = useState<{ userId: string; expiresAtMs: number }[]>([]); const [jumped, setJumped] = useState(false);
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
  const attachmentGroups = new Map<string, string[]>(); for (const entry of entries) if (entry.kind === 'user_attachment' && entry.batchId) { const message = entries.find(item => item.kind === 'message' && item.batchId === entry.batchId); if (message) { const ids = attachmentGroups.get(message.id) || []; ids.push(entry.attachmentId); attachmentGroups.set(message.id, ids); } }
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => { if ((event.metaKey || event.ctrlKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === 'f') { event.preventDefault(); setFindOpen(true); requestAnimationFrame(() => findInput.current?.focus()); } };
    window.addEventListener('keydown', keyboard); return () => window.removeEventListener('keydown', keyboard);
  }, []);
  if (routePending) return <section className="page"><PageHeader title="Checking conversation link" /><Loading /></section>;
  const mismatchedContext = conversation && ((route.botId && !conversation.botIds.includes(route.botId)) || (route.taskConversationId && (conversation.kind !== 'task' || conversation.id !== route.taskConversationId)) || (route.conversationId && route.conversationId !== conversation.id && route.conversationId !== conversation.parentConversationId));
  if (routeRejected || mismatchedContext) return <section className="page"><PageHeader title="Conversation link rejected" /><ErrorNotice error={routeRejected ? pageError : new Error('The linked Bot, conversation or task identifiers do not match this authorized context.')} /><button onClick={() => navigate({ screen: 'conversation', id })}>Open this authorized conversation without the mismatched link</button></section>;
  const runById = new Map(runs.map(run => [run.id, run]));
  const retryTextFor = (run: Run, before?: number) => { const exact = entries.find(entry => entry.kind === 'message' && entry.actor.kind === 'user' && entry.clientNonce === run.clientNonce); const fallback = before === undefined ? undefined : [...entries].reverse().find(entry => entry.seq < before && entry.kind === 'message' && entry.actor.kind === 'user'); const source = exact || fallback; return source?.kind === 'message' && source.text ? source.text : undefined; };
  const placedRuns = new Set(entries.map(entry => entry.runId).filter((runId): runId is string => !!runId));
  const orphanOutcomes = runs.filter(run => finishedRun[run.status] && run.status !== 'outcome_unknown' && !placedRuns.has(run.id)).sort((a, b) => (a.completedAtMs || a.createdAtMs) - (b.completedAtMs || b.createdAtMs));
  const leadBot = conversation ? snapshot.bots.find(bot => bot.id === (conversation.leadBotId || conversation.botIds[0])) : undefined;
  const shared = conversation?.kind === 'group' || conversation?.kind === 'channel';
  const title = conversation ? (conversation.kind === 'dm' && leadBot ? leadBot.name : conversation.name) : 'Conversation';
  const stepFor = (run: Run) => [...entries].reverse().find(entry => entry.kind === 'tool_call' && entry.runId === run.id);
  const runVerb: Record<string, string> = { reserved: 'is starting…', queued: 'is queued', running: 'is working…', awaiting_input: 'needs your input', outcome_unknown: 'may still be working' };
  const typingNow = typing.filter(item => item.expiresAtMs > clock && item.userId !== snapshot.user.id).length > 0;
  let previous: TranscriptEntry | undefined;
  return <section className={`chat-page ${panel ? 'panel-open' : ''}`} style={{ ['--bot' as string]: botColor(leadBot) }}>
    <header className="chat-header">
      <button className="icon-button chat-back" aria-label="Back to your Bots" onClick={() => navigate({ screen: 'home' })}><ChevronLeft size={22}/></button>
      <button className="chat-title" aria-expanded={panel !== null} aria-controls={`panel-${id}`} title="Show what this Bot is doing" onClick={() => setPanel(panel ? null : 'activity')}>
        {leadBot ? <BotAvatar bot={leadBot} size={26}/> : <LemonFace size={26}/>}<span className="chat-title-name">{title}</span>
        {leadBot && <span className={`status-dot ${leadBot.activity}`} aria-label={presenceLabel(leadBot.activity)}/>}
        {conversation?.kind === 'task' && <span className="chip">Task</span>}
      </button>
      <div className="chat-header-actions">
        <button className="icon-button" aria-label="Find in conversation (⌘F)" title="Find (⌘F)" aria-expanded={findOpen} onClick={() => setFindOpen(!findOpen)}><Search size={18}/></button>
        <button className={`icon-button ${panel ? 'selected' : ''}`} aria-label="Details and activity" title="Details and activity" aria-expanded={panel !== null} onClick={() => setPanel(panel ? null : 'activity')}><PanelRight size={18}/></button>
      </div>
    </header>
    {findOpen && <div className="chat-find" role="search">
      <form onSubmit={event => { event.preventDefault(); setFindQuery(find.trim()); }}><Search size={16} aria-hidden="true"/><label className="sr-only" htmlFor={`find-${id}`}>Find in this conversation</label><input id={`find-${id}`} ref={findInput} autoFocus placeholder="Find in conversation" value={find} maxLength={512} onChange={event => setFind(event.target.value)} onKeyDown={event => { if (event.key === 'Escape') { setFindOpen(false); setFind(''); setFindQuery(''); } }} /><button type="button" className="icon-button" aria-label="Close find" onClick={() => { setFindOpen(false); setFind(''); setFindQuery(''); }}><X size={16}/></button></form>
      {findQuery && <div className="chat-find-results"><ErrorNotice error={search.error} />{search.loading && <Loading />}{search.data?.items.map(hit => hit.kind === 'message' && <button key={hit.entry.id} onClick={() => void jump(hit.entry.id)}><strong>{hit.entry.actor.displayName}</strong> {hit.snippet}</button>)}{search.data && !search.data.items.length && <p className="muted">No matches.</p>}</div>}
    </div>}
    <ErrorNotice error={conversationQuery.error || history.error || runQuery.error} />
    {conversationQuery.loading && !conversation && <Loading />}
    {conversation && <div className={`chat-layout ${panel ? 'with-panel' : ''}`}>
      <div className="chat-main">
        <div className="chat-transcript" ref={scroller} onScroll={() => { const element = scroller.current; if (element) pinned.current = element.scrollHeight - element.scrollTop - element.clientHeight < 100; }} aria-label="Conversation transcript">
          <div className="chat-column">
            {(older || jumped) && <div className="chat-paging">{older && <button disabled={paging || !online} onClick={() => void loadOlder()}>{paging ? 'Loading…' : 'Load earlier messages'}</button>}{jumped && <button onClick={() => void latest().catch(setPageError)}>Jump to latest</button>}</div>}
            <ErrorNotice error={pageError || liveError || readError} />
            {!!readError && <button onClick={() => { void client.call('GET /conversations/:id', { params: { id } }).then(actual => { lastRead.current = actual.lastReadSeq; conversationQuery.setData(actual); setReadError(undefined); readFailure.current = false; visibleThrough.current = actual.lastReadSeq; }).catch(setReadError); }}>Reconcile read marker (does not resolve gates)</button>}
            {!!liveError && <button onClick={() => void history.reload().then(() => setLiveError(undefined)).catch(setLiveError)}>Refetch authoritative transcript</button>}
            {history.loading && !entries.length && <Loading />}
            {!history.loading && !history.error && !entries.length && <div className="chat-empty">{leadBot ? <BotAvatar bot={leadBot} size={72}/> : <LemonFace size={72}/>}<h2>{title}</h2><p className="muted">{leadBot?.job || leadBot?.title || 'Messages, files, questions and real work will appear here.'}</p></div>}
            {entries.map((entry, index) => {
              if (entry.kind === 'user_attachment' && entry.batchId && entries.some(item => item.kind === 'message' && item.batchId === entry.batchId)) return null;
              if (entry.targetedUserId && entry.targetedUserId !== snapshot.user.id) return null;
              const unread = unreadBoundary.current !== undefined && entry.seq > unreadBoundary.current && (index === 0 || entries[index - 1].seq <= unreadBoundary.current);
              const separator = !previous || entry.timestampMs - previous.timestampMs > 3600000 || new Date(entry.timestampMs).toDateString() !== new Date(previous.timestampMs).toDateString();
              const bubbleKinds: Record<string, true> = { message: true, user_attachment: true };
              const grouped = !separator && !unread && !!previous && bubbleKinds[previous.kind] && bubbleKinds[entry.kind] && previous.actor.kind === entry.actor.kind && previous.actor.id === entry.actor.id && entry.timestampMs - previous.timestampMs < 300000;
              previous = entry;
              const run = entry.runId ? runById.get(entry.runId) : undefined;
              return <div className="chat-row" key={entry.id}>{separator && <div className="chat-day" role="separator">{dayLabel(entry.timestampMs, clock)}</div>}{unread && <div className="chat-unread" role="separator" aria-label="Unread messages"><span>New</span></div>}<EntryView entry={entry} attachments={attachmentGroups.get(entry.id) || []} jump={entryId => void jump(entryId)} reply={setReplyId} changed={entry => upsert([entry])} context={{ run, retryText: run && finishedRun[run.status] ? retryTextFor(run, entry.seq) : undefined, grouped, showName: shared }} /></div>;
            })}
            {orphanOutcomes.map(run => <div className="chat-entry chat-entry-system" key={run.id}><RunOutcomeRow run={run} retryText={retryTextFor(run)}/></div>)}
            {jumped && newer && <div className="chat-paging"><button disabled={paging || !online} onClick={() => void loadNewer()}>Load newer messages</button></div>}
            <div ref={end} />
          </div>
        </div>
        <div className="chat-dock">
          {[...new Set(activeRuns.map(run => run.botId))].map(botId => { const botRuns = activeRuns.filter(run => run.botId === botId); const priority: Record<string, number> = { running: 0, awaiting_input: 1, queued: 2, reserved: 3, outcome_unknown: 4 }; const run = [...botRuns].sort((a, b) => priority[a.status] - priority[b.status])[0]; const bot = snapshot.bots.find(item => item.id === botId); const step = stepFor(run); const unconfirmed = run.status === 'outcome_unknown'; return <div className="chat-working" key={botId} role="status">
            <button className="chat-working-main" onClick={() => setPanel('activity')} aria-label={`${bot?.name || 'Bot'} ${runVerb[run.status] || run.status}. Open activity`}>{unconfirmed ? <AlertCircle size={15} className="warning-text" aria-hidden="true"/> : <span className={`spinner ${run.status === 'awaiting_input' ? 'paused' : ''}`} aria-hidden="true"/>}<strong>{bot?.name || 'Bot'}</strong><span>{runVerb[run.status] || run.status.replaceAll('_', ' ')}</span>{step?.kind === 'tool_call' && <span className="chat-working-step">{step.title}</span>}{botRuns.length > 1 && <span className="chat-working-step">{botRuns.length} runs</span>}</button>
            {!unconfirmed && <button className="chat-stop" aria-label="Stop this run" title="Stop" disabled={!online || stopIntent.busy || stopIntent.uncertain} onClick={() => void stopIntent.run(async () => updateRun(await client.call('POST /runs/:id/cancel', { params: { id: run.id }, body: { clientNonce: nonce(), reason: 'Explicit user Stop' } })))}><Square size={11} fill="currentColor"/></button>}
          </div>; })}
          {!activeRuns.length && (typingNow || conversation.activity.length > 0) && <div className="chat-presence" role="status">{conversation.activity.map(activity => `${snapshot.bots.find(bot => bot.id === activity.botId)?.name || 'A Bot'} is ${activity.phase}…`).join(' · ')}{typingNow && ' Someone is typing…'}</div>}
          <IntentNotice intent={stopIntent} reconcile={async () => { const page = await client.call('GET /runs', { query: { conversationId: id, limit: 200 } }); for (const run of page.items) updateRun(run); }} />
          {!online && <p className="chat-offline">Offline. History may be stale; nothing is queued.</p>}
          <Composer key={id} conversation={conversation} bot={leadBot} replyId={replyId} clearReply={() => setReplyId(null)} accepted={receipt => { upsert(receipt.entries); for (const run of receipt.runs) updateRun(run); }} />
        </div>
      </div>
      {panel && <BotPanel id={`panel-${id}`} conversation={conversation} changed={conversationQuery.setData} runs={runs} entries={entries} tab={panel} setTab={setPanel} stop={run => void stopIntent.run(async () => updateRun(await client.call('POST /runs/:id/cancel', { params: { id: run.id }, body: { clientNonce: nonce(), reason: 'Explicit user Stop' } })))} stopDisabled={!online || stopIntent.busy || stopIntent.uncertain} />}
    </div>}
  </section>;
}
