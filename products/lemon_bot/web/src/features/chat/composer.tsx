import { useEffect, useRef, useState } from 'react';
import { LemonBotError, nonce } from '@lemon-bot/sdk';
import type { Bot, ComposerDraft, Conversation, MessageReceipt, MessageSend, Reference } from '@lemon-bot/sdk';
import { ArrowUp, AudioLines, Mic, Plus, X } from 'lucide-react';
import { useApp } from '../../app';
import { ErrorNotice, Field, useQuery } from '../../ui';
import { CaptureControls } from './capture';
import { AttachmentLink } from './files';
import { IntentNotice, unknownOutcome, useIntent } from './common';
import { startLiveVoice } from './voice';
import { humanize } from '../../live';
const deliveryLabels: Record<string, string> = { rejected: 'Not started', outcome_unknown: 'Status unknown', followup: 'Waiting for current work', steer: 'Adjusting current work', interrupt: 'Starting with your message' };

interface LocalDraft { text: string; attachmentIds: string[]; replyToEntryId: string | null; revision: number; references: Reference[]; mentions: string[]; everyone: boolean; unknownNonce?: string; acknowledged?: boolean; refused?: boolean }
function storedDraft(key: string): LocalDraft | undefined {
  try { const raw = sessionStorage.getItem(key); if (!raw) return; const data: unknown = JSON.parse(raw); if (data && typeof data === 'object' && 'text' in data && typeof data.text === 'string' && 'attachmentIds' in data && Array.isArray(data.attachmentIds) && data.attachmentIds.every(id => typeof id === 'string') && 'revision' in data && typeof data.revision === 'number') return data as LocalDraft; } catch { /* Damaged local cache is not server truth. */ }
}

