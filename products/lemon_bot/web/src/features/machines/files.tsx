import { useRef, useState } from 'react';
import { LemonBotError, nonce } from '@lemon-bot/sdk';
import type { Attachment, Confirmation, FileChunk, FileInfo, Machine } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ConfirmDialog, EmptyState, ErrorNotice, Field, Loading, formatBytes, formatTime, saveBytes, useAction } from '../../ui';
import { IntentNotice, base64FromBytes, bytesFromBase64, joinPath, useIntent, usePages, usePoll } from './shared';

const CHUNK_BYTES = 256 * 1024;

export function MachineFiles({ machine }: { machine: Machine }) {
  const { client, online, snapshot, navigate, reportError } = useApp()
  const [path, setPath] = useState('.');
  const [pathInput, setPathInput] = useState('.');
  const [hidden, setHidden] = useState(false);
  const [selected, setSelected] = useState<FileInfo>();
  const [chunk, setChunk] = useState<FileChunk>();
  const [folder, setFolder] = useState('');
  const [destination, setDestination] = useState('');
  const [upload, setUpload] = useState<File>();
  const [uploadName, setUploadName] = useState('');
  const [overwrite, setOverwrite] = useState<FileInfo>();
  const [overwriteAccepted, setOverwriteAccepted] = useState(false);
  const [progress, setProgress] = useState<{ path: string; bytes: number; total: number; state: string }>();
  const [confirmation, setConfirmation] = useState<{ preview: Confirmation; path: string }>();
  const [imported, setImported] = useState<Attachment>();
  const [importBot, setImportBot] = useState('');
  const intent = useIntent();
  const read = useAction();
  const listing = usePages(`files:${machine.id}:${path}:${hidden}`, cursor => client.call('GET /machines/:id/files', { params: { id: machine.id }, query: { path, showHidden: hidden, limit: 100, cursor } }), item => item.path);
  usePoll(listing.reload, online && !intent.busy && !confirmation, 15000);
  const available = online && machine.status === 'online';
  const availability = useRef(available);
  availability.current = available;
  function changeDirectory(next: string) { setPath(next); setPathInput(next); setSelected(undefined); setChunk(undefined); setConfirmation(undefined); setOverwrite(undefined); setOverwriteAccepted(false); }
  async function inspect(filePath: string) {
    const stat = await client.call('GET /machines/:id/files/stat', { params: { id: machine.id }, query: { path: filePath } });
    setSelected(stat); setDestination(stat.path); setChunk(undefined);
    if (stat.kind !== 'file' || !stat.readable) return;
    const preview = await client.call('GET /machines/:id/files/read', { params: { id: machine.id }, query: { path: stat.path, offset: 0, length: CHUNK_BYTES } });
    const previewBytes = bytesFromBase64(preview.dataBase64);
    if (preview.path !== stat.path || preview.offset !== 0 || !Number.isSafeInteger(preview.size) || preview.size < previewBytes.length || previewBytes.length > CHUNK_BYTES || preview.eof !== (previewBytes.length === preview.size)) throw new Error('Host returned an inconsistent file chunk.');
    setChunk(preview);
  }
  async function reconcile() {
    await client.call('GET /machines/:id/files', { params: { id: machine.id }, query: { path, showHidden: hidden, limit: 100 } });
    if (progress) {
      const stat = await client.call('GET /machines/:id/files/stat', { params: { id: machine.id }, query: { path: progress.path } });
      setSelected(stat);
      setProgress(value => value ? { ...value, state: `Reconciled stat: ${formatBytes(stat.size)} on host. Inspect bytes before another upload.` } : value);
    } else if (selected) await inspect(selected.path);
    await listing.reload();
  }
  const pieces = path.split('/').filter(Boolean);
  let previewText = '';
  if (chunk) {
    const bytes = bytesFromBase64(chunk.dataBase64);
    previewText = /^(text\/|application\/(json|xml|javascript))/.test(chunk.mime) ? new TextDecoder().decode(bytes) : [...bytes.subarray(0, 256)].map(byte => byte.toString(16).padStart(2, '0')).join(' ');
  }
  return <div className="stack"><IntentNotice intent={intent} reconcile={reconcile} /><ErrorNotice error={read.error} /><section className="panel stack"><div className="row spread"><h2>Destination-local files</h2><button disabled={listing.loading} onClick={() => void listing.reload().catch(reportError)}>Refresh directory</button></div><p className="small muted">Paths are interpreted on {machine.name}, under worker-authorized roots. “.” is the destination default directory; symlink/traversal escapes are rejected by the host. This is privileged host access, not a Bot sandbox.</p><nav className="row machine-breadcrumbs" aria-label="File breadcrumb"><button onClick={() => changeDirectory(path.startsWith('/') ? '/' : '.')}>{path.startsWith('/') ? 'Root' : 'Default'}</button>{pieces.map((piece, index) => piece === '.' ? null : <button key={`${index}:${piece}`} onClick={() => changeDirectory(`${path.startsWith('/') ? '/' : ''}${pieces.slice(0, index + 1).join('/')}`)}>{piece}</button>)}</nav><form className="row" onSubmit={event => { event.preventDefault(); changeDirectory(pathInput); }}><Field label="Host directory"><input required value={pathInput} onChange={event => setPathInput(event.target.value)} /></Field><button>Open directory</button></form><label className="row"><input type="checkbox" checked={hidden} onChange={event => { setHidden(event.target.checked); setSelected(undefined); setChunk(undefined); }} />Show hidden files</label><ErrorNotice error={listing.error} />{listing.loading && !listing.data && <Loading />}{listing.data?.items.length === 0 && <EmptyState title="This directory is empty" />}<div className="table-wrap"><table><thead><tr><th>Name</th><th>Kind</th><th>Size</th><th>Type</th><th>Modified</th><th>Access</th></tr></thead><tbody>{listing.data?.items.map(file => <tr key={file.path}><th scope="row"><button disabled={!available || read.busy} onClick={() => file.kind === 'directory' ? changeDirectory(file.path) : void read.run(() => inspect(file.path))}>{file.name}{file.kind === 'directory' ? '/' : ''}</button>{file.kind === 'directory' && <button aria-label={`Inspect ${file.name}`} disabled={!available || read.busy} onClick={() => void read.run(() => inspect(file.path))}>Info</button>}</th><td>{file.kind}</td><td>{formatBytes(file.size)}</td><td>{file.mime || 'Unknown'}</td><td>{formatTime(file.modifiedAtMs)}</td><td>{file.readable ? 'Read' : 'No read'} · {file.writable ? 'Write' : 'Read-only'}</td></tr>)}</tbody></table></div><ErrorNotice error={listing.moreError} />{listing.data?.nextCursor && <button disabled={listing.moreBusy} onClick={() => void listing.loadMore()}>Load next file page</button>}</section>{selected && <section className="panel stack"><div className="row spread"><h2>{selected.name}</h2><button onClick={() => { setSelected(undefined); setChunk(undefined); }}>Close inspector</button></div><p><code>{selected.path}</code> · {selected.kind} · {formatBytes(selected.size)} · modified {formatTime(selected.modifiedAtMs)}</p>{chunk && <><p className="small muted">{chunk.mime} · offset {chunk.offset} · {formatBytes(chunk.size)}{chunk.eof ? ' · end of file' : ' · truncated preview, more bytes remain'}{! /^(text\/|application\/(json|xml|javascript))/.test(chunk.mime) ? ' · binary hex sample (first 256 bytes of chunk)' : ''}</p><pre className="machine-file-preview" tabIndex={0}>{previewText}</pre>{!chunk.eof && <button disabled={read.busy || !available} onClick={() => void read.run(async () => { const offset = chunk.offset + chunk.size; const next = await client.call('GET /machines/:id/files/read', { params: { id: machine.id }, query: { path: selected.path, offset, length: CHUNK_BYTES } }); if (next.offset !== offset || next.path !== selected.path || bytesFromBase64(next.dataBase64).length !== next.size || (!next.eof && !next.size)) throw new Error('Host returned an inconsistent next file chunk.'); setChunk(next); })}>Read next bounded chunk</button>}</>}<div className="row"><button disabled={read.busy || !available} onClick={() => void read.run(() => inspect(selected.path))}>Refresh stat and preview</button>{selected.kind === 'file' && <button disabled={intent.disabled || !available || !selected.readable} onClick={() => void intent.run(async () => { const attachment = await client.call('POST /machines/:id/files/import', { params: { id: machine.id }, body: { clientNonce: nonce(), path: selected.path, ...(importBot ? { botId: importBot } : {}) } }); setImported(attachment); })}>Import immutable attachment</button>}<button className="danger" disabled={intent.disabled || !available || !selected.writable} onClick={() => void intent.run(async () => { const preview = await client.call('POST /machines/:id/files/preview', { params: { id: machine.id }, body: { clientNonce: nonce(), path: selected.path, action: 'delete' } }); setConfirmation({ preview, path: selected.path }); })}>Preview delete</button></div>{selected.kind === 'file' && <Field label="Attachment attribution (optional)"><select value={importBot} onChange={event => setImportBot(event.target.value)}><option value="">My private attachment</option>{snapshot.bots.filter(bot => bot.machineId === machine.id).map(bot => <option key={bot.id} value={bot.id}>{bot.name}</option>)}</select></Field>}<form className="row" onSubmit={event => { event.preventDefault(); void intent.run(async () => { await client.call('POST /machines/:id/files/move', { params: { id: machine.id }, body: { clientNonce: nonce(), path: selected.path, destination, expectedModifiedAtMs: selected.modifiedAtMs } }); setSelected(undefined); setChunk(undefined); await listing.reload(); }); }}><Field label="Move / rename to exact destination path" hint="Destination must not exist. Source modification time fences this move."><input required value={destination} onChange={event => setDestination(event.target.value)} /></Field><button disabled={intent.disabled || !available || !selected.writable || destination === selected.path}>Move file or directory</button></form></section>}{imported && <section className="panel stack"><h2>Imported attachment</h2><p>{imported.filename} · immutable product copy, not the live host file.</p><div className="row"><button disabled={read.busy} onClick={() => void read.run(async () => { const download = await client.download(imported.id); const bytes = await client.downloadBytes(download); saveBytes(bytes, download.filename, download.mime); })}>Download actual bytes</button><button onClick={() => navigate({ screen: 'file.viewer', id: imported.id })}>Open attachment viewer</button></div></section>}<section className="panel stack"><h2>Upload into this directory</h2><p className="small muted">Chunks are at most {formatBytes(CHUNK_BYTES)}; each acknowledged write fences the next with its returned modification time. A failed or unknown upload stops immediately, never resumes automatically. Partial files may remain.</p><Field label="Local file"><input type="file" disabled={intent.busy} onChange={event => { const file = event.target.files?.[0]; setUpload(file); setUploadName(file?.name || ''); setOverwrite(undefined); setOverwriteAccepted(false); setProgress(undefined); }} /></Field><Field label="Destination filename"><input required value={uploadName} disabled={intent.busy} onChange={event => { setUploadName(event.target.value); setOverwrite(undefined); setOverwriteAccepted(false); }} /></Field><button disabled={!upload || !uploadName || uploadName.includes('/') || !available || read.busy || intent.busy} onClick={() => void read.run(async () => { const target = joinPath(path, uploadName); try { const stat = await client.call('GET /machines/:id/files/stat', { params: { id: machine.id }, query: { path: target } }); if (stat.kind !== 'file') throw new Error('Upload target must be a regular file.'); setOverwrite(stat); setOverwriteAccepted(false); } catch (error) { if (error instanceof LemonBotError && error.code === 'not_found') { setOverwrite(undefined); setOverwriteAccepted(false); } else throw error; } })}>Inspect overwrite target</button>{overwrite && <label className="machine-warning row"><input type="checkbox" checked={overwriteAccepted} onChange={event => setOverwriteAccepted(event.target.checked)} />Replace {overwrite.path} ({formatBytes(overwrite.size)}, modified {formatTime(overwrite.modifiedAtMs)}) using this exact modification fence. Existing contents will be truncated.</label>}<button className="primary" disabled={intent.disabled || !available || !upload || !uploadName || uploadName.includes('/') || (!!overwrite && !overwriteAccepted)} onClick={() => void intent.run(async () => {
    if (!upload) return;
    const target = joinPath(path, uploadName);
    let existing: FileInfo | undefined;
    try { existing = await client.call('GET /machines/:id/files/stat', { params: { id: machine.id }, query: { path: target } }); }
    catch (error) { if (!(error instanceof LemonBotError) || error.code !== 'not_found') throw error; }
    if (existing && (!overwriteAccepted || !overwrite || existing.path !== overwrite.path || existing.modifiedAtMs !== overwrite.modifiedAtMs || existing.kind !== 'file')) { setOverwrite(existing); setOverwriteAccepted(false); throw new Error('An existing or changed file needs explicit overwrite approval. Inspect and approve the new stat.'); }
    let fence = existing?.modifiedAtMs;
    setProgress({ path: target, bytes: 0, total: upload.size, state: 'Writing acknowledged chunks' });
    try {
      for (let offset = 0; offset < upload.size || (offset === 0 && upload.size === 0); offset += CHUNK_BYTES) {
        if (!availability.current) throw new Error('Host disconnected. Remaining chunks were not sent.');
        const bytes = new Uint8Array(await upload.slice(offset, offset + CHUNK_BYTES).arrayBuffer());
        const result = await client.call('PUT /machines/:id/files', { params: { id: machine.id }, body: { clientNonce: nonce(), path: target, dataBase64: base64FromBytes(bytes), offset, truncate: offset === 0, ...(fence !== undefined ? { expectedModifiedAtMs: fence } : {}) } });
        fence = result.modifiedAtMs;
        setProgress({ path: target, bytes: Math.min(offset + bytes.length, upload.size), total: upload.size, state: 'Writing acknowledged chunks' });
      }
    } catch (error) {
      setProgress(previous => previous ? { ...previous, state: 'Stopped; partial or uncertain host data may remain. No automatic resume.' } : previous);
      throw error;
    }
    setProgress({ path: target, bytes: upload.size, total: upload.size, state: 'All chunks acknowledged' }); setOverwrite(undefined); setOverwriteAccepted(false); await listing.reload();
  })}>Upload bounded chunks</button>{progress && <div role="status"><p>{progress.state} · {formatBytes(progress.bytes)} / {formatBytes(progress.total)} · <code>{progress.path}</code></p><progress aria-label="Acknowledged upload bytes" value={progress.bytes} max={progress.total || 1} /></div>}</section><form className="panel stack" onSubmit={event => { event.preventDefault(); void intent.run(async () => { await client.call('POST /machines/:id/files/mkdir', { params: { id: machine.id }, body: { clientNonce: nonce(), path: joinPath(path, folder) } }); setFolder(''); await listing.reload(); }); }}><h2>New folder</h2><Field label="Folder name"><input required value={folder} onChange={event => setFolder(event.target.value)} /></Field><button disabled={intent.disabled || !available || !folder || folder.includes('/')}>Create folder</button></form>{confirmation && <ConfirmDialog title={`Delete ${confirmation.path}`} confirmation={confirmation.preview} onCancel={() => setConfirmation(undefined)} onConfirm={async confirm => { await intent.run(async () => { await client.call('DELETE /machines/:id/files', { params: { id: machine.id }, body: { clientNonce: nonce(), path: confirmation.path, confirmationToken: confirm.confirmationToken, confirmName: confirm.confirmName } }); setConfirmation(undefined); setSelected(undefined); setChunk(undefined); await listing.reload(); }); }} disabled={intent.disabled} />}</div>;
}
