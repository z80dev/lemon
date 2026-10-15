import { useCallback, useEffect, useRef, useState, type ReactNode, type KeyboardEvent } from 'react';
import { LemonBotError, type Bot, type Confirmation, type Confirm } from '@lemon-bot/sdk';
import { useApp } from './app';

export function useQuery<T>(key: string, load: () => Promise<T>) {
  const loader = useRef(load); loader.current = load;
  const [data, setData] = useState<T>();
  const [error, setError] = useState<unknown>();
  const [loading, setLoading] = useState(true);
  const generation = useRef(0);
  const reload = useCallback(async () => {
    const current = ++generation.current;
    setLoading(true);
    try { const result = await loader.current(); if (generation.current === current) { setData(result); setError(undefined); } }
    catch (failure) { if (generation.current === current) setError(failure); throw failure; }
    finally { if (generation.current === current) setLoading(false); }
  }, [key]);
  useEffect(() => { setData(undefined); void reload().catch(() => undefined); return () => { generation.current++; }; }, [reload]);
  useEffect(() => {
    let timer: number | undefined;
    const refresh = (event: Event) => { if (event instanceof CustomEvent && event.detail?.event === 'entry.delta') return; if (!timer) timer = window.setTimeout(() => { timer = undefined; void reload().catch(() => undefined); }, 180); };
    window.addEventListener('lemon:refresh', refresh);
    window.addEventListener('lemon:event', refresh);
    return () => { window.removeEventListener('lemon:refresh', refresh); window.removeEventListener('lemon:event', refresh); clearTimeout(timer); };
  }, [reload]);
  return { data, setData, error, loading, reload };
}
export function useAction({ reconcileOnRefresh = false, available = true }: { reconcileOnRefresh?: boolean; available?: boolean } = {}) {
  const [busy, setBusy] = useState(false); const [error, setError] = useState<unknown>();
  const lock = useRef(false);
  const unresolved = useRef(false);
  useEffect(() => {
    if (!reconcileOnRefresh) return;
    const reconcile = () => { unresolved.current = false; setError(undefined); };
    window.addEventListener('lemon:refresh', reconcile); return () => window.removeEventListener('lemon:refresh', reconcile);
  }, [reconcileOnRefresh]);
  const run = async <T,>(fn: () => Promise<T>): Promise<T | undefined> => {
    if (lock.current || unresolved.current) return undefined;
    if (!available) { setError(new Error('Offline: this action was not queued. Reconnect first.')); return undefined; }
    lock.current = true; setBusy(true); setError(undefined);
    try { return await fn(); } catch (failure) { if (reconcileOnRefresh && (!(failure instanceof LemonBotError) || failure.outcomeUnknown || !failure.retrySafe)) unresolved.current = true; setError(failure); return undefined; }
    finally { lock.current = false; setBusy(false); }
  };
  return { run, busy, error };
}
export function ErrorNotice({ error }: { error: unknown }) {
  if (!error) return null;
  const known = error instanceof LemonBotError;
  return <div className="error-notice" role="alert"><strong>{known && error.outcomeUnknown ? 'Outcome not confirmed' : 'Could not complete this request'}</strong><p>{error instanceof Error ? error.message : 'The service did not return a usable result.'}</p>{known && <><p className="small">{error.code.replaceAll('_', ' ')} · {error.requestId || 'No server request ID'}</p>{error.requestId && <button onClick={() => void navigator.clipboard.writeText(error.requestId)}>Copy request ID</button>}{error.outcomeUnknown && <><p>Work may already have started. Keep this intent and check its resource or run before sending again. Nothing is automatically replayed.</p>{error.clientNonce && <p className="small">Intent nonce: <code>{error.clientNonce}</code></p>}{error.resourceIds.length > 0 && <p className="small">Reserved resources: {error.resourceIds.join(', ')}</p>}</>}{error.code === 'revision_conflict' && <p>The resource changed on another device. Reload before editing.{error.currentRevision && ` Current server revision: ${error.currentRevision}.`}</p>}</>}</div>;
}
export function Loading() { return <div className="loading" role="status"><span className="loading-dot"/> Connecting to your workspace…</div>; }
export function EmptyState({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) { return <div className="empty-state"><span className="empty-mark" aria-hidden="true">◒</span><h2>{title}</h2>{children && <div className="muted">{children}</div>}{action}</div>; }
export function PageHeader({ title, eyebrow, children }: { title: string; eyebrow?: string; children?: ReactNode }) { return <header className="page-header"><div>{eyebrow && <div className="eyebrow">{eyebrow}</div>}<h1>{title}</h1></div><div className="row">{children}</div></header>; }
export function Badge({ children, tone = 'muted' }: { children: ReactNode; tone?: 'good' | 'warning' | 'danger' | 'muted' }) { return <span className={`badge ${tone}`}>{children}</span>; }
export function Field({ label, children, hint }: { label: string; children: ReactNode; hint?: string }) { return <label className="field"><span>{label}</span>{children}{hint && <small>{hint}</small>}</label>; }
export function trapDialogFocus(event: KeyboardEvent<HTMLElement>) {
  if (event.key !== 'Tab') return;
  const controls = [...event.currentTarget.querySelectorAll<HTMLElement>('button:not([disabled]),input:not([disabled]),textarea:not([disabled]),select:not([disabled]),a[href],[tabindex]:not([tabindex="-1"])')].filter(element => element.getClientRects().length > 0);
  const first = controls[0], last = controls.at(-1);
  if (!first || !last) { event.preventDefault(); return; }
  if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
  else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
}
export function ConfirmDialog({ confirmation, title, onConfirm, onCancel, disabled = false }: { confirmation: Confirmation; title: string; onConfirm: (confirm: Omit<Confirm, 'clientNonce'>) => Promise<void>; onCancel: () => void; disabled?: boolean }) {
  const [name, setName] = useState(''); const action = useAction(); const [now, setNow] = useState(Date.now());
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  const expired = now >= confirmation.expiresAtMs;
  const focus = useRef<HTMLInputElement>(null); useEffect(() => { const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null; focus.current?.focus(); return () => { if (previous?.isConnected) previous.focus(); }; }, []);
  return <div className="modal-backdrop" onKeyDown={event => { trapDialogFocus(event); if (event.key === 'Escape' && !action.busy) onCancel(); }}><section className="modal stack" role="dialog" aria-modal="true" aria-labelledby="confirm-title"><h2 id="confirm-title">{title}</h2><p>This preview is bound to the exact resources and revision below. Host files, independent memory, provider sessions and backups are retained only as disclosed here.</p><ul>{confirmation.effects.map((effect, i) => <li key={i}>{effect}</li>)}</ul><div className="scope-effects">{confirmation.affected.map((effect, i) => <div key={i}><Badge>{effect.operation}</Badge> <strong>{effect.resourceType} · {effect.id}</strong><p>{effect.explanation}{effect.machineId && ` · Machine ${effect.machineId}`}</p></div>)}</div><Field label={`Type “${confirmation.confirmName}” to confirm`}><input ref={focus} value={name} autoComplete="off" onChange={event => setName(event.target.value)} /></Field><p className="small muted">{expired ? 'Preview expired. Cancel and request a new preview.' : `Expires ${formatTime(confirmation.expiresAtMs)} · revision ${confirmation.revision}`}</p><ErrorNotice error={action.error}/><div className="row"><button onClick={onCancel} disabled={action.busy}>Cancel</button><button className="danger" disabled={disabled || action.busy || expired || name !== confirmation.confirmName || !navigator.onLine} onClick={() => void action.run(() => onConfirm({ revision: confirmation.revision, confirmationToken: confirmation.confirmationToken, confirmName: name }))}>{action.busy ? 'Confirming…' : 'Confirm exact scope'}</button></div></section></div>;
}
export function BotAvatar({ bot, size = 40 }: { bot: Bot; size?: number }) {
  const colors: Record<string, string> = { yellow: '#e6cc64', green: '#a9c8a0', blue: '#a9c7e4', pink: '#dbb3c2', purple: '#c1b8dc', orange: '#e4b68e' };
  return <span className="avatar" style={{ width: size, height: size, background: colors[bot.avatar.color] || '#e6cc64', borderRadius: bot.avatar.shape === 'square' ? '28%' : '50%' }} aria-label={`${bot.name} avatar`}>{bot.avatar.kind === 'image' && bot.avatar.attachmentId ? <AvatarImage attachmentId={bot.avatar.attachmentId} name={bot.name}/> : <span aria-hidden="true" className="avatar-face">··<i/></span>}</span>;
}
function AvatarImage({ attachmentId, name }: { attachmentId: string; name: string }) {
  const { client } = useApp();
  const [url, setUrl] = useState<string>(); const [failed, setFailed] = useState(false);
  useEffect(() => {
    let disposed = false; let timer: number | undefined;
    const load = async () => { try { const download = await client.download(attachmentId); if (!disposed) { setUrl(download.url); setFailed(false); timer = window.setTimeout(() => void load(), Math.max(1000, download.expiresAtMs - Date.now() - 10000)); } } catch { if (!disposed) setFailed(true); } };
    void load(); return () => { disposed = true; clearTimeout(timer); };
  }, [attachmentId, client]);
  return url && !failed ? <img src={url} alt="" referrerPolicy="no-referrer" onError={() => setFailed(true)}/> : <span title={failed ? 'Avatar unavailable' : 'Loading avatar'}>{name.slice(0, 1)}</span>;
}
export function formatTime(ms: number | null): string { return ms === null ? 'Not yet' : new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(ms)); }
export function formatBytes(n: number): string { if (n < 1024) return `${n} B`; const units = ['KB', 'MB', 'GB', 'TB']; let value = n / 1024, index = 0; while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; } return `${value.toFixed(value < 10 ? 1 : 0)} ${units[index]}`; }
export function safeExternal(url: string): string | undefined { try { const parsed = new URL(url); return ['https:', 'http:'].includes(parsed.protocol) && !parsed.username && !parsed.password ? parsed.href : undefined; } catch { return undefined; } }
export function saveBytes(bytes: Uint8Array, filename: string, mime = 'application/octet-stream') { const blob = new Blob([new Uint8Array(bytes)], { type: mime }); const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url; anchor.download = filename; anchor.rel = 'noopener'; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
