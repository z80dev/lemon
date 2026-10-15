import { useEffect, useRef, useState } from 'react';
import { nonce, type User, type VoiceSettings } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { useQuery, ErrorNotice, Loading, Field } from '../../ui';
import { useIntent, IntentNotice } from './shared';

export function VoiceSettingsScreen() {
  const { client, refresh } = useApp();
  const me = useQuery('settings:voice-user', () => client.call('GET /me'));
  const capabilities = useQuery('settings:voice-capabilities', () => client.call('GET /capabilities'));
  return <div className="stack"><ErrorNotice error={me.error} /><ErrorNotice error={capabilities.error} />{me.loading && !me.data && <Loading />}{me.data && <VoiceEditor user={me.data} backendTts={capabilities.data?.tts} backendStt={capabilities.data?.stt} onReload={async () => { await Promise.all([me.reload(), capabilities.reload(), refresh()]); }} onSaved={user => me.setData(user)} />}<MicrophoneSettings /></div>;
}
function VoiceEditor({ user, backendTts, backendStt, onReload, onSaved }: { user: User; backendTts: boolean | undefined; backendStt: boolean | undefined; onReload: () => Promise<void>; onSaved: (user: User) => void }) {
  const { client, refresh, reportError } = useApp();
  const [voice, setVoice] = useState<VoiceSettings>(user.preferences.voice);
  const [sample, setSample] = useState('Hello. I’m ready to help with your next task.');
  const [audioUrl, setAudioUrl] = useState<string>();
  const [localVoices, setLocalVoices] = useState<SpeechSynthesisVoice[]>([]);
  const [localVoice, setLocalVoice] = useState('');
  const audio = useRef<HTMLAudioElement>(null);
  const intent = useIntent(onReload);
  useEffect(() => { if (!('speechSynthesis' in window)) return; const update = () => setLocalVoices(speechSynthesis.getVoices()); update(); speechSynthesis.addEventListener('voiceschanged', update); return () => { speechSynthesis.removeEventListener('voiceschanged', update); speechSynthesis.cancel(); }; }, []);
  useEffect(() => () => { if (audioUrl) URL.revokeObjectURL(audioUrl); }, [audioUrl]);
  return <section className="panel stack">
    <h2>Voice & language</h2><IntentNotice intent={intent} />
    <dl className="settings-facts">
      <dt>Server voice</dt><dd>{backendTts === undefined ? 'Checking availability…' : backendTts ? 'On' : 'Off — ask your administrator to turn on server voice.'}</dd>
      <dt>Server transcription</dt><dd>{backendStt === undefined ? 'Checking availability…' : backendStt ? 'On' : 'Off — browser dictation may still work.'}</dd>
      <dt>Browser voice</dt><dd>{'speechSynthesis' in window ? 'Available on this device; it doesn’t use server voice.' : 'Not available in this browser.'}</dd>
      <dt>Dictation</dt><dd>{'SpeechRecognition' in window || 'webkitSpeechRecognition' in window ? 'Uses your browser; some browsers send audio to their company.' : 'Not supported in this browser.'}</dd>
    </dl>
    <form className="stack" onSubmit={e => { e.preventDefault(); void (async () => {
      const saved = await intent.run(() => client.call('PATCH /me', { body: { preferences: { ...user.preferences, voice }, revision: user.revision, clientNonce: nonce() } }));
      if (saved) { onSaved(saved); await refresh().catch(reportError); }
    })(); }}>
      <fieldset className="grid" disabled={intent.disabled}>
        <Field label="Server voice ID" hint="Use default or an ID supported by your server’s voice provider."><input required value={voice.voiceId} onChange={e => setVoice({ ...voice, voiceId: e.target.value })} /></Field>
        <Field label={`Speed · ${voice.speed.toFixed(2)}×`}><input type="range" min={0.5} max={2} step={0.05} value={voice.speed} onChange={e => setVoice({ ...voice, speed: Number(e.target.value) })} /></Field>
        <Field label="Speech language (BCP-47)" hint="Blank means automatic selection."><input value={voice.language ?? ''} onChange={e => setVoice({ ...voice, language: e.target.value || null })} /></Field>
      </fieldset>
      <button className="primary" disabled={intent.disabled}>Save voice preferences</button>
    </form>
    <Field label="Sample text"><textarea maxLength={4096} value={sample} onChange={e => setSample(e.target.value)} /></Field>
    <div className="row"><button disabled={intent.disabled || !backendTts || !sample.trim()} onClick={() => void intent.run(async () => {
    const result = await client.call('POST /audio/speech', { body: { text: sample, voice, clientNonce: nonce() } });
    const bytes = await client.downloadBytes(result.download);
    setAudioUrl(URL.createObjectURL(new Blob([new Uint8Array(bytes)], { type: result.download.mime })));
  })}>Play server voice sample</button>
    <button disabled={!audioUrl && !('speechSynthesis' in window)} onClick={() => { audio.current?.pause(); if ('speechSynthesis' in window) speechSynthesis.cancel(); }}>Stop playback</button>
    </div>{audioUrl && <audio ref={audio} controls autoPlay src={audioUrl} aria-label="Server voice sample" />}
    {'speechSynthesis' in window && <div className="card stack">
      <h3>Browser voice sample</h3>
      <Field label="Browser voice" hint="This sample uses your browser’s voices, not the server voice ID."><select value={localVoice} onChange={e => setLocalVoice(e.target.value)}><option value="">Browser default</option>{localVoices.map(item => <option key={item.voiceURI} value={item.voiceURI}>{item.name} · {item.lang} · {item.localService ? 'local' : 'browser network service'}</option>)}</select></Field>
      <button disabled={!sample.trim()} onClick={() => { speechSynthesis.cancel(); const utterance = new SpeechSynthesisUtterance(sample); utterance.rate = voice.speed; if (voice.language) utterance.lang = voice.language; utterance.voice = localVoices.find(item => item.voiceURI === localVoice) ?? null; speechSynthesis.speak(utterance); }}>Play browser voice sample</button>
    </div>}
    <p className="muted small">Samples never start a call or send a chat message. Server samples use your server’s voice provider; browser samples use your browser’s voices. Your microphone only turns on when you ask.</p>
  </section>;
}
function MicrophoneSettings() {
  const [permission, setPermission] = useState('Not requested'); const [devices, setDevices] = useState<MediaDeviceInfo[]>([]); const [selected, setSelected] = useState(() => localStorage.getItem('lemonbot.microphoneDeviceId') ?? ''); const [error, setError] = useState<unknown>(); const [active, setActive] = useState(false);
  const stream = useRef<MediaStream | null>(null);
  useEffect(() => () => { stream.current?.getTracks().forEach(track => track.stop()); }, []);
  async function inspect() {
    setError(undefined);
    try {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('Microphone capture is unavailable. Use a secure context and supported browser.');
      const capture = await navigator.mediaDevices.getUserMedia({ audio: selected ? { deviceId: { exact: selected } } : true });
      stream.current?.getTracks().forEach(track => track.stop()); stream.current = capture; setActive(true); setPermission('Granted — microphone test active');
      setDevices((await navigator.mediaDevices.enumerateDevices()).filter(device => device.kind === 'audioinput'));
    } catch (failure) { setError(failure); setPermission(failure instanceof DOMException && failure.name === 'NotAllowedError' ? 'Microphone blocked. Allow it in your browser’s site settings, then try again.' : failure instanceof DOMException && failure.name === 'NotFoundError' ? 'No microphone input found' : 'Could not access selected microphone'); }
  }
  return <section className="panel stack"><h2>Microphone — this browser only</h2><p role="status">{permission}</p><ErrorNotice error={error} /><Field label="Input device" hint="This device-local choice is used by voice capture, not sent as a backend preference. Explicit test requests browser permission."><select value={selected} disabled={active} onChange={e => { setSelected(e.target.value); localStorage.setItem('lemonbot.microphoneDeviceId', e.target.value); }}><option value="">System default</option>{selected && !devices.some(device => device.deviceId === selected) && <option value={selected}>Previously selected microphone (not connected yet)</option>}{devices.map(device => <option key={device.deviceId} value={device.deviceId}>{device.label || 'Microphone input'}</option>)}</select></Field><div className="row"><button disabled={active} onClick={() => void inspect()}>Request permission & test input</button><button disabled={!active} onClick={() => { stream.current?.getTracks().forEach(track => track.stop()); stream.current = null; setActive(false); setPermission('Permission granted — microphone stopped'); }}>Stop microphone test</button></div><p className="muted small">The test opens the selected input so the browser shows its microphone indicator. It does not record, upload or transcribe. Stop explicitly or leave this screen to release it.</p></section>;
}
