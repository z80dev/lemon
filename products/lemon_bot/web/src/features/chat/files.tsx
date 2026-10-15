import { useEffect, useRef, useState } from 'react';
import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import type { Attachment } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import type { Route } from '../../app';
import { ErrorNotice, Loading, PageHeader, formatBytes, formatTime, safeExternal, saveBytes, useQuery } from '../../ui';
import { useIntent, IntentNotice } from './common';

export function RichText({ text }: { text: string }) {
  return <Markdown remarkPlugins={[remarkGfm]} components={{ a: ({ href, children }) => {
    const url = href && safeExternal(href);
    return url ? <a href={url} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">{children}</a> : <span>{children}</span>;
  }, img: ({ alt }) => <span className="muted">[External image: {alt || 'image'} — not loaded automatically]</span> }}>{text}</Markdown>;
}

export function AttachmentLink({ id }: { id: string }) {
  const { client, navigate } = useApp();
  const resource = useQuery(`attachment:${id}`, () => client.call('GET /attachments/:id', { params: { id } }));
  const download = useIntent();
  return <div className="chat-file row"><span aria-hidden="true">↗</span><button onClick={() => navigate({ screen: 'file.viewer', id })}>{resource.data?.filename || 'Open attachment'}</button>{resource.data && <span className="muted small">{resource.data.mime} · {formatBytes(resource.data.size)}</span>}<button disabled={download.busy} onClick={() => void download.run(async () => { const ticket = await client.download(id); saveBytes(await client.downloadBytes(ticket), ticket.filename, ticket.mime); })}>Download</button><ErrorNotice error={resource.error || download.error} /></div>;
}

/** RFC 4180 quoted cells, including embedded delimiters/newlines; no formula evaluation. */
function tableRows(text: string): string[][] {
  const delimiter = text.split('\n', 1)[0]?.includes('\t') ? '\t' : ',';
  const rows: string[][] = []; let row: string[] = []; let cell = ''; let quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') { if (quoted && text[i + 1] === '"') { cell += '"'; i++; } else quoted = !quoted; }
    else if (!quoted && char === delimiter) { row.push(cell); cell = ''; }
    else if (!quoted && (char === '\n' || char === '\r')) { if (char === '\r' && text[i + 1] === '\n') i++; row.push(cell); rows.push(row); cell = ''; row = []; }
    else cell += char;
  }
  if (quoted) throw new Error('Table contains an unterminated quoted cell. Download the original to inspect it.');
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows;
}

function isolatedHTML(html: string) {
  return '<!doctype html><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'; font-src data:; base-uri \'none\'; form-action \'none\'"><meta name="referrer" content="no-referrer">' + html;
}

function TextPreview({ attachment, bytes }: { attachment: Attachment; bytes: Uint8Array }) {
  const [doc, setDoc] = useState<string>(); const [error, setError] = useState<unknown>();
  useEffect(() => {
    let active = true;
    if (attachment.preview === 'docx') {
      import('mammoth').then(mammoth => mammoth.convertToHtml({ arrayBuffer: bytes.slice().buffer as ArrayBuffer })).then(result => {
        if (active) setDoc(result.value);
      }).catch(failure => { if (active) setError(failure); });
    }
    return () => { active = false; };
  }, [attachment.id, attachment.preview, bytes]);
  if (error) return <ErrorNotice error={error} />;
  if (attachment.preview === 'docx') return doc !== undefined ? <iframe title={attachment.filename} sandbox="" srcDoc={isolatedHTML(doc)} className="chat-document" /> : <Loading />;
  let text: string;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
  catch { return <p className="error-notice">Text encoding could not be decoded as UTF-8. Download the unchanged original.</p>; }
  if (attachment.preview === 'html') return <iframe title={attachment.filename} sandbox="" srcDoc={isolatedHTML(text)} className="chat-document" />;
  if (attachment.preview === 'markdown') return <div className="chat-markdown"><RichText text={text} /></div>;
  if (attachment.preview === 'json') {
    try { return <pre className="chat-source">{JSON.stringify(JSON.parse(text), null, 2)}</pre>; }
    catch { return <><p className="error-notice">Invalid JSON; showing original text, not repaired data.</p><pre className="chat-source">{text}</pre></>; }
  }
  if (attachment.preview === 'table') {
    try { const rows = tableRows(text); return <><p className="muted small">Read-only values. Spreadsheet formulas are never executed.</p><div className="table-wrap"><table><tbody>{rows.slice(0, 1000).map((row, i) => <tr key={i}>{row.slice(0, 100).map((cell, j) => <td key={j}>{cell}</td>)}</tr>)}</tbody></table></div>{(rows.length > 1000 || rows.some(row => row.length > 100)) && <p>Preview limited to 1,000 rows and 100 columns. Download for the full table.</p>}</>; }
    catch (failure) { return <ErrorNotice error={failure} />; }
  }
  return <pre className="chat-source">{text}</pre>;
}