export function Composer({ conversation, bot, replyId, clearReply, accepted }: { conversation: Conversation; bot?: Bot; replyId: string | null; clearReply: () => void; accepted: (resources: Pick<MessageReceipt, 'entries' | 'runs'>) => void }) {
  const { client, snapshot, online, realtime } = useApp(); const key = `lemonbot.composer:${snapshot.workspace.id}:${snapshot.user.id}:${conversation.id}`;
  const query = useQuery(`composer:${conversation.id}`, () => client.call('GET /conversations/:id/composer', { params: { id: conversation.id } }));
  const [local, setLocal] = useState<LocalDraft>(() => storedDraft(key) || { text: '', attachmentIds: [], replyToEntryId: null, revision: 0, references: [], mentions: [], everyone: false });
  const localRef = useRef(local); localRef.current = local; const [dirty, setDirty] = useState(!!storedDraft(key)); const dirtyRef = useRef(dirty); dirtyRef.current = dirty;
  const [conflict, setConflict] = useState<ComposerDraft>(); const [mode, setMode] = useState<MessageSend['mode']>('followup'); const [referenceKind, setReferenceKind] = useState<Reference['kind']>('skill'); const [showReferences, setShowReferences] = useState(false); const [showDictation, setShowDictation] = useState(false); const [showMore, setShowMore] = useState(false);
  const sendIntent = useIntent(); const saveIntent = useIntent(); const uploadIntent = useIntent(); const [error, setError] = useState<unknown>(); const [delivery, setDelivery] = useState<Pick<MessageReceipt, 'runs' | 'delivery'>>(); const textarea = useRef<HTMLTextAreaElement>(null); const typingAt = useRef(0); const journal = useRef<string | undefined>(local.unknownNonce);
  const references = useQuery(`composer-references:${conversation.id}:${referenceKind}`, async () => {
    const items: { id: string; name: string }[] = []; let cursor: string | undefined;
    if (referenceKind === 'bot') {
      do { const page = await client.call('GET /bots', { query: { limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items.map(bot => ({ id: bot.id, name: bot.name }))); cursor = page.nextCursor || undefined; } while (cursor);
    } else if (referenceKind === 'routine') {
      do { const page = await client.call('GET /routines', { query: { limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items.map(routine => ({ id: routine.id, name: routine.name }))); cursor = page.nextCursor || undefined; } while (cursor);
    } else if (referenceKind === 'skill') {
      do { const page = await client.call('GET /skills', { query: { limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items.map(skill => ({ id: skill.id, name: skill.name }))); cursor = page.nextCursor || undefined; } while (cursor);
    } else if (referenceKind === 'group') {
      do { const page = await client.call('GET /conversations', { query: { kind: 'group', limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items.map(group => ({ id: group.id, name: group.name }))); cursor = page.nextCursor || undefined; } while (cursor);
    } else for (const botId of conversation.botIds) {
      do { const page = await client.call('GET /bots/:id/connectors', { params: { id: botId }, query: { limit: 200, ...(cursor ? { cursor } : {}) } }); items.push(...page.items.map(connector => ({ id: connector.id, name: `${connector.name} (${connector.accountLabel})` }))); cursor = page.nextCursor || undefined; } while (cursor);
    }
    return { items, nextCursor: null };
  });
  useEffect(() => {
    const remote = query.data; if (!remote) return;
    const current = localRef.current;
    const same = remote.text === current.text && remote.attachmentIds.join() === current.attachmentIds.join() && remote.replyToEntryId === current.replyToEntryId;
    if (dirtyRef.current) {
      if (same) { setLocal(value => ({ ...value, revision: remote.revision })); setDirty(false); setConflict(undefined); }
      else if (!current.revision && (remote.text || remote.attachmentIds.length || remote.replyToEntryId)) setConflict(remote);
      else if (current.revision && remote.revision !== current.revision) setConflict(remote);
      else if (!current.revision) setLocal(value => ({ ...value, revision: remote.revision }));
    } else setLocal(value => ({ ...value, text: remote.text, attachmentIds: remote.attachmentIds, replyToEntryId: remote.replyToEntryId, revision: remote.revision, ...(same ? {} : { references: [], mentions: [], everyone: false }) }));
  }, [query.data?.revision]);
  useEffect(() => { if (replyId) { setLocal(current => ({ ...current, replyToEntryId: replyId })); setDirty(true); } }, [replyId]);
  useEffect(() => { if (dirty || local.unknownNonce || local.text || local.attachmentIds.length || local.references.length || local.mentions.length || local.everyone || local.acknowledged) sessionStorage.setItem(key, JSON.stringify(local)); else sessionStorage.removeItem(key); }, [local, dirty, key]);
  useEffect(() => {
    const promptKey = `lemonbot.prompt:${snapshot.workspace.id}:${snapshot.user.id}:${conversation.id}`;
    const prompt = sessionStorage.getItem(promptKey);
    if (prompt) { setLocal(current => ({ ...current, text: current.text ? `${current.text}\n${prompt}` : prompt })); setDirty(true); sessionStorage.removeItem(promptKey); }
  }, [conversation.id, snapshot.workspace.id, snapshot.user.id]);
  useEffect(() => {
    function insert(event: Event) { const detail = (event as CustomEvent<{ conversationId: string; text: string }>).detail; if (detail?.conversationId === conversation.id && typeof detail.text === 'string') { setLocal(current => ({ ...current, text: current.text ? `${current.text}\n${detail.text}` : detail.text })); setDirty(true); sessionStorage.removeItem(`lemonbot.prompt:${snapshot.workspace.id}:${snapshot.user.id}:${conversation.id}`); textarea.current?.focus(); } }
    window.addEventListener('lemonbot:draft-prompt', insert); return () => window.removeEventListener('lemonbot:draft-prompt', insert);
  }, [conversation.id]);
  useEffect(() => {
    if (!realtime) return;
    return realtime.subscribe(frame => { if (frame.type === 'event' && frame.event === 'composer.updated' && frame.payload.conversationId === conversation.id) query.setData(frame.payload); });
  }, [realtime, conversation.id]);
  async function save() {
    const current = localRef.current; if (!online || !current.revision || conflict || journal.current) return;
    await saveIntent.run(async () => { const result = await client.call('PUT /conversations/:id/composer', { params: { id: conversation.id }, body: { revision: current.revision, clientNonce: nonce(), text: current.text, attachmentIds: current.attachmentIds, replyToEntryId: current.replyToEntryId } }); query.setData(result); setLocal(value => ({ ...value, revision: result.revision })); if (localRef.current.text === current.text && localRef.current.attachmentIds.join() === current.attachmentIds.join() && localRef.current.replyToEntryId === current.replyToEntryId) setDirty(false); });
  }
  useEffect(() => {
    if (!dirty || !online || !local.revision || conflict || saveIntent.busy || saveIntent.error || sendIntent.busy || journal.current) return;
    const timer = window.setTimeout(() => void save(), 700); return () => clearTimeout(timer);
  }, [local.text, local.attachmentIds, local.replyToEntryId, local.revision, dirty, online, conflict, saveIntent.busy, saveIntent.error, sendIntent.busy]);
  function change(text: string) { setLocal(current => ({ ...current, text })); setDirty(true); if (realtime?.state === 'live' && Date.now() - typingAt.current > 1000) { typingAt.current = Date.now(); try { realtime.send({ type: 'typing', conversationId: conversation.id, active: !!text }); } catch (failure) { setError(failure); } } }
  async function upload(files: File[]) {
    if (!online || sendIntent.busy || uploadIntent.busy) return;
    if (localRef.current.attachmentIds.length + files.length > 6) { setError(new Error('At most six files per message.')); return; }
    await uploadIntent.run(async () => {
      for (const file of files) {
        const max = file.type.startsWith('video/') ? Math.min(snapshot.capabilities.videoMaxBytes, 200 * 1024 * 1024) : Math.min(snapshot.capabilities.attachmentMaxBytes, 25 * 1024 * 1024);
        if (!file.size || file.size > max) throw new Error(`${file.name}: empty or exceeds the ${Math.floor(max / 1024 / 1024)} MiB upload limit.`);
        const attachment = await client.upload(file, { clientNonce: nonce(), conversationId: conversation.id, purpose: 'message' }, file.name);
        if (attachment.state !== 'ready') throw new Error(`${file.name}: upload did not become ready.`);
        setLocal(current => ({ ...current, attachmentIds: [...current.attachmentIds, attachment.id] })); setDirty(true);
      }
    });
  }
  async function send() {
    const current = localRef.current;
    if (!online || sendIntent.busy || sendIntent.uncertain || saveIntent.busy || saveIntent.uncertain || uploadIntent.busy || journal.current || conflict || current.acknowledged) return;
    if (!current.text.trim() && !current.attachmentIds.length) return;
    if (new TextEncoder().encode(current.text).length > 64 * 1024) { setError(new Error('Message exceeds 64 KiB.')); return; }
    setError(undefined); const clientNonce = nonce(); journal.current = clientNonce; setLocal(value => ({ ...value, unknownNonce: clientNonce, refused: false })); sessionStorage.setItem(key, JSON.stringify({ ...current, unknownNonce: clientNonce, refused: false }));
    const result = await sendIntent.run(async () => {
      const receipt = await client.call('POST /conversations/:id/messages', { params: { id: conversation.id }, body: { clientNonce, text: current.text, attachmentIds: current.attachmentIds, ...(current.replyToEntryId ? { replyToEntryId: current.replyToEntryId } : {}), mentions: current.mentions, everyone: current.everyone, references: current.references, mode } }); accepted(receipt); setDelivery(receipt);
      if (receipt.status === 'outcome_unknown') throw new Error('We couldn’t confirm your message was delivered. Check its status before sending again.');
      return receipt;
    });
    if (!result) {
      const failure = sendIntent.lastError.current;
      const recordedEntries = failure instanceof LemonBotError ? failure.details?.entryIds : undefined;
      const recordedRuns = failure instanceof LemonBotError ? failure.details?.runIds : undefined;
      const recordedRefusal = failure instanceof LemonBotError && !failure.outcomeUnknown && ((Array.isArray(recordedEntries) && recordedEntries.length > 0) || (Array.isArray(recordedRuns) && recordedRuns.length > 0));
      if (recordedRefusal) setLocal(value => ({ ...value, refused: true }));
      else if (failure !== undefined && !unknownOutcome(failure)) { journal.current = undefined; setLocal(value => ({ ...value, unknownNonce: undefined, refused: false })); }
      return;
    }
    journal.current = undefined; clearReply(); if (realtime?.state === 'live') { try { realtime.send({ type: 'typing', conversationId: conversation.id, active: false }); } catch (failure) { setError(failure); } }
    setLocal(value => ({ ...value, text: '', attachmentIds: [], replyToEntryId: null, references: [], mentions: [], everyone: false, unknownNonce: undefined, refused: false })); setDirty(true);
  }
  async function reconcileMessage() {
    const clientNonce = journal.current || localRef.current.unknownNonce; if (!clientNonce) { await query.reload(); return; }
    const receipt = await client.messageReceipt(conversation.id, clientNonce);
    if (receipt.status === 'outcome_unknown' || receipt.runs.some(run => run.status === 'outcome_unknown' || run.status === 'reserved') || receipt.delivery.length !== receipt.runs.length || receipt.delivery.some(target => target.effectiveMode === 'outcome_unknown')) throw new Error('We still can’t confirm delivery. Your draft is kept. Check status again before sending anything else.');
    accepted(receipt);
    journal.current = undefined; setLocal(current => ({ ...current, unknownNonce: undefined, acknowledged: true, refused: receipt.delivery.length > 0 && receipt.delivery.every(target => target.effectiveMode === 'rejected') }));
    setDelivery(receipt);
    setError(undefined);
  }
  useEffect(() => { const focus = () => textarea.current?.focus(); const dictate = (event: KeyboardEvent) => { if ((event.metaKey || event.ctrlKey) && !event.shiftKey && event.key.toLowerCase() === 'd') { event.preventDefault(); setShowDictation(value => !value); } }; window.addEventListener('lemonbot:focus-composer', focus); window.addEventListener('keydown', dictate); return () => { window.removeEventListener('lemonbot:focus-composer', focus); window.removeEventListener('keydown', dictate); }; }, []);
  useEffect(() => { const element = textarea.current; if (!element) return; element.style.height = 'auto'; element.style.height = `${Math.min(element.scrollHeight, 220)}px`; }, [local.text]);
  const blocked = !online || sendIntent.busy || sendIntent.uncertain || saveIntent.busy || saveIntent.uncertain || uploadIntent.busy || !!journal.current || !!conflict || !!local.acknowledged;
  const ownsVoice = ['dm', 'task'].includes(conversation.kind) && conversation.ownerUserId === snapshot.user.id && conversation.botIds.every(id => { const bot = snapshot.bots.find(value => value.id === id); return bot && bot.ownerUserId === snapshot.user.id; });
  const empty = !local.text.trim() && !local.attachmentIds.length;
  const placeholder = `Message ${conversation.kind === 'dm' && bot ? bot.name : conversation.name || 'your Bot'}`;
  const problem = !!(query.error || error || sendIntent.error || saveIntent.error || uploadIntent.error || local.unknownNonce || local.acknowledged || conflict);
  const rejected = delivery && (delivery.delivery.some(item => item.effectiveMode === 'rejected' || item.effectiveMode === 'outcome_unknown') || delivery.runs.some(run => run.status === 'failed' || run.status === 'outcome_unknown'));
  return <section className="chat-composer" aria-label="Message composer">
    {problem && <div className="chat-composer-notices">
      <ErrorNotice error={query.error || error} />
      <IntentNotice intent={sendIntent} reconcile={reconcileMessage} />
      <IntentNotice intent={saveIntent} reconcile={async () => { await query.reload(); }} />
      <IntentNotice intent={uploadIntent} reconcile={async () => { await client.call('GET /attachments', { query: { conversationId: conversation.id, limit: 200 } }); }} />
      {local.unknownNonce && !sendIntent.error && !sendIntent.uncertain && <p className="error-notice">{local.refused ? 'Your message couldn’t be sent as requested. Check what happened before sending again.' : 'We couldn’t confirm your message was delivered. Your draft is kept.'} <button disabled={!online || sendIntent.busy} onClick={() => void sendIntent.reconcile(reconcileMessage)}>Check status</button></p>}
      {local.acknowledged && <p className="chat-notice">{local.refused ? 'The message was received, but the Bots could not start. Your text is kept for reference only.' : 'This message was already received. Your text is kept for reference only.'} <button onClick={() => { setLocal(current => ({ ...current, text: '', attachmentIds: [], replyToEntryId: null, references: [], mentions: [], everyone: false, acknowledged: false })); setDirty(true); clearReply(); setError(undefined); }}>Dismiss</button></p>}
      {conflict && <div className="error-notice"><p>This draft changed on another device. Your version is kept until you choose.</p><button onClick={() => { setLocal(current => ({ ...current, text: conflict.text, attachmentIds: conflict.attachmentIds, replyToEntryId: conflict.replyToEntryId, revision: conflict.revision })); setDirty(false); setConflict(undefined); }}>Use the newer draft</button><button onClick={() => { setLocal(current => ({ ...current, revision: conflict.revision })); setDirty(true); setConflict(undefined); }}>Keep my version</button></div>}
    </div>}
    {rejected && <div className="chat-delivery" role="status">{delivery.delivery.length ? delivery.delivery.map(item => <p key={item.botId}>{snapshot.bots.find(bot => bot.id === item.botId)?.name || 'Bot'}: <strong>{deliveryLabels[item.effectiveMode] || humanize(item.effectiveMode)}</strong></p>) : delivery.runs.map(run => <p key={run.id}>{snapshot.bots.find(bot => bot.id === run.botId)?.name || 'Bot'}: <strong>{run.status === 'outcome_unknown' ? 'Status unknown' : run.status === 'failed' && run.startedAtMs === null ? 'Not started' : humanize(run.status)}</strong></p>)}<details><summary>Details</summary>{delivery.runs.map(run => <p key={run.id} className="small"><code>{run.id}</code>{run.error && <> · {run.error.message} · {run.error.code} · request <code>{run.error.requestId}</code></>}</p>)}<p className="muted small">Rejected Bots did not start. Nothing is sent again automatically. Anything already done was not undone.</p></details><button className="chat-link" onClick={() => setDelivery(undefined)}>Dismiss</button></div>}
    {local.replyToEntryId && <div className="chat-reply-chip"><span>Replying to a message</span><button className="icon-button" aria-label="Cancel reply" onClick={() => { clearReply(); setLocal(current => ({ ...current, replyToEntryId: null })); setDirty(true); }}><X size={14}/></button></div>}
    {(local.attachmentIds.length > 0 || local.references.length > 0) && <div className="chat-staged">{local.attachmentIds.map(id => <div className="chat-staged-item" key={id}><AttachmentLink id={id} /><button type="button" className="icon-button" aria-label="Remove staged file" disabled={sendIntent.busy || !!journal.current} onClick={() => { setLocal(current => ({ ...current, attachmentIds: current.attachmentIds.filter(value => value !== id) })); setDirty(true); }}><X size={14}/></button></div>)}{local.references.map(reference => <button key={`${reference.kind}:${reference.id}`} className="chip" aria-label={`Remove ${reference.kind} reference`} onClick={() => { setLocal(current => ({ ...current, references: current.references.filter(item => item !== reference), mentions: current.mentions.filter(id => id !== reference.id) })); setDirty(true); }}>{reference.kind === 'skill' ? '/' : '@'}{references.data?.items.find(item => item.id === reference.id)?.name || reference.kind} <X size={12}/></button>)}</div>}
    <form className={`chat-pill ${local.text.includes('\n') || local.text.length > 80 ? 'multiline' : ''}`} onSubmit={event => { event.preventDefault(); void send(); }}>
      <details className="chat-more" open={showMore} onToggle={event => setShowMore((event.currentTarget as HTMLDetailsElement).open)}>
        <summary className="chat-plus" aria-label="Add files, references or delivery mode"><Plus size={17}/></summary>
        <div className="menu chat-more-menu stack">
          <label className="menu-item">Attach files<input aria-label="Attach files" className="chat-file-input" type="file" multiple disabled={!online || uploadIntent.busy || local.attachmentIds.length >= 6 || !!journal.current} onChange={event => { void upload(Array.from(event.target.files || [])); event.target.value = ''; setShowMore(false); }} /></label>
          <button type="button" className="menu-item" onClick={() => { setShowReferences(!showReferences); setShowMore(false); }} aria-expanded={showReferences}>/ Skills · @ References</button>
          {ownsVoice && <button type="button" className="menu-item" disabled={!online || !!local.text.trim() || !!local.attachmentIds.length || !!journal.current} onClick={() => { startLiveVoice(conversation.id); setShowMore(false); }}>Start voice call</button>}
          <label className="menu-item menu-select">When to send <select value={mode} onChange={event => setMode(event.target.value as MessageSend['mode'])}><option value="followup">Follow-up</option><option value="steer">Steer active work</option><option value="interrupt">Interrupt active work</option></select></label>
          <p className="muted small">Follow-up sends after the Bot finishes. Steer adjusts its current work. Interrupt stops it and sends now.</p>
          <button type="button" className="menu-item" disabled={!online || blocked} onClick={() => { void save(); setShowMore(false); }}>Save draft now</button>
          <button type="button" className="menu-item" disabled={sendIntent.busy || !!journal.current} onClick={() => { setLocal(current => ({ ...current, text: '', attachmentIds: [], replyToEntryId: null, references: [], mentions: [], everyone: false, acknowledged: false })); setDirty(true); clearReply(); setError(undefined); setShowMore(false); }}>Clear draft</button>
          <p className="muted small">{!online ? 'Offline. Your draft is saved on this device.' : saveIntent.busy ? 'Saving your draft…' : dirty ? 'Draft not yet saved to your account' : 'Draft saved to your account'} · up to six files</p>
        </div>
      </details>
      <label className="sr-only" htmlFor={`message-${conversation.id}`}>Message {conversation.kind === 'group' ? 'the group' : 'your Bot'}</label>
      <textarea id={`message-${conversation.id}`} ref={textarea} rows={1} value={local.text} disabled={sendIntent.busy || !!journal.current || !!local.acknowledged} placeholder={placeholder} enterKeyHint="send" onChange={event => { change(event.target.value); if (/[\/@]$/.test(event.target.value)) setShowReferences(true); }} onPaste={event => { const images = Array.from(event.clipboardData.items).filter(item => item.kind === 'file' && item.type.startsWith('image/')).map(item => item.getAsFile()).filter((file): file is File => !!file); if (images.length) { event.preventDefault(); void upload(images); } }} onKeyDown={event => { if (event.key === 'Enter' && !event.nativeEvent.isComposing && (event.metaKey || event.ctrlKey || (!event.shiftKey && !matchMedia('(hover: none)').matches))) { event.preventDefault(); void send(); } }} />
      <button type="button" className={`chat-round ${showDictation ? 'selected' : ''}`} aria-label="Dictate, then review" title={`Dictate (${navigator.platform.includes('Mac') ? '⌘' : 'Ctrl+'}D)`} aria-expanded={showDictation} onClick={() => setShowDictation(!showDictation)}><Mic size={17}/></button>
      {empty && ownsVoice ? <button type="button" className="chat-send" aria-label="Start voice chat" title="Voice chat" disabled={!online || !!journal.current} onClick={() => startLiveVoice(conversation.id)}><AudioLines size={16} strokeWidth={2.4}/></button> : <button className="chat-send" aria-label="Send" title="Send (Enter)" disabled={blocked || empty}><ArrowUp size={16} strokeWidth={2.6}/></button>}
    </form>
    {showReferences && <div className="chat-popover stack">
      <div className="row spread"><Field label="Reference type"><select value={referenceKind} onChange={event => setReferenceKind(event.target.value as Reference['kind'])}><option value="skill">/ Skill</option><option value="bot">@ Bot</option><option value="routine">@ Routine</option><option value="connector">@ Connector</option><option value="group">@ Group</option></select></Field><button className="icon-button" aria-label="Close references" onClick={() => setShowReferences(false)}><X size={16}/></button></div>
      <ErrorNotice error={references.error} />
      <div className="chat-reference-list">{references.data?.items.map(item => <button key={item.id} className="chip" onClick={() => { setLocal(current => ({ ...current, text: `${current.text}${current.text && !/[\/@\s]$/.test(current.text) ? ' ' : ''}${/[\/@]$/.test(current.text) ? '' : referenceKind === 'skill' ? '/' : '@'}${item.name} `, references: [...current.references.filter(reference => reference.id !== item.id || reference.kind !== referenceKind), { kind: referenceKind, id: item.id }], mentions: referenceKind === 'bot' && conversation.botIds.includes(item.id) ? [...new Set([...current.mentions, item.id])] : current.mentions })); setDirty(true); textarea.current?.focus(); }}>{item.name}</button>)}</div>
      {conversation.kind === 'group' && <label className="row"><input type="checkbox" checked={local.everyone} onChange={event => { setLocal(current => ({ ...current, everyone: event.target.checked })); setDirty(true); }} />@everyone — wake each group Bot once</label>}
      <p className="muted small">References add context. They don’t grant permissions.</p>
    </div>}
    {!online && <p className="chat-status-line">Offline. Your draft is saved on this device.</p>}
    {showDictation && <div className="chat-popover"><CaptureControls conversationId={conversation.id} language={snapshot.user.preferences.voice.language} onText={text => change(localRef.current.text ? `${localRef.current.text}\n${text}` : text)} /></div>}
  </section>;
}
