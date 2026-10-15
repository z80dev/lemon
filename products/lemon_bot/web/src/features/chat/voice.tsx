import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { nonce } from '@lemon-bot/sdk';
import type { TranscriptEntry, VoiceSession, VoiceSettings } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, Field, formatTime } from '../../ui';
import { CaptureControls } from './capture';
import { IntentNotice, mergeEntries, unknownOutcome, useClock, useIntent } from './common';
import { RichText } from './files';
import { voiceStateLabels } from '../../live';

interface VoiceRequest { conversationId: string }
let requested: VoiceRequest | null = null; const listeners = new Set<() => void>();
export function startLiveVoice(conversationId: string) { requested = { conversationId }; for (const listener of listeners) listener(); }
function subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener); }; }
function clearRequest() { requested = null; for (const listener of listeners) listener(); }

export function VoiceOverlay() {
  const { client, device, snapshot, realtime, online, navigate, draftPrompt } = useApp(); const request = useSyncExternalStore(subscribe, () => requested, () => null);
  const [session, setSession] = useState<VoiceSession>(); const sessionRef = useRef(session); sessionRef.current = session;
  const [settings, setSettings] = useState<VoiceSettings>(snapshot.user.preferences.voice); const [entries, setEntries] = useState<TranscriptEntry[]>([]);
  const [listening, setListening] = useState(false); const [status, setStatus] = useState('Microphone off'); const [speechError, setSpeechError] = useState<unknown>(); const [showTranscript, setShowTranscript] = useState(true); const [conflictId, setConflictId] = useState<string>();
  const [pendingUtterance, setPendingUtterance] = useState<{ text: string; clientNonce: string; safeToDraft?: boolean }>(); const pendingRef = useRef(pendingUtterance); pendingRef.current = pendingUtterance;
  const completedSpeech = useRef(new Set<string>());
  const endIntent = useIntent(); const sessionKey = `lemonbot.voiceSession:${snapshot.workspace.id}:${snapshot.user.id}`;
  const intent = useIntent(); const clock = useClock(); const runs = useRef(new Set<string>()); const spoken = useRef(new Map<string, number>()); const liveEntries = useRef<TranscriptEntry[]>([]); const audio = useRef<HTMLAudioElement | null>(null); const speaking = useRef(false); const queue = useRef(Promise.resolve()); const epoch = useRef(0);
  const paused = useRef(true);
  function silence() { paused.current = true; epoch.current++; audio.current?.pause(); audio.current = null; window.speechSynthesis?.cancel(); speaking.current = false; setListening(false); }
  async function reconcile() {
    const current = sessionRef.current; if (!current) return;
    const actual = await client.call('GET /voice/sessions/:id', { params: { id: current.id } }); setSession(actual);
    const page = await client.call('GET /conversations/:id/entries', { params: { id: actual.conversationId }, query: { limit: 200 } }); setEntries(page.items); liveEntries.current = page.items;
    if (pendingRef.current) {
      const receipt = await client.messageReceipt(current.conversationId, pendingRef.current.clientNonce);
      if (receipt.status === 'outcome_unknown' || receipt.runs.some(run => run.status === 'reserved' || run.status === 'outcome_unknown') || receipt.delivery.length !== receipt.runs.length || receipt.delivery.some(target => target.effectiveMode === 'outcome_unknown')) throw new Error('We still can’t confirm your last words were sent. Your transcript is kept. Check status before speaking again.');
      receipt.runs.forEach(run => runs.current.add(run.id)); setPendingUtterance(undefined); pendingRef.current = undefined; sessionStorage.removeItem(`${sessionKey}:utterance`);
      const failures = receipt.runs.flatMap(run => run.error ? [run.error.message] : []);
      if (failures.length) setSpeechError(new Error(failures.join('\n')));
    }
    setStatus(actual.state === 'active' ? 'Call restored. Microphone is off. Tap Resume to continue.' : voiceStateLabels[actual.state]);
  }
  useEffect(() => {
    const saved = sessionStorage.getItem(sessionKey);
    const utterance = sessionStorage.getItem(`${sessionKey}:utterance`);
    if (utterance) { try { const value: unknown = JSON.parse(utterance); if (value && typeof value === 'object' && 'text' in value && typeof value.text === 'string' && 'clientNonce' in value && typeof value.clientNonce === 'string') setPendingUtterance({ text: value.text, clientNonce: value.clientNonce, safeToDraft: 'safeToDraft' in value && value.safeToDraft === true }); } catch { setSpeechError(new Error('The local voice review transcript could not be read. No call or utterance was restarted.')); } }
    if (saved) client.call('GET /voice/sessions/:id', { params: { id: saved } }).then(actual => { if (actual.userId === snapshot.user.id) { setSession(actual); setSettings(actual.settings); setStatus('Call restored. Microphone is off. Tap Resume to continue.'); } }).catch(setSpeechError);
    return () => { silence(); clearRequest(); };
  }, [client, snapshot.user.id]);
  useEffect(() => { if (session) sessionStorage.setItem(sessionKey, session.id); }, [session?.id, sessionKey]);
  useEffect(() => { if (!online || session?.state !== 'active' || session.muted) silence(); }, [online, session?.state, session?.muted]);
  async function begin() {
    if (!request || !device || !online || !realtime || pendingRef.current || sessionRef.current?.state === 'active') return;
    silence(); setSpeechError(undefined);
    await intent.run(async () => {
      setStatus('Connecting…');
      try {
        const actual = await client.call('POST /voice/sessions', { body: { clientNonce: nonce(), conversationId: request.conversationId, deviceId: device.id, settings } });
        paused.current = false; setSession(actual); setEntries([]); liveEntries.current = []; runs.current.clear(); spoken.current.clear(); completedSpeech.current.clear(); setConflictId(undefined); clearRequest(); setStatus('Active call'); setListening(actual.state === 'active' && !actual.muted);
      } catch (error) {
        if (error && typeof error === 'object' && 'details' in error) { const details = error.details; if (details && typeof details === 'object') { const record = details as Record<string, unknown>; const id = record.voiceSessionId || record.existingSessionId || record.sessionId || (Array.isArray(record.resourceIds) ? record.resourceIds[0] : undefined); if (typeof id === 'string') setConflictId(id); } }
        setStatus('Call start not confirmed'); throw error;
      }
    });
  }
  async function update(patch: { muted?: boolean; settings?: VoiceSettings; feedback?: 'good' | 'bad' }) {
    const current = sessionRef.current; if (!current || !online) return;
    if (patch.muted) silence();
    await intent.run(async () => { const actual = await client.call('PATCH /voice/sessions/:id', { params: { id: current.id }, body: { revision: current.revision, clientNonce: nonce(), ...patch } }); setSession(actual); setSettings(actual.settings); });
  }
  async function end() { const current = sessionRef.current; if (!current || !online) return; silence(); await endIntent.run(async () => { const actual = await client.call('POST /voice/sessions/:id/end', { params: { id: current.id }, body: { clientNonce: nonce() } }); setSession(actual); setStatus(voiceStateLabels[actual.state]); }); }
  async function send(text: string) {
    const current = sessionRef.current; setListening(false);
    if (!current || current.state !== 'active' || current.muted || !online || intent.uncertain) return;
    setStatus('Sending utterance…'); const clientNonce = nonce(); const pending = { text, clientNonce }; pendingRef.current = pending; setPendingUtterance(pending); sessionStorage.setItem(`${sessionKey}:utterance`, JSON.stringify(pending)); runs.current.clear();
    const result = await intent.run(async () => {
      const receipt = await client.call('POST /conversations/:id/messages', { params: { id: current.conversationId }, body: { clientNonce, text, voiceSessionId: current.id } });
      receipt.runs.forEach(run => runs.current.add(run.id)); liveEntries.current = mergeEntries(liveEntries.current, receipt.entries); setEntries(liveEntries.current);
      setStatus(receipt.status === 'outcome_unknown' ? 'Couldn’t confirm your last words were sent. They’re in the transcript.' : receipt.delivery.some(delivery => delivery.effectiveMode === 'rejected') ? 'Some Bots couldn’t start. Check the conversation.' : 'Message received.');
      if (receipt.status === 'outcome_unknown') throw new Error('We couldn’t confirm your last words were sent. Check the conversation before resuming.');
      return receipt;
    });
    if (result) {
      setPendingUtterance(undefined); pendingRef.current = undefined; sessionStorage.removeItem(`${sessionKey}:utterance`);
      const page = await client.call('GET /conversations/:id/entries', { params: { id: current.conversationId }, query: { limit: 200 } });
      liveEntries.current = mergeEntries(liveEntries.current, page.items); setEntries(liveEntries.current);
      for (const entry of page.items) enqueueSpeech(entry, entry.kind === 'message' && !entry.streaming);
    }
    else if (intent.lastError.current !== undefined && !unknownOutcome(intent.lastError.current)) { const unsent = { text, clientNonce, safeToDraft: true }; setPendingUtterance(unsent); sessionStorage.setItem(`${sessionKey}:utterance`, JSON.stringify(unsent)); setStatus('Utterance was refused before acceptance. Review it in the composer if desired.'); }
  }
  function enqueueSpeech(entry: TranscriptEntry, final: boolean) {
    if (entry.kind !== 'message' || entry.role !== 'assistant' || !entry.runId || !runs.current.has(entry.runId)) return;
    if (completedSpeech.current.has(entry.id)) return;
    const current = sessionRef.current; if (!current || current.state !== 'active' || paused.current) return;
    const already = spoken.current.get(entry.id) || 0; const rest = entry.text.slice(already);
    let length = 0;
    if (final) length = rest.length;
    else { const matches = [...rest.matchAll(/[.!?](?:\s|$)/g)]; const last = matches.at(-1); if (last?.index !== undefined) length = last.index + last[0].length; }
    if (!length && !final) return;
    if (final) completedSpeech.current.add(entry.id);
    spoken.current.set(entry.id, already + length); const text = rest.slice(0, length); const turnEpoch = epoch.current;
    speaking.current = true; setListening(false); setStatus('Speaking reply…');
    queue.current = queue.current.then(async () => {
      if (turnEpoch !== epoch.current || sessionRef.current?.state !== 'active') return;
      for (let offset = 0; offset < text.length; offset += 4096) {
        const segment = text.slice(offset, offset + 4096); const voice = sessionRef.current?.settings || settings;
        if (snapshot.capabilities.tts) {
          const result = await client.call('POST /audio/speech', { body: { clientNonce: nonce(), text: segment, voice, conversationId: current.conversationId, voiceSessionId: current.id } });
          const bytes = await client.downloadBytes(result.download); if (turnEpoch !== epoch.current) return;
          const url = URL.createObjectURL(new Blob([bytes.slice().buffer as ArrayBuffer], { type: result.download.mime }));
          try { await new Promise<void>((resolve, reject) => { const player = new Audio(url); audio.current = player; player.onended = () => resolve(); player.onerror = () => reject(new Error('Synthesized speech playback failed.')); player.onpause = () => { if (turnEpoch !== epoch.current) resolve(); }; void player.play().catch(reject); }); }
          finally { URL.revokeObjectURL(url); audio.current = null; }
        } else {
          if (!window.speechSynthesis) throw new Error('No backend TTS provider or browser speech synthesis is available. Read the transcript.');
          await new Promise<void>((resolve, reject) => { const utterance = new SpeechSynthesisUtterance(segment); utterance.rate = voice.speed; if (voice.language) utterance.lang = voice.language; const selected = speechSynthesis.getVoices().find(item => item.voiceURI === voice.voiceId || item.name === voice.voiceId); if (selected) utterance.voice = selected; utterance.onend = () => resolve(); utterance.onerror = () => turnEpoch !== epoch.current ? resolve() : reject(new Error('Browser speech synthesis failed.')); speechSynthesis.speak(utterance); });
        }
      }
    }).catch(error => { setSpeechError(error); silence(); setStatus('Speech stopped. Review the transcript, then tap Resume to continue.'); });
    if (final) { const lastQueue = queue.current; void lastQueue.then(() => { if (queue.current === lastQueue && turnEpoch === epoch.current && sessionRef.current?.state === 'active' && !sessionRef.current.muted && !pendingRef.current) { speaking.current = false; setStatus('Ready for your next utterance'); setListening(true); } }); }
  }
  useEffect(() => {
    if (!realtime) return;
    return realtime.subscribe(frame => {
      if (frame.type !== 'event') return;
      const current = sessionRef.current; if (!current) return;
      if (frame.event === 'voice.upserted' && frame.payload.id === current.id) { setSession(frame.payload); setSettings(frame.payload.settings); return; }
      if (frame.event === 'entry.upserted' && frame.payload.conversationId === current.conversationId) { liveEntries.current = mergeEntries(liveEntries.current, [frame.payload]); setEntries(liveEntries.current); enqueueSpeech(frame.payload, frame.payload.kind === 'message' && !frame.payload.streaming); }
      if (frame.event === 'entry.delta' && frame.payload.conversationId === current.conversationId) {
        const delta = frame.payload; const old = liveEntries.current.find(entry => entry.id === delta.entryId);
        if (!old || old.kind !== 'message' || old.text.length !== delta.offset || old.runId !== delta.runId) {
          client.call('GET /entries/:id', { params: { id: delta.entryId } }).then(entry => { liveEntries.current = mergeEntries(liveEntries.current, [entry]); setEntries(liveEntries.current); enqueueSpeech(entry, entry.kind === 'message' && !entry.streaming); }).catch(setSpeechError); return;
        }
        const next = { ...old, text: old.text + delta.text }; liveEntries.current = liveEntries.current.map(entry => entry.id === next.id ? next : entry); setEntries(liveEntries.current); enqueueSpeech(next, false);
      }
      if (frame.event === 'run.upserted' && runs.current.has(frame.payload.id) && ['failed', 'cancelled', 'outcome_unknown'].includes(frame.payload.status)) { silence(); setStatus(frame.payload.status === 'outcome_unknown' ? 'The Bot’s status is unknown. Check the conversation before resuming.' : frame.payload.status === 'cancelled' ? 'Work stopped. Anything already done was not undone.' : 'The Bot couldn’t finish. Check the conversation.'); }
    });
  }, [realtime, client, snapshot.capabilities.tts, settings]);
  if (!request && !session && !speechError && !pendingUtterance) return null;
  const active = session?.state === 'active'; const duration = session ? active ? clock - session.startedAtMs : session.durationMs : 0;
  return <aside className="chat-voice-overlay panel stack" aria-label="Live voice call">
    <div className="row spread"><h2>{session ? voiceStateLabels[session.state] : 'Review call'}</h2>{session && <span>{Math.max(0, Math.floor(duration / 1000))}s</span>}</div>
    <p role="status">{status}</p>
    {!online && <p className="error-notice">You’re offline. The microphone is off. Reconnect and check call status before resuming.</p>}
    {request && <>
      <p>Start an explicit live call in {snapshot.conversations.find(conversation => conversation.id === request.conversationId)?.name || request.conversationId}. Your final utterances will send as ordinary messages.</p>
      {active && <p>Another call is active. End it explicitly before starting a new one.</p>}
      <button className="primary" disabled={!device || !online || !realtime || active || intent.busy || intent.uncertain || !!pendingUtterance} onClick={() => void begin()}>Start call and microphone</button>
      <button onClick={clearRequest}>Cancel start</button>
      {!device && <p>Register this device in Settings before starting a call.</p>}
      {!realtime && <p>Live voice requires the product realtime connection.</p>}
    </>}
    {conflictId && <button disabled={intent.busy} onClick={() => void intent.reconcile(async () => { const actual = await client.call('GET /voice/sessions/:id', { params: { id: conflictId } }); setSession(actual); setSettings(actual.settings); setConflictId(undefined); clearRequest(); })}>Inspect existing call (microphone off)</button>}
    <ErrorNotice error={speechError} />
    <IntentNotice intent={intent} reconcile={async () => { if (sessionRef.current) await reconcile(); else if (conflictId) { const actual = await client.call('GET /voice/sessions/:id', { params: { id: conflictId } }); setSession(actual); } else throw new Error('Call identity is not known. Inspect account/device call status before starting another call.'); }} />
    <IntentNotice intent={endIntent} reconcile={async () => { const current = sessionRef.current; if (!current) return; const actual = await client.call('GET /voice/sessions/:id', { params: { id: current.id } }); setSession(actual); if (actual.state === 'active') throw new Error('End is still not confirmed. Microphone remains off; check call status.'); }} />
    {pendingUtterance && <div className="error-notice"><strong>{pendingUtterance.safeToDraft ? 'Not sent — review your words' : 'Couldn’t confirm your last words were sent'}</strong><p>{pendingUtterance.text}</p>{pendingUtterance.safeToDraft && session ? <button onClick={() => { draftPrompt(session.conversationId, pendingUtterance.text); navigate({ screen: 'conversation', id: session.conversationId }); setPendingUtterance(undefined); pendingRef.current = undefined; sessionStorage.removeItem(`${sessionKey}:utterance`); }}>Review in composer</button> : <button onClick={() => void intent.reconcile(reconcile)}>Check status</button>}</div>}
    {session && <>
      <div className="row">
        <button onClick={() => navigate({ screen: 'conversation', id: session.conversationId })}>Return to conversation</button>
        {active && <>
          <button disabled={!online || intent.busy || intent.uncertain} onClick={() => void update({ muted: !session.muted })}>{session.muted ? 'Unmute (then resume)' : 'Mute'}</button>
          <button disabled={!online || endIntent.busy || endIntent.uncertain} className="danger" onClick={() => void end()}>End call</button>
          <button disabled={!online || session.muted || session.deviceId !== device?.id || intent.busy || intent.uncertain || speaking.current || !!pendingUtterance} onClick={() => { paused.current = false; setSpeechError(undefined); setListening(true); }}>Resume microphone</button>
          <button onClick={silence}>Pause microphone and playback</button>
        </>}
      </div>
      {active && session.deviceId !== device?.id && <p>Call belongs to another device. End it explicitly before starting on this device.</p>}
      {active && !paused.current && session.deviceId === device?.id && !session.muted && !intent.uncertain && !intent.busy && !pendingUtterance && !speaking.current && <CaptureControls conversationId={session.conversationId} voiceSessionId={session.id} language={session.settings.language} autoStart={listening && online} onText={send} />}
      <details><summary>Voice / speed / language settings</summary>
        <Field label="Voice (default if blank)"><input value={settings.voiceId} onChange={event => setSettings({ ...settings, voiceId: event.target.value })}/></Field>
        <Field label="Speech speed"><input type="number" min={0.5} max={2} step={0.1} value={settings.speed} onChange={event => setSettings({ ...settings, speed: Number(event.target.value) })}/></Field>
        <Field label="Language (leave blank to detect automatically)"><input value={settings.language || ''} onChange={event => setSettings({ ...settings, language: event.target.value || null })}/></Field>
        <p className="muted">{snapshot.capabilities.tts ? 'Backend-generated speech' : 'Browser speech synthesis fallback (not persisted audio)'}</p>
        <button disabled={!active || intent.busy || intent.uncertain || !settings.voiceId.trim() || !Number.isFinite(settings.speed) || settings.speed < 0.5 || settings.speed > 2} onClick={() => void update({ settings })}>Apply call settings</button>
      </details>
      <button aria-expanded={showTranscript} onClick={() => { setShowTranscript(!showTranscript); if (!entries.length) void reconcile().catch(setSpeechError); }}>{showTranscript ? 'Hide' : 'Show'} transcript</button>
      {showTranscript && <div className="chat-voice-transcript">{entries.filter(entry => entry.kind === 'message').map(entry => <div key={entry.id}><strong>{entry.actor.displayName}</strong>{entry.kind === 'message' && <RichText text={entry.text} />}</div>)}</div>}
      {!active && <>
        <p>Ended {formatTime(session.endedAtMs)}. Chat work continues; this call does not cancel runs.</p>
        <div className="row"><button disabled={intent.busy || intent.uncertain} onClick={() => void update({ feedback: 'good' })} aria-pressed={session.feedback === 'good'}>Good call</button><button disabled={intent.busy || intent.uncertain} onClick={() => void update({ feedback: 'bad' })} aria-pressed={session.feedback === 'bad'}>Poor call</button><button disabled={!!pendingUtterance} onClick={() => { silence(); setSession(undefined); sessionStorage.removeItem(sessionKey); }}>Dismiss summary</button></div>
      </>}
    </>}
  </aside>;
}