export function FileViewer({ route }: { route: Route }) {
  const { client, navigate, snapshot } = useApp(); const id = route.id || '';
  const resource = useQuery(`attachment:${id}`, () => client.call('GET /attachments/:id', { params: { id } }));
  const [bytes, setBytes] = useState<Uint8Array>(); const [url, setUrl] = useState<string>(); const [previewError, setPreviewError] = useState<unknown>(); const [loading, setLoading] = useState(false);
  const intent = useIntent(); const generation = useRef(0);
  const attachment = resource.data;
  useEffect(() => {
    const current = ++generation.current; setBytes(undefined); setUrl(undefined); setPreviewError(undefined);
    if (!attachment || attachment.state !== 'ready' || attachment.preview === 'download') return;
    const textLike = ['text', 'markdown', 'html', 'json', 'table', 'docx'].includes(attachment.preview);
    if (textLike && attachment.size > 8 * 1024 * 1024) return;
    setLoading(true); let objectUrl: string | undefined;
    client.download(id).then(ticket => client.downloadBytes(ticket)).then(data => {
      if (generation.current !== current) return;
      setBytes(data); objectUrl = URL.createObjectURL(new Blob([data.slice().buffer as ArrayBuffer], { type: attachment.mime })); setUrl(objectUrl);
    }).catch(error => { if (generation.current === current) setPreviewError(error); }).finally(() => { if (generation.current === current) setLoading(false); });
    return () => { generation.current++; if (objectUrl) URL.revokeObjectURL(objectUrl); };
  }, [id, attachment?.revision, client]);
  return <section className="page chat-viewer"><PageHeader title={attachment?.filename || 'File'} eyebrow="Deliverable"><button onClick={() => attachment?.conversationId && navigate({ screen: 'conversation', id: attachment.conversationId })} disabled={!attachment?.conversationId}>Back to conversation</button></PageHeader><ErrorNotice error={resource.error} />{resource.loading && <Loading />}{attachment && <><div className="panel stack"><div className="row spread"><span>{attachment.mime} · {formatBytes(attachment.size)} · {attachment.state}</span><button className="primary" disabled={intent.busy || attachment.state !== 'ready'} onClick={() => void intent.run(async () => { const ticket = await client.download(id); saveBytes(bytes || await client.downloadBytes(ticket), ticket.filename, ticket.mime); })}>Download original</button></div><ErrorNotice error={intent.error} /><dl className="chat-provenance"><dt>Source</dt><dd>{attachment.source}</dd><dt>Bot</dt><dd>{snapshot.bots.find(bot => bot.id === attachment.provenance.botId)?.name || attachment.provenance.botId || 'Not bot-generated'}</dd><dt>Machine</dt><dd>{snapshot.machines.find(machine => machine.id === attachment.provenance.machineId)?.name || attachment.provenance.machineId || 'Not attributed'}</dd><dt>Run</dt><dd>{attachment.provenance.runId || 'None'}</dd><dt>Generated</dt><dd>{formatTime(attachment.provenance.generatedAtMs)}</dd><dt>Integrity SHA-256</dt><dd className="chat-hash">{attachment.sha256}</dd></dl>{attachment.provenance.sourceEntryId && <button onClick={() => attachment.conversationId && navigate({ screen: 'conversation', id: attachment.conversationId, entryId: attachment.provenance.sourceEntryId || undefined })}>Open source entry</button>}</div>{attachment.state === 'deleted' ? <p className="error-notice">This attachment was deleted. The original is no longer available.</p> : <div className="panel chat-preview">{loading && <Loading />}<ErrorNotice error={previewError} />{url && bytes && <>{attachment.preview === 'image' ? <img src={url} alt={attachment.filename} onError={() => setPreviewError(new Error('Image could not be rendered. Download the original.'))} /> : attachment.preview === 'video' ? <video controls src={url} onError={() => setPreviewError(new Error('Video codec is unavailable in this browser. Download the original.'))} /> : attachment.preview === 'audio' ? <audio controls src={url} onError={() => setPreviewError(new Error('Audio codec is unavailable in this browser. Download the original.'))} /> : attachment.preview === 'pdf' ? <iframe title={attachment.filename} src={url} className="chat-document" /> : <TextPreview attachment={attachment} bytes={bytes} />}</>}{!loading && !bytes && !previewError && <p>{attachment.preview === 'download' ? 'This format has no browser preview. Download the original bytes to open it in an appropriate app.' : 'This file is too large for the text/document preview (8 MiB). The full original is available to download.'}</p>}</div>}</>}</section>;
}

