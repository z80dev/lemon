import { useEffect, useRef, useState } from 'react';
import { nonce } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice } from '../../ui';

interface RecognitionResult { isFinal: boolean; 0: { transcript: string }; length: number }
interface RecognitionEvent { resultIndex: number; results: { [index: number]: RecognitionResult; length: number } }
interface Recognition {
  lang: string; continuous: boolean; interimResults: boolean;
  onresult: ((event: RecognitionEvent) => void) | null; onerror: ((event: { error: string }) => void) | null; onend: (() => void) | null;
  start(): void; stop(): void; abort(): void;
}
interface SpeechWindow extends Window { SpeechRecognition?: new () => Recognition; webkitSpeechRecognition?: new () => Recognition }
let micOwner: symbol | null = null;

/** Explicit mic capture only. Dictation output remains unsent; live-call owner decides when to send. */
export function CaptureControls({ onText, language, voiceSessionId, conversationId, autoStart = false, onState }: { onText: (text: string) => void | Promise<void>; language: string | null; voiceSessionId?: string; conversationId: string; autoStart?: boolean; onState?: (active: boolean) => void }) {
  const { client, snapshot, online } = useApp(); const [state, setState] = useState<'idle' | 'listening' | 'transcribing'>('idle'); const [error, setError] = useState<unknown>(); const [interim, setInterim] = useState('');
  const owner = useRef(Symbol('microphone')); const recorder = useRef<MediaRecorder | null>(null); const stream = useRef<MediaStream | null>(null); const recognition = useRef<Recognition | null>(null); const active = useRef(false); const chunks = useRef<Blob[]>([]); const transcript = useRef(''); const cancelled = useRef(false); const timer = useRef<number | undefined>(undefined); const callback = useRef(onText); callback.current = onText;
  const Speech = (window as SpeechWindow).SpeechRecognition || (window as SpeechWindow).webkitSpeechRecognition;
  function release() { active.current = false; onState?.(false); clearTimeout(timer.current); stream.current?.getTracks().forEach(track => track.stop()); stream.current = null; recognition.current = null; if (micOwner === owner.current) micOwner = null; }
  function cancel() { cancelled.current = true; recognition.current?.abort(); if (recorder.current?.state === 'recording') recorder.current.stop(); release(); chunks.current = []; transcript.current = ''; setInterim(''); setState('idle'); }
  useEffect(() => () => { cancelled.current = true; recognition.current?.abort(); if (recorder.current?.state === 'recording') recorder.current.stop(); release(); }, []);
  async function start(backend = false) {
    if (active.current || state === 'transcribing') return;
    if (micOwner && micOwner !== owner.current) { setError(new Error('The microphone is already in use by dictation or a live call. Stop that capture first.')); return; }
    cancelled.current = false; micOwner = owner.current; active.current = true; transcript.current = ''; chunks.current = []; setError(undefined); setInterim('');
    try {
      if (Speech && !backend) {
        const instance = new Speech(); recognition.current = instance; instance.lang = language || navigator.language; instance.continuous = !voiceSessionId; instance.interimResults = true;
        instance.onresult = event => { let pending = ''; for (let i = event.resultIndex; i < event.results.length; i++) { const result = event.results[i]; if (result.isFinal) transcript.current += result[0].transcript + ' '; else pending += result[0].transcript; } setInterim(transcript.current + pending); };
        instance.onerror = event => { cancelled.current = true; setError(new Error(`Browser speech recognition: ${event.error}. Check microphone permission and input. You may explicitly choose backend audio transcription if configured.`)); release(); setState('idle'); };
        instance.onend = () => { const text = transcript.current.trim(); release(); setState('idle'); setInterim(''); if (!cancelled.current && text) void Promise.resolve(callback.current(text)).catch(setError); };
        instance.start(); setState('listening'); onState?.(true);
      } else {
        if (!snapshot.capabilities.stt) throw new Error('Backend transcription is not configured. This browser must provide Web Speech, or the operator must configure an STT provider.');
        if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') throw new Error('Audio capture is unavailable. Use an HTTPS origin and a supported browser.');
        const deviceId = localStorage.getItem('lemonbot.microphoneDeviceId');
        const input = await navigator.mediaDevices.getUserMedia({ audio: deviceId ? { deviceId: { exact: deviceId } } : true });
        if (cancelled.current) { input.getTracks().forEach(track => track.stop()); release(); return; }
        stream.current = input; const type = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/webm'].find(value => MediaRecorder.isTypeSupported(value));
        const capture = new MediaRecorder(input, type ? { mimeType: type } : undefined); recorder.current = capture;
        capture.ondataavailable = event => { if (event.data.size) chunks.current.push(event.data); };
        capture.onerror = () => { setError(new Error('Microphone recording failed. No message was sent.')); cancel(); };
        capture.onstop = () => { release(); if (cancelled.current) { setState('idle'); return; } const blob = new Blob(chunks.current, { type: capture.mimeType }); chunks.current = []; setState('transcribing');
          if (!blob.size || blob.size > 25 * 1024 * 1024) { setError(new Error('Recording is empty or exceeds 25 MiB. Nothing was sent.')); setState('idle'); return; }
          client.upload(blob, { clientNonce: nonce(), purpose: 'audio', conversationId }, capture.mimeType.includes('mp4') ? 'dictation.m4a' : 'dictation.webm').then(attachment => client.call('POST /audio/transcriptions', { body: { clientNonce: nonce(), attachmentId: attachment.id, ...(language ? { language } : {}), ...(voiceSessionId ? { voiceSessionId } : {}) } })).then(result => { if (!cancelled.current) return callback.current(result.text); }).catch(setError).finally(() => setState('idle'));
        };
        capture.start(1000); setState('listening'); onState?.(true);
      }
      timer.current = window.setTimeout(stop, 10 * 60 * 1000);
    } catch (failure) { release(); setState('idle'); setError(failure); }
  }
  function stop() { if (recognition.current) recognition.current.stop(); else if (recorder.current?.state === 'recording') recorder.current.stop(); }
  useEffect(() => { if (autoStart && online) void start(); else if (!autoStart && voiceSessionId) cancel(); }, [autoStart, online]);
  return <div className="chat-capture stack"><div className="row"><span role="status">{state === 'listening' ? '● Microphone on' : state === 'transcribing' ? 'Transcribing audio…' : 'Microphone off'}</span>{state === 'idle' && <><button type="button" disabled={!online} onClick={() => void start()}>{Speech ? 'Dictate with browser speech' : 'Record for backend transcription'}</button>{Speech && snapshot.capabilities.stt && <button type="button" disabled={!online} onClick={() => void start(true)}>Use backend audio instead</button>}</>}{state === 'listening' && <button type="button" onClick={stop}>{voiceSessionId ? 'Finish utterance' : 'Stop and review'}</button>}{state !== 'idle' && <button type="button" onClick={cancel}>Cancel capture</button>}</div>{interim && <p aria-live="polite" className="muted">{interim}</p>}<ErrorNotice error={error} /><p className="muted small">{voiceSessionId ? 'Explicit live call: completed utterances send into this conversation.' : 'Dictation is never sent automatically. Review and edit the transcript in the composer before Send.'} Browser speech may use your browser vendor’s speech service. No ambient listening.</p></div>;
}
