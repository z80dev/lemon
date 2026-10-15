import { useEffect, useRef, useState } from 'react';
import type { FeedbackCreate, Run, TranscriptEntry, TranscriptEvent } from '@lemon-bot/sdk';
import { nonce } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import type { Route } from '../../app';
import { AlertCircle, ArrowDown, Hand, Check, ChevronLeft, ChevronRight, CircleStop, Copy, MoreHorizontal, Reply, Search, Square, ThumbsUp, Wrench, X } from 'lucide-react';
import { BotAvatar, EmptyState, ErrorNotice, Field, LemonFace, Loading, PageHeader, botStyle, formatTime, useQuery } from '../../ui';
import { compactDuration, currentStep, humanize, liveRunStatuses, plainLine, relativeTime, separatorDate, stoppableRunStatuses, toolIcon, voiceStateLabels } from '../../live';
import { TranscriptCard } from './cards';
import { Composer } from './composer';
import { BotPanel, type PanelTab } from './panel';
import { AttachmentLink, RichText } from './files';
import { IntentNotice, copyText, mergeEntries, useClock, useIntent } from './common';
import './chat.css';
export { FileViewer } from './files';
export { VoiceOverlay } from './voice';

function EventLine({ event }: { event: TranscriptEvent }) {
  const { snapshot, navigate } = useApp(); const botName = (id: string) => snapshot.bots.find(bot => bot.id === id)?.name || 'A Bot'; const machineName = (id: string) => snapshot.machines.find(machine => machine.id === id)?.name || 'another machine';
  const link = (label: string, route: Route) => <button className="event-link" onClick={() => navigate(route)}>{label}</button>;
  switch (event.type) {
    case 'name_changed': return <span>Renamed to “{event.name}”</span>;
    case 'channel_connected': case 'channel_disconnected': return <span>{event.type === 'channel_connected' ? 'Channel connected' : 'Channel disconnected'} {link('Open channels', { screen: 'integrations.channels', id: event.channelBindingId })}</span>;
    case 'routine_changed': return <span>Routine {event.action} {link('Open routine', { screen: 'routines', id: event.routineId })}</span>;
    case 'task_changed': return <span>Task {event.status.replaceAll('_', ' ')} {link('Open task', { screen: 'conversation', id: event.conversationId })}</span>;
    case 'bot_added': case 'bot_removed': return <span>{botName(event.botId)} {event.type === 'bot_added' ? 'joined' : 'left'} {link('Bot details', { screen: 'bot.overview', id: event.botId, botId: event.botId })}</span>;
    case 'handoff': return <span>{botName(event.sourceBotId)} handed off to {botName(event.targetBotId)}: {event.text} {link('Open', { screen: 'conversation', id: event.targetConversationId })}</span>;
    case 'machine_moved': return <span>{botName(event.botId)} moved from {machineName(event.sourceMachineId)} to {machineName(event.targetMachineId)} {link('Open machine', { screen: 'machine.detail', id: event.targetMachineId })}</span>;
    default: return <span>Unsupported activity. Update the client.</span>;
  }
}
function ReplyQuote({ id, jump }: { id: string; jump: (id: string) => void }) {
  const { client } = useApp(); const query = useQuery(`entry:${id}`, () => client.call('GET /entries/:id', { params: { id } })); const entry = query.data;
  return <blockquote className="chat-quote"><button onClick={() => jump(id)}><Reply size={12} aria-hidden="true"/>{entry ? `${entry.actor.displayName}: ${entry.kind === 'message' ? plainLine(entry.text).slice(0, 180) : entry.kind === 'user_attachment' ? 'File attachment' : entry.kind === 'card' ? entry.card.type.replaceAll('_', ' ') : entry.kind}` : query.error ? 'Quoted message unavailable' : 'Loading quoted message…'}</button></blockquote>;
}
const moreReactions = ['❤️', '🎉', '👀', '😂', '🙏'];
/** Hover-only ghost row beside the bubble (pointer) or long-press/context menu (touch): 👍, copy, reply, ⋯. */
function EntryActions({ entry, changed, reply }: { entry: TranscriptEntry; changed: (entry: TranscriptEntry) => void; reply: (id: string) => void }) {
  const { client, snapshot, online, reportError } = useApp(); const intent = useIntent(); const [showFeedback, setShowFeedback] = useState(false); const [sentiment, setSentiment] = useState<FeedbackCreate['sentiment']>('good'); const [reasons, setReasons] = useState<NonNullable<FeedbackCreate['reasons']>>([]); const [comment, setComment] = useState(''); const [feedbackSent, setFeedbackSent] = useState(false); const [copied, setCopied] = useState(false); const more = useRef<HTMLDetailsElement>(null);
  const text = entry.kind === 'message' ? entry.text : entry.kind === 'card' && entry.card.type === 'text' ? entry.card.text : undefined;
  const react = (emoji: string, own: boolean) => void intent.run(async () => changed(await client.call(own ? 'DELETE /entries/:id/reactions' : 'POST /entries/:id/reactions', { params: { id: entry.id }, body: { clientNonce: nonce(), emoji } })));
  const reactionDisabled = !online || intent.busy || intent.uncertain;
  const ownThumb = !!entry.reactions.find(item => item.emoji === '👍')?.userIds.includes(snapshot.user.id);
  const closeMore = () => more.current?.removeAttribute('open');
  return <>
    <div className="chat-actions" role="toolbar" aria-label="Message actions">
      <button aria-label={`${ownThumb ? 'Remove' : 'Add'} 👍 reaction`} aria-pressed={ownThumb} disabled={reactionDisabled} onClick={() => react('👍', ownThumb)}><ThumbsUp size={15}/></button>
      {text !== undefined && <button aria-label={copied ? 'Copied' : 'Copy message'} title={copied ? 'Copied' : 'Copy'} onClick={() => void copyText(text).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1400); }).catch(reportError)}>{copied ? <Check size={15}/> : <Copy size={15}/>}</button>}
      <button aria-label="Reply" title="Reply" onClick={() => reply(entry.id)}><Reply size={15}/></button>
      <details className="chat-more-actions" ref={more}><summary aria-label="More actions" title="More"><MoreHorizontal size={15}/></summary><div className="menu" role="menu">
        <div className="menu-reactions">{moreReactions.map(emoji => { const own = !!entry.reactions.find(item => item.emoji === emoji)?.userIds.includes(snapshot.user.id); return <button key={emoji} role="menuitem" aria-label={`${own ? 'Remove' : 'Add'} ${emoji} reaction`} aria-pressed={own} disabled={reactionDisabled} onClick={() => { react(emoji, own); closeMore(); }}>{emoji}</button>; })}</div>
        {entry.actor.kind === 'bot' && <button role="menuitem" onClick={() => { setShowFeedback(true); closeMore(); }}>Give feedback</button>}
        <button role="menuitem" onClick={() => { const link = new URL('/', location.origin); link.hash = new URLSearchParams({ screen: 'conversation', id: entry.conversationId, entryId: entry.id }).toString(); void copyText(link.href).catch(reportError); closeMore(); }}>Copy link to message</button>
      </div></details>
    </div>
    {copied && <span className="sr-only" role="status">Message copied.</span>}
    {entry.reactions.some(reaction => reaction.userIds.length > 0) && <div className="chat-reactions">{entry.reactions.filter(reaction => reaction.userIds.length > 0).map(reaction => { const own = reaction.userIds.includes(snapshot.user.id); return <button key={reaction.emoji} className={own ? 'own' : ''} aria-pressed={own} aria-label={`${reaction.emoji} ${reaction.userIds.length}. ${own ? 'Remove your reaction' : 'Add reaction'}`} disabled={reactionDisabled} onClick={() => react(reaction.emoji, own)}>{reaction.emoji}{reaction.userIds.length > 1 && <span>{reaction.userIds.length}</span>}</button>; })}</div>}
    <IntentNotice intent={intent} reconcile={async () => changed(await client.call('GET /entries/:id', { params: { id: entry.id } }))} />
    {showFeedback && <form className="chat-feedback stack" onSubmit={event => { event.preventDefault(); void intent.run(async () => { await client.call('POST /entries/:id/feedback', { params: { id: entry.id }, body: { clientNonce: nonce(), sentiment, reasons, comment } }); setFeedbackSent(true); }); }}><Field label="Feedback"><select value={sentiment} onChange={event => setSentiment(event.target.value as FeedbackCreate['sentiment'])}><option value="good">Good</option><option value="bad">Bad</option></select></Field><fieldset><legend>Reasons (optional)</legend>{(['not_requested', 'inaccurate', 'low_quality', 'slow'] as const).map(reason => <label key={reason} className="row"><input type="checkbox" checked={reasons.includes(reason)} onChange={event => setReasons(current => event.target.checked ? [...current, reason] : current.filter(value => value !== reason))} />{reason.replaceAll('_', ' ')}</label>)}</fieldset><Field label="Comment"><textarea value={comment} onChange={event => setComment(event.target.value)} /></Field><div className="row"><button className="pill-button primary" disabled={!online || intent.busy || intent.uncertain}>Save feedback</button><button type="button" className="pill-button secondary" onClick={() => setShowFeedback(false)}>Close</button></div>{feedbackSent && <p role="status">Thanks — your feedback was saved. It does not approve an action.</p>}</form>}
  </>;
}
const finishedRun: Record<string, true> = { failed: true, cancelled: true, outcome_unknown: true };
function CopyValue({ label, value }: { label: string; value: string }) {
  const { reportError } = useApp(); const [copied, setCopied] = useState(false);
  return <><dt>{label}</dt><dd><code>{value}</code><button className="ghost-mini" aria-label={`Copy ${label}`} onClick={() => void copyText(value).then(() => { setCopied(true); window.setTimeout(() => setCopied(false), 1200); }).catch(reportError)}>{copied ? <Check size={12}/> : <Copy size={12}/>}</button></dd></>;
}
/** Failed, stopped or unconfirmed run: one quiet left-aligned row. IDs appear only inside Details. */
export function RunOutcomeRow({ run, retryText, showTime = false }: { run: Run; retryText?: string; showTime?: boolean }) {
  const [open, setOpen] = useState(false);
  const { navigate } = useApp();
  const label = run.status === 'cancelled' ? 'Stopped.' : run.status === 'outcome_unknown' ? 'Status unknown' : 'Couldn’t finish this.';
  const canRetry = retryText !== undefined && run.status === 'failed' && !!run.error?.retrySafe;
  return <div className={`chat-outcome ${run.status}`} role="status">
    <div className="chat-outcome-line">
      {run.status === 'cancelled' ? <CircleStop size={14} aria-hidden="true"/> : <AlertCircle size={14} aria-hidden="true"/>}<span className="chat-outcome-label">{label}</span>
      {canRetry && <><button className="chat-link" title="Puts your message back in the composer to review and send" onClick={() => window.dispatchEvent(new CustomEvent('lemonbot:draft-prompt', { detail: { conversationId: run.conversationId, text: retryText } }))}>Retry</button><span className="faint" aria-hidden="true">·</span></>}
      <button className="chat-link" aria-expanded={open} onClick={() => setOpen(!open)}>Details</button>
      {showTime && <span className="chat-outcome-time">{relativeTime(run.completedAtMs ?? run.updatedAtMs)}</span>}
    </div>
    {run.status === 'outcome_unknown' && <p>The Bot may have finished this. <button className="chat-link" onClick={() => navigate({ screen: 'activity', botId: run.botId })}>Check Activity</button> before asking again.</p>}
    {open && <div className="chat-outcome-box">
      {run.error && <p>{run.error.message}</p>}
      {run.status === 'cancelled' && <p>Stopped at your request. Anything already done was not undone.</p>}
      <dl><dt>Status</dt><dd>{({ failed: 'Couldn’t finish', cancelled: 'Stopped', outcome_unknown: 'Status unknown' } as Record<string, string>)[run.status] || humanize(run.status)}{run.error && <span className="faint"> · {run.error.code.replaceAll('_', ' ')}</span>}</dd>
        {run.error?.requestId && <CopyValue label="Request ID" value={run.error.requestId}/>}
        <CopyValue label="Run ID" value={run.id}/></dl>
    </div>}
  </div>;
}
export function TypingDots() { return <span className="typing-dots" aria-hidden="true"><i/><i/><i/></span>; }
function TypingBubble({ label }: { label: string }) { return <div className="chat-typing" role="status" aria-label={label}><TypingDots/></div>; }
/** Consecutive tool calls collapse to "Used N tools ›" and expand to per-tool rows. */
function ToolGroup({ tools }: { tools: Extract<TranscriptEntry, { kind: 'tool_call' }>[] }) {
  const [open, setOpen] = useState(false);
  const running = tools.some(tool => tool.status === 'started'); const failed = tools.some(tool => tool.status === 'failed');
  const label = tools.length === 1 ? tools[0].title || humanize(tools[0].tool) : `Used ${tools.length} tools`;
  return <div className="chat-tools" data-entry-id={tools[0].id} data-seq={tools[0].seq} id={`entry-${tools[0].id}`} tabIndex={-1}>
    <button className="chat-tools-summary" aria-expanded={open} onClick={() => setOpen(!open)}><Wrench size={13} aria-hidden="true"/><span>{label}</span>{running ? <span className="mini-spinner" aria-label="Running"/> : failed ? <AlertCircle size={12} className="danger-text" aria-label="A tool failed"/> : null}<ChevronRight size={13} className="chevron" aria-hidden="true"/></button>
    {open && <ol className="chat-tool-rows">{tools.map(tool => { const Icon = toolIcon(tool.tool); return <li key={tool.id} data-entry-id={tool.id} data-seq={tool.seq}><details><summary><Icon size={13} aria-hidden="true"/><span className="chat-tool-title">{tool.title || humanize(tool.tool)}</span>{tool.status === 'started' ? <span className="mini-spinner" aria-label="Running"/> : tool.status === 'failed' ? <AlertCircle size={12} className="danger-text" aria-label="Failed"/> : <Check size={12} className="faint" aria-label="Done"/>}</summary><pre>{tool.tool}{tool.detail ? `\n${tool.detail}` : ''}</pre></details></li>; })}</ol>}
  </div>;
}
interface EntryContext { run?: Run; retryText?: string; grouped: boolean; showName: boolean }
function EntryView({ entry, attachments, jump, reply, changed, context }: { entry: TranscriptEntry; attachments: string[]; jump: (id: string) => void; reply: (id: string) => void; changed: (entry: TranscriptEntry) => void; context: EntryContext }) {
  const { snapshot, navigate } = useApp();
  if (entry.targetedUserId && entry.targetedUserId !== snapshot.user.id) return null;
  const mine = entry.actor.kind === 'user';
  const anchor = { 'data-entry-id': entry.id, 'data-seq': entry.seq, tabIndex: -1, id: `entry-${entry.id}` };
  const fileIds = entry.kind === 'message' ? [...new Set([...entry.attachmentIds, ...attachments])] : [];
  if (entry.kind === 'message' && !mine && !entry.text && !fileIds.length) {
    if (context.run && finishedRun[context.run.status]) return <article className="chat-entry chat-entry-outcome" {...anchor} aria-label={`${entry.actor.displayName}, ${formatTime(entry.timestampMs)}`}><RunOutcomeRow run={context.run} retryText={context.retryText}/></article>;
    if (entry.streaming || (context.run && context.run.status !== 'succeeded')) return <article className={`chat-entry chat-bot-entry ${context.grouped ? 'grouped' : ''}`} {...anchor}><TypingBubble label={`${entry.actor.displayName} is replying`}/></article>;
    return null;
  }
  let content; let shape: 'bubble' | 'card' | 'system' | 'outcome' = 'bubble';
  switch (entry.kind) {
    case 'message': content = <><RichText text={entry.text} />{entry.streaming && <span className="chat-caret" role="status" aria-label="Still writing"/>}{fileIds.map(id => <AttachmentLink key={id} id={id} />)}</>; break;
    case 'card': {
      shape = 'card';
      const room = snapshot.conversations.find(conversation => conversation.id === entry.conversationId);
      const privateTypes: Record<string, true> = { secret_request: true, human_step: true, email_draft: true, slack_draft: true, message_draft: true, permission_request: true, auto_review_approval: true, local_tool_permission: true, publish_approval: true };
      content = (room?.kind === 'group' || room?.kind === 'channel') && privateTypes[entry.card.type] ? <p className="error-notice">Sensitive requests must be reviewed in your authorized private task or DM, not in this shared room.</p> : <TranscriptCard card={entry.card} />; break;
    }
    case 'user_attachment': content = <AttachmentLink id={entry.attachmentId} />; break;
    case 'tool_call': return <ToolGroup tools={[entry]}/>;
    case 'mcp_app': shape = 'card'; content = <div className="stack"><h3>App snapshot</h3><span className="badge">{entry.state === 'available' ? 'Ready' : entry.state === 'expired' ? 'Expired' : 'Unavailable'}</span><details><summary>Details</summary><p>{entry.resourceUri}</p></details>{entry.state === 'available' && entry.snapshotAttachmentId ? <AttachmentLink id={entry.snapshotAttachmentId}/> : <p className="muted">This snapshot is no longer available. Ask the Bot to run it again.</p>}<button className="pill-button secondary" onClick={() => navigate({ screen: 'connect.apps', id: entry.connectorId })}>Open connection</button></div>; break;
    case 'notice': if (entry.severity === 'info' && !entry.requestId) { shape = 'system'; content = <div className="chat-event"><span>{entry.text}</span></div>; } else { shape = 'outcome'; content = <NoticeRow text={entry.text} severity={entry.severity} requestId={entry.requestId}/>; } break;
    case 'event': shape = 'system'; content = <div className="chat-event"><EventLine event={entry.event} /></div>; break;
    case 'feedback': shape = 'system'; content = <div className="chat-event"><span>Thanks for the feedback.{entry.feedback.comment && ` “${entry.feedback.comment}”`}</span></div>; break;
    case 'voice_call': shape = 'card'; content = <div className="stack"><h3>{voiceStateLabels[entry.voiceSession.state]}</h3><p>{Math.floor(entry.voiceSession.durationMs / 1000)}s{entry.voiceSession.endedAtMs !== null && ` · ended ${formatTime(entry.voiceSession.endedAtMs)}`}</p><div className="row">{entry.voiceSession.transcriptEntryIds.map((id, index) => <button key={id} className="pill-button secondary compact" onClick={() => jump(id)}>Transcript {index + 1}</button>)}</div></div>; break;
    default: shape = 'system'; content = <p className="error-notice">Unsupported transcript entry. Update this client.</p>;
  }
  const when = formatTime(entry.timestampMs);
  if (shape === 'system') return <article className="chat-entry chat-entry-system" {...anchor} aria-label={`${entry.actor.displayName}, ${when}`}>{content}</article>;
  if (shape === 'outcome') return <article className="chat-entry chat-entry-outcome" {...anchor} aria-label={`${entry.actor.displayName}, ${when}`}>{content}</article>;
  const actions = entry.kind !== 'feedback';
  return <article className={`chat-entry ${mine ? 'chat-user-entry' : 'chat-bot-entry'} ${context.grouped ? 'grouped' : ''} ${shape === 'card' ? 'chat-card-entry' : ''}`} {...anchor} aria-label={`${entry.actor.displayName}, ${when}`} onMouseEnter={event => { const article = event.currentTarget; const bubble = article.querySelector<HTMLElement>(':scope > .chat-bubble, :scope > .chat-card'); const toolbar = article.querySelector<HTMLElement>(':scope > .chat-actions'); const column = article.closest<HTMLElement>('.chat-transcript'); if (!bubble || !toolbar || !column) return; const box = bubble.getBoundingClientRect(), area = column.getBoundingClientRect(); const room = mine ? box.left - area.left : area.right - box.right; article.dataset.actions = room >= toolbar.offsetWidth + 12 ? 'side' : 'below'; }} onContextMenu={event => { if (matchMedia('(hover: none)').matches) { event.preventDefault(); event.currentTarget.classList.add('actions-open'); } }} onTouchStart={event => { const target = event.currentTarget; const timer = window.setTimeout(() => { target.classList.add('actions-open'); const close = (outside: Event) => { if (!target.contains(outside.target as Node)) { target.classList.remove('actions-open'); document.removeEventListener('touchstart', close); } }; document.addEventListener('touchstart', close); }, 450); const cancel = () => { clearTimeout(timer); target.removeEventListener('touchend', cancel); target.removeEventListener('touchmove', cancel); }; target.addEventListener('touchend', cancel); target.addEventListener('touchmove', cancel); }}>
    {context.showName && !context.grouped && !mine && <header className="chat-name">{entry.actor.displayName}</header>}
    {entry.replyToEntryId && <ReplyQuote id={entry.replyToEntryId} jump={jump} />}
    <div className={shape === 'card' ? 'chat-card' : 'chat-bubble'} title={when} onClick={event => { if (matchMedia('(pointer: coarse)').matches && event.target instanceof Element && !event.target.closest('button,a,input,textarea,select,summary')) event.currentTarget.parentElement?.focus({ preventScroll: true }); }}>{content}</div>
    <time className="sr-only" dateTime={new Date(entry.timestampMs).toISOString()}>{when}</time>
    {actions && <EntryActions entry={entry} changed={changed} reply={reply} />}
  </article>;
}
/** Error/warning notices use the failed-row shape; request IDs only under Details. */
function NoticeRow({ text, severity, requestId }: { text: string; severity: 'info' | 'warning' | 'error'; requestId: string | null }) {
  const [open, setOpen] = useState(false);
  return <div className={`chat-outcome ${severity === 'error' ? 'failed' : severity}`} role={severity === 'error' ? 'alert' : 'status'}>
    <div className="chat-outcome-line">{severity !== 'info' && <AlertCircle size={14} aria-hidden="true"/>}<span className="chat-outcome-label">{text}</span>{requestId && <button className="chat-link" aria-expanded={open} onClick={() => setOpen(!open)}>Details</button>}</div>
    {open && requestId && <div className="chat-outcome-box"><dl><CopyValue label="Request ID" value={requestId}/></dl></div>}
  </div>;
}