export function VoiceMemo({ attachmentId, transcript, durationMs, peaks }: { attachmentId: string; transcript: string; durationMs: number; peaks: number[] }) {
  const { client } = useApp(); const audio = useRef<HTMLAudioElement>(null); const [url, setUrl] = useState<string>(); const [state, setState] = useState('paused'); const [rate, setRate] = useState(1); const [position, setPosition] = useState(0); const intent = useIntent();
  useEffect(() => () => { if (url) URL.revokeObjectURL(url); }, [url]);
  async function play() { await intent.run(async () => {
    if (!url) { setState('preparing'); const ticket = await client.download(attachmentId); const data = await client.downloadBytes(ticket); const objectUrl = URL.createObjectURL(new Blob([data.slice().buffer as ArrayBuffer], { type: ticket.mime })); setUrl(objectUrl); setState('ready'); }
    else if (audio.current?.paused) await audio.current.play(); else audio.current?.pause();
  }); }
  useEffect(() => { if (url && audio.current) void audio.current.play().catch(() => setState('paused — press Play')); }, [url]);
  return <div className="stack"><div className="row"><button disabled={intent.busy} onClick={() => void play()}>{state === 'playing' ? 'Pause' : state === 'preparing' ? 'Preparing audio…' : 'Play memo'}</button><span className="muted" aria-live="polite">{state} · {(durationMs / 1000).toFixed(0)}s</span><label>Playback speed <select value={rate} onChange={event => { const speed = Number(event.target.value); setRate(speed); if (audio.current) audio.current.playbackRate = speed; }}><option value={1}>1×</option><option value={1.5}>1.5×</option><option value={2}>2×</option></select></label></div><svg viewBox="0 0 400 40" className="chat-waveform" role="img" aria-label="Persisted audio waveform">{peaks.slice(0, 200).map((peak, i, list) => <line key={i} x1={i * 400 / list.length} x2={i * 400 / list.length} y1={20 - Math.min(1, Math.max(0, peak)) * 18} y2={20 + Math.min(1, Math.max(0, peak)) * 18} />)}</svg>{url && <><audio ref={audio} src={url} onPlay={() => { setState('playing'); if (audio.current) audio.current.playbackRate = rate; }} onPause={() => setState('paused')} onEnded={() => setState('paused')} onTimeUpdate={() => setPosition(audio.current?.currentTime || 0)} onError={() => setState('fetch-failed — download original')} /><label>Seek memo <input type="range" min={0} max={durationMs / 1000} step={0.1} value={position} onChange={event => { const value = Number(event.target.value); if (audio.current) audio.current.currentTime = value; setPosition(value); }} /></label></>}<IntentNotice intent={intent} reconcile={async () => { await client.download(attachmentId); setState('paused'); }} /><details><summary>Transcript</summary><RichText text={transcript} /></details><AttachmentLink id={attachmentId} /></div>;
}