export function ConversationScreen({ route }: { route: Route }) {
  if (!route.id) return <EmptyState title="Select a conversation">Open a Bot or task to read its real conversation.</EmptyState>;
  return <ConversationBody key={route.id} route={route} id={route.id} />;
}
function ConversationBody({ id, route }: { id: string; route: Route }) {
  const { client, realtime, snapshot, online, navigate } = useApp(); const conversationQuery = useQuery(`conversation:${id}`, () => client.call('GET /conversations/:id', { params: { id } })); const history = useQuery(`entries:${id}`, () => client.call('GET /conversations/:id/entries', { params: { id }, query: { limit: 100 } }));
  const runQuery = useQuery(`runs:${id}`, () => client.call('GET /runs', { query: { conversationId: id, limit: 200 } })); const runsRef = useRef<Run[]>([]); const [runs, setRuns] = useState<Run[]>([]);
  const [entries, setEntries] = useState<TranscriptEntry[]>([]); const entriesRef = useRef(entries); entriesRef.current = entries; const [replyId, setReplyId] = useState<string | null>(null); const [panel, setPanel] = useState<PanelTab | null>(null); const headerMenu = useRef<HTMLDetailsElement>(null); const [findOpen, setFindOpen] = useState(false); const findInput = useRef<HTMLInputElement>(null); const [older, setOlder] = useState(false); const [paging, setPaging] = useState(false); const [pageError, setPageError] = useState<unknown>(); const [liveError, setLiveError] = useState<unknown>(); const [find, setFind] = useState(''); const [findQuery, setFindQuery] = useState(''); const [typing, setTyping] = useState<{ userId: string; expiresAtMs: number }[]>([]); const [jumped, setJumped] = useState(false);
  const scroller = useRef<HTMLDivElement>(null); const end = useRef<HTMLDivElement>(null); const pinned = useRef(true); const initialScroll = useRef(false); const lastRead = useRef(0); const unreadBoundary = useRef<number | undefined>(undefined); const clock = useClock(); const stopIntent = useIntent(); const readFailure = useRef(false); const [readError, setReadError] = useState<unknown>(); const readInFlight = useRef(false); const visibleThrough = useRef(0); const visibleEntries = useRef(new Set<string>()); const [readVersion, setReadVersion] = useState(0); const refetching = useRef(new Set<string>());
  const forwardSeq = useRef(0); const [newer, setNewer] = useState(false); const [newBelow, setNewBelow] = useState(false); const [settled, setSettled] = useState(false);
  const [routePending, setRoutePending] = useState(!!route.entryId); const [routeRejected, setRouteRejected] = useState(false);
  const search = useQuery(`conversation-search:${id}:${findQuery}`, async () => {
    if (!findQuery) return { items: [], nextCursor: null };
    const first = await client.call('GET /search', { query: { q: findQuery, kinds: ['message'], conversationId: id, limit: 200 } });
    const items = [...first.items]; let cursor = first.nextCursor;
    while (cursor) { const page = await client.call('GET /search', { query: { q: findQuery, kinds: ['message'], conversationId: id, limit: 200, cursor } }); items.push(...page.items); cursor = page.nextCursor; }
    return { items, nextCursor: null };
  });
  function upsert(incoming: TranscriptEntry[], own = false) { const known = new Set(entriesRef.current.map(entry => entry.id)); const lastSeq = entriesRef.current.at(-1)?.seq ?? 0; entriesRef.current = mergeEntries(entriesRef.current, incoming); setEntries(entriesRef.current); if (own) pinned.current = true; if (pinned.current) requestAnimationFrame(() => end.current?.scrollIntoView({ block: 'end', behavior: 'instant' })); else if (initialScroll.current && incoming.some(entry => !known.has(entry.id) && entry.seq > lastSeq)) setNewBelow(true); }
  function updateRun(run: Run) { const current = runsRef.current.find(value => value.id === run.id); if (current && current.revision > run.revision) return; const next = [...runsRef.current.filter(value => value.id !== run.id), run]; runsRef.current = next; setRuns(next); }
  useEffect(() => { if (runQuery.data) { for (const run of runQuery.data.items) updateRun(run); } }, [runQuery.data]);
  useEffect(() => { if (history.data) { upsert(history.data.items); if (!initialScroll.current) { setOlder(!!history.data.nextCursor); initialScroll.current = true; window.setTimeout(() => setSettled(true), 400); } } }, [history.data]);
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
  const conversation = conversationQuery.data; const stoppable = runs.filter(run => stoppableRunStatuses[run.status]); const liveRuns = runs.filter(run => liveRunStatuses[run.status]);
  const attachmentGroups = new Map<string, string[]>(); for (const entry of entries) if (entry.kind === 'user_attachment' && entry.batchId) { const message = entries.find(item => item.kind === 'message' && item.batchId === entry.batchId); if (message) { const ids = attachmentGroups.get(message.id) || []; ids.push(entry.attachmentId); attachmentGroups.set(message.id, ids); } }
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => { if ((event.metaKey || event.ctrlKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === 'f') { event.preventDefault(); setFindOpen(true); requestAnimationFrame(() => findInput.current?.focus()); } };
    const toggle = () => setPanel(current => current ? null : 'activity');
    window.addEventListener('keydown', keyboard); window.addEventListener('lemonbot:toggle-inspector', toggle);
    return () => { window.removeEventListener('keydown', keyboard); window.removeEventListener('lemonbot:toggle-inspector', toggle); };
  }, []);
  if (routePending) return <section className="page"><PageHeader title="Checking conversation link" /><Loading /></section>;
  const mismatchedContext = conversation && ((route.botId && !conversation.botIds.includes(route.botId)) || (route.taskConversationId && (conversation.kind !== 'task' || conversation.id !== route.taskConversationId)) || (route.conversationId && route.conversationId !== conversation.id && route.conversationId !== conversation.parentConversationId));
  if (routeRejected || mismatchedContext) return <section className="page"><PageHeader title="Conversation link rejected" /><ErrorNotice error={routeRejected ? pageError : new Error('The linked Bot, conversation or task identifiers do not match this authorized context.')} /><button onClick={() => navigate({ screen: 'conversation', id })}>Open this authorized conversation without the mismatched link</button></section>;
  const runById = new Map(runs.map(run => [run.id, run]));
  const retryTextFor = (run: Run, before?: number) => { const exact = entries.find(entry => entry.kind === 'message' && entry.actor.kind === 'user' && entry.clientNonce === run.clientNonce); const fallback = before === undefined ? undefined : [...entries].reverse().find(entry => entry.seq < before && entry.kind === 'message' && entry.actor.kind === 'user'); const source = exact || fallback; return source?.kind === 'message' && source.text ? source.text : undefined; };
  const placedRuns = new Set(entries.map(entry => entry.runId).filter((runId): runId is string => !!runId));
  const orphanOutcomes = runs.filter(run => finishedRun[run.status] && !placedRuns.has(run.id)).sort((a, b) => (a.completedAtMs || a.createdAtMs) - (b.completedAtMs || b.createdAtMs));
  const leadBot = conversation ? snapshot.bots.find(bot => bot.id === (conversation.leadBotId || conversation.botIds[0])) : undefined;
  const members = conversation ? conversation.botIds.map(botId => snapshot.bots.find(bot => bot.id === botId)).filter((bot): bot is NonNullable<typeof bot> => !!bot) : [];
  const shared = conversation?.kind === 'group' || conversation?.kind === 'channel';
  const title = conversation ? (conversation.kind === 'dm' && leadBot ? leadBot.name : conversation.name) : 'Conversation';
  const step = currentStep(runs.filter(run => run.conversationId === id), entries, conversation);
  const typingNow = typing.filter(item => item.expiresAtMs > clock && item.userId !== snapshot.user.id).length > 0;
  const placeholderForLive = entries.some(entry => entry.kind === 'message' && entry.actor.kind !== 'user' && (entry.streaming || (!entry.text && !!entry.runId && liveRuns.some(run => run.id === entry.runId))));
  const stopAll = () => void stopIntent.run(async () => { for (const run of stoppable.filter(item => item.status !== 'outcome_unknown')) updateRun(await client.call('POST /runs/:id/cancel', { params: { id: run.id }, body: { clientNonce: nonce(), reason: 'Explicit user Stop' } })); });
  const toolRun = (index: number) => { const tools: Extract<TranscriptEntry, { kind: 'tool_call' }>[] = []; for (let cursor = index; cursor < entries.length; cursor++) { const item = entries[cursor]; if (item.targetedUserId && item.targetedUserId !== snapshot.user.id) continue; if (item.kind !== 'tool_call') break; tools.push(item); } return tools; };
  let previous: TranscriptEntry | undefined;
  return <section className={`chat-page ${panel ? 'panel-open' : ''}`} style={botStyle(leadBot)}>
    <header className="chat-header">
      <div className="chat-edge" aria-hidden="true"/>
      <button className="ghost-circle chat-back" aria-label="Back to chats" onClick={() => navigate({ screen: 'home' })}><ChevronLeft size={18}/></button>
      <button className="chat-title" aria-label="Show Bot details" aria-expanded={panel !== null} aria-controls={`panel-${id}`} onClick={() => setPanel(panel ? null : 'activity')}>
        {shared && members.length > 1 ? <span className="avatar-stack" aria-hidden="true">{members.slice(0, 3).map(bot => <BotAvatar key={bot.id} bot={bot} size={22}/>)}</span> : leadBot ? <BotAvatar bot={leadBot} size={22}/> : <LemonFace size={22}/>}
        <span className="chat-title-name">{title}</span>
        {step && <span className="working-dot" aria-label="Working"/>}
      </button>
      <details className="chat-menu" ref={headerMenu}>
        <summary className="ghost-circle" aria-label="Conversation menu"><MoreHorizontal size={16}/></summary>
        <div className="menu" role="menu" onClick={event => { if ((event.target as Element).closest('button')) headerMenu.current?.removeAttribute('open'); }}>
          <button role="menuitem" onClick={() => setPanel('details')}>Details, media and export</button>
          <button role="menuitem" onClick={() => { setFindOpen(true); requestAnimationFrame(() => findInput.current?.focus()); }}>Find in chat<kbd>⌘F</kbd></button>
          {conversation?.kind === 'group' && <button role="menuitem" onClick={() => navigate({ screen: 'group.edit', id })}>Edit group members</button>}
          <button role="menuitem" disabled={!online || !conversation} onClick={() => conversation && void client.call('POST /conversations/:id/read', { params: { id }, body: { clientNonce: nonce(), throughSeq: Math.max(0, lastRead.current - 1), unread: true } }).then(conversationQuery.setData).catch(setPageError)}>Mark unread</button>
          {stoppable.some(run => run.status !== 'outcome_unknown') && <button role="menuitem" disabled={!online || stopIntent.busy || stopIntent.uncertain} onClick={stopAll}>Stop</button>}
        </div>
      </details>
    </header>
    {findOpen && <div className="chat-find" role="search">
      <form onSubmit={event => { event.preventDefault(); setFindQuery(find.trim()); }}><Search size={15} aria-hidden="true"/><label className="sr-only" htmlFor={`find-${id}`}>Find in this conversation</label><input id={`find-${id}`} ref={findInput} autoFocus placeholder="Find in chat" value={find} maxLength={512} onChange={event => setFind(event.target.value)} onKeyDown={event => { if (event.key === 'Escape') { setFindOpen(false); setFind(''); setFindQuery(''); } }} /><button type="button" className="ghost-mini" aria-label="Close find" onClick={() => { setFindOpen(false); setFind(''); setFindQuery(''); }}><X size={14}/></button></form>
      {findQuery && <div className="chat-find-results"><ErrorNotice error={search.error} />{search.loading && <Loading />}{search.data?.items.map(hit => hit.kind === 'message' && <button key={hit.entry.id} onClick={() => void jump(hit.entry.id)}><strong>{hit.entry.actor.displayName}</strong> {hit.snippet}</button>)}{search.data && !search.data.items.length && <p className="muted">No matches.</p>}</div>}
    </div>}
    <ErrorNotice error={conversationQuery.error || history.error || runQuery.error} />
    {!!(conversationQuery.error || history.error || runQuery.error) && <button className="pill-button secondary" onClick={() => void Promise.all([conversationQuery.reload(), history.reload(), runQuery.reload()]).catch(setLiveError)}>Try again</button>}
    {conversationQuery.loading && !conversation && <Loading label="Loading conversation…"/>}
    {conversation && <div className={`chat-layout ${panel ? 'with-panel' : ''}`}>
      <div className="chat-main">
        <div className="chat-transcript" ref={scroller} onScroll={() => { const element = scroller.current; if (element) { pinned.current = element.scrollHeight - element.scrollTop - element.clientHeight < 100; if (pinned.current) setNewBelow(false); } }} aria-label="Conversation transcript">
          <div className={`chat-column ${settled ? 'settled' : ''}`}>
            {(older || jumped) && <div className="chat-paging">{older && <button disabled={paging || !online} onClick={() => void loadOlder()}>{paging ? 'Loading…' : 'Load earlier messages'}</button>}{jumped && <button onClick={() => void latest().catch(setPageError)}>Jump to latest</button>}</div>}
            <ErrorNotice error={pageError || liveError || readError} />
            {!!readError && <div className="stack"><p>Couldn’t save your place.</p><button className="pill-button secondary compact" onClick={() => { void client.call('GET /conversations/:id', { params: { id } }).then(actual => { lastRead.current = actual.lastReadSeq; conversationQuery.setData(actual); setReadError(undefined); readFailure.current = false; visibleThrough.current = actual.lastReadSeq; }).catch(setReadError); }}>Check saved place</button></div>}
            {!!liveError && <button className="pill-button secondary compact" onClick={() => void history.reload().then(() => setLiveError(undefined)).catch(setLiveError)}>Reload messages</button>}
            {history.loading && !entries.length && <Loading label="Loading messages…"/>}
            {!history.loading && !history.error && !entries.length && !step && !liveRuns.length && <div className="chat-empty">{leadBot ? <BotAvatar bot={leadBot} size={72}/> : <LemonFace size={72}/>}<h2>{title}</h2><p className="muted">{leadBot?.job || leadBot?.title || 'Messages, files and work will appear here.'}</p></div>}
            {entries.map((entry, index) => {
              if (entry.kind === 'user_attachment' && entry.batchId && entries.some(item => item.kind === 'message' && item.batchId === entry.batchId)) return null;
              if (entry.targetedUserId && entry.targetedUserId !== snapshot.user.id) return null;
              if (entry.kind === 'tool_call' && previous?.kind === 'tool_call') { previous = entry; return null; }
              const unread = unreadBoundary.current !== undefined && entry.seq > unreadBoundary.current && (index === 0 || entries[index - 1].seq <= unreadBoundary.current);
              const separator = !previous || entry.timestampMs - previous.timestampMs > 1800000 || new Date(entry.timestampMs).toDateString() !== new Date(previous.timestampMs).toDateString();
              const bubbleKinds: Record<string, true> = { message: true, user_attachment: true };
              const grouped = !separator && !unread && !!previous && bubbleKinds[previous.kind] && bubbleKinds[entry.kind] && previous.actor.kind === entry.actor.kind && previous.actor.id === entry.actor.id && entry.timestampMs - previous.timestampMs < 300000;
              previous = entry;
              const run = entry.runId ? runById.get(entry.runId) : undefined;
              return <div className={`chat-row ${grouped ? 'grouped' : ''}`} key={entry.id}>{separator && <div className="chat-day" role="separator">{separatorDate(entry.timestampMs, clock)}</div>}{unread && <div className="chat-unread" role="separator" aria-label="Unread messages"><span>Unread</span></div>}{entry.kind === 'tool_call' ? <ToolGroup tools={toolRun(index)}/> : <EntryView entry={entry} attachments={attachmentGroups.get(entry.id) || []} jump={entryId => void jump(entryId)} reply={setReplyId} changed={entry => upsert([entry])} context={{ run, retryText: run && finishedRun[run.status] ? retryTextFor(run, entry.seq) : undefined, grouped, showName: shared }} />}</div>;
            })}
            {orphanOutcomes.map(run => <div className="chat-row" key={run.id}><div className="chat-entry chat-entry-outcome"><RunOutcomeRow run={run} retryText={retryTextFor(run)}/></div></div>)}
            {liveRuns.length > 0 && !placeholderForLive && <div className="chat-row"><article className="chat-entry chat-bot-entry"><TypingBubble label={`${leadBot?.name || 'Bot'} is working`}/></article></div>}
            {jumped && newer && <div className="chat-paging"><button disabled={paging || !online} onClick={() => void loadNewer()}>Load newer messages</button></div>}
            <div ref={end} />
          </div>
        </div>
        <div className="chat-dock">
          {newBelow && <button className="new-messages" onClick={() => { pinned.current = true; setNewBelow(false); end.current?.scrollIntoView({ block: 'end', behavior: 'smooth' }); }}><ArrowDown size={14}/>New messages</button>}
          {step && <div className={`chat-working ${step.needsInput ? 'needs-input' : ''} ${stoppable.some(run => run.status !== 'outcome_unknown') ? '' : 'no-stop'}`} role="status">
            <button className="chat-working-main" onClick={() => setPanel('activity')} aria-label={`${step.title}. Open Activity`}>{step.needsInput ? <Hand size={14} className="warning-text" aria-hidden="true"/> : <TypingDots/>}<span className="chat-working-step">{step.title}</span>{step.sinceMs !== undefined && <span className="chat-working-time">{compactDuration(step.sinceMs, clock)}</span>}</button>
            {stoppable.some(run => run.status !== 'outcome_unknown') && <button className="stop-pill" aria-label="Stop" disabled={!online || stopIntent.busy || stopIntent.uncertain} onClick={stopAll}><Square size={9} fill="currentColor"/>Stop</button>}
          </div>}
          {!step && typingNow && <div className="chat-presence" role="status">Someone is typing…</div>}
          <IntentNotice intent={stopIntent} reconcile={async () => { const page = await client.call('GET /runs', { query: { conversationId: id, limit: 200 } }); for (const run of page.items) updateRun(run); }} />
          <Composer key={id} conversation={conversation} bot={leadBot} replyId={replyId} clearReply={() => setReplyId(null)} accepted={receipt => { upsert(receipt.entries, true); for (const run of receipt.runs) updateRun(run); }} />
        </div>
      </div>
      {panel && <BotPanel id={`panel-${id}`} conversation={conversation} changed={conversationQuery.setData} runs={runs} entries={entries} tab={panel} setTab={setPanel} stop={run => void stopIntent.run(async () => updateRun(await client.call('POST /runs/:id/cancel', { params: { id: run.id }, body: { clientNonce: nonce(), reason: 'Explicit user Stop' } })))} stopDisabled={!online || stopIntent.busy || stopIntent.uncertain} />}
    </div>}
  </section>;
}
