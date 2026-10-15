import { useCallback, useEffect, useId, useRef, useState, type ReactNode, type KeyboardEvent } from 'react';
import { LemonBotError, type Bot, type Confirmation, type Confirm } from '@lemon-bot/sdk';
import { useApp } from './app';
import { errorSummary } from './error-copy';

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
    if (!available) { setError(new Error('You’re offline, so this didn’t send. Reconnect and try again.')); return undefined; }
    lock.current = true; setBusy(true); setError(undefined);
    try { return await fn(); } catch (failure) { if (reconcileOnRefresh && (!(failure instanceof LemonBotError) || failure.outcomeUnknown || !failure.retrySafe)) unresolved.current = true; setError(failure); return undefined; }
    finally { lock.current = false; setBusy(false); }
  };
  return { run, busy, error };
}
export function ErrorNotice({ error, uncertain = false }: { error: unknown; uncertain?: boolean }) {
  const [copied, setCopied] = useState(false);
  if (!error) return null;
  const known = error instanceof LemonBotError;
  const detail = [error instanceof Error ? error.message : 'No usable response was received.', ...(known ? [`Code: ${error.code}`, `Request ID: ${error.requestId || 'Not provided'}`, error.clientNonce ? `Reference: ${error.clientNonce}` : '', error.resourceIds.length ? `Resources: ${error.resourceIds.join(', ')}` : '', error.currentRevision ? `Revision: ${error.currentRevision}` : ''] : [])].filter(Boolean).join('\n');
  return <div className="error-notice" role="alert"><strong>{uncertain || (known && error.outcomeUnknown) ? 'Couldn’t confirm' : 'Couldn’t finish this'}</strong><p>{uncertain ? 'We couldn’t confirm this went through. Your input is kept. Check its current status before trying again so you don’t duplicate it.' : errorSummary(error)}</p><details><summary>Details</summary><pre>{detail}</pre><button onClick={() => void navigator.clipboard.writeText(detail).then(() => setCopied(true)).catch(() => setCopied(false))}>Copy details</button>{copied && <span role="status">Details copied.</span>}</details></div>;
}
/** Consistent read-only recovery copy; callers retain their own mutation fences. */
export function RecoveryNotice({ error, uncertain, busy, onCheck, available = true, reviewed = false, onResume }: { error: unknown; uncertain: boolean; busy: boolean; onCheck?: () => Promise<unknown>; available?: boolean; reviewed?: boolean; onResume?: () => void }) {
  return <><ErrorNotice error={error} uncertain={uncertain}/>{uncertain && !error && <p role="status">We couldn’t confirm this went through. Your input is kept. Check the current status before trying again so you don’t duplicate it.</p>}{(!!error || uncertain) && onCheck && <button disabled={busy || !available} onClick={() => void onCheck()}>{uncertain ? 'Check status' : 'Refresh and check again'}</button>}{uncertain && reviewed && onResume && <><p>Status refreshed. If your change is shown, you’re done. Otherwise, check the affected service or computer before starting a new change.</p><button disabled={busy || !available} onClick={onResume}>I’ve checked — start a new change</button></>}</>;
}
export function Loading({ label = 'Loading…' }: { label?: string }) { return <div className="loading" role="status"><span className="loading-dot"/> {label}</div>; }
export function EmptyState({ title, children, action }: { title: string; children?: ReactNode; action?: ReactNode }) { return <div className="empty-state"><LemonMark size={76}/><h2>{title}</h2>{children && <div className="muted">{children}</div>}{action}</div>; }
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
type ConfirmDialogProps = { title: string; onCancel: () => void; disabled?: boolean } & (
  { confirmation: Confirmation; children?: never; onConfirm: (confirm: Omit<Confirm, 'clientNonce'>) => Promise<void> } |
  { confirmation?: never; children: ReactNode; onConfirm: () => Promise<void> }
);
export function ConfirmDialog(props: ConfirmDialogProps) {
  const { confirmation, title, onCancel, disabled = false } = props;
  const [name, setName] = useState(''); const action = useAction(); const [now, setNow] = useState(Date.now());
  const titleId = useId();
  useEffect(() => { if (!confirmation) return; const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, [confirmation]);
  const expired = !!confirmation && now >= confirmation.expiresAtMs;
  const focus = useRef<HTMLInputElement>(null), cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => { const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null; (focus.current || cancel.current)?.focus(); return () => { if (previous?.isConnected) previous.focus(); }; }, []);
  return <div className="modal-backdrop" onKeyDown={event => { trapDialogFocus(event); if (event.key === 'Escape' && !action.busy) onCancel(); }}><section className="modal stack" role="dialog" aria-modal="true" aria-labelledby={titleId}><h2 id={titleId}>{title}</h2>
    {confirmation ? <><p>Review what will change before confirming. Anything not listed here is kept.</p><ul>{confirmation.effects.map((effect, i) => <li key={i}>{effect}</li>)}</ul><details><summary>Details · affected items</summary><div className="scope-effects">{confirmation.affected.map((effect, i) => <div key={i}><Badge>{effect.operation.replaceAll('_', ' ')}</Badge> <strong>{effect.resourceType} · {effect.id}</strong><p>{effect.explanation}{effect.machineId && ` · Computer ${effect.machineId}`}</p></div>)}</div><p>Revision {confirmation.revision}</p></details><Field label={`Type “${confirmation.confirmName}” to confirm`}><input ref={focus} value={name} autoComplete="off" onChange={event => setName(event.target.value)}/></Field><p className="small muted">{expired ? 'This preview expired. Cancel and review the action again.' : `Expires ${formatTime(confirmation.expiresAtMs)}`}</p></> : props.children}
    <ErrorNotice error={action.error}/><div className="row"><button ref={cancel} onClick={onCancel} disabled={action.busy}>Cancel</button><button className="danger" disabled={disabled || action.busy || expired || (!!confirmation && name !== confirmation.confirmName) || !navigator.onLine} onClick={() => void action.run(async () => { if (props.confirmation) await props.onConfirm({ revision: props.confirmation.revision, confirmationToken: props.confirmation.confirmationToken, confirmName: name }); else await props.onConfirm(); })}>{action.busy ? 'Confirming…' : 'Confirm'}</button></div>
  </section></div>;
}
/** Per-Bot palette shared by every client (design system §1). `avatar` fills the mascot; `tint` is the user bubble, send button and header dot; `onTint` is text on `tint`. */
export interface BotPalette { avatar: string; tint: string; onTint: string }
const botPalettes: Record<string, BotPalette> = {
  yellow: { avatar: '#EDD56C', tint: '#E6CC5A', onTint: '#2E3420' },
  green: { avatar: '#A3CA98', tint: '#4F7D55', onTint: '#FFFFFF' },
  blue: { avatar: '#A0C4EA', tint: '#3F6FA3', onTint: '#FFFFFF' },
  pink: { avatar: '#E3AEC3', tint: '#A2557A', onTint: '#FFFFFF' },
  purple: { avatar: '#BDB2E3', tint: '#6A5CA8', onTint: '#FFFFFF' },
  orange: { avatar: '#EBB487', tint: '#B0643A', onTint: '#FFFFFF' },
  red: { avatar: '#E6A79F', tint: '#A7473F', onTint: '#FFFFFF' },
};
export function botPalette(bot: Pick<Bot, 'avatar'> | undefined): BotPalette { return (bot && botPalettes[bot.avatar.color]) || botPalettes.yellow; }
/** CSS custom properties carrying a Bot's palette, for bubbles, send button and dots. */
export function botStyle(bot: Pick<Bot, 'avatar'> | undefined): Record<string, string> { const palette = botPalette(bot); return { '--bot-avatar': palette.avatar, '--bot-tint': palette.tint, '--bot-on-tint': palette.onTint }; }
/** The mascot body: a soft lemon rotated −24° and fitted to the 100×100 box (design system §4). */
export const lemonBlobPath = 'M0.83 71.82 C1.00 67.93 2.87 60.73 5.22 54.60 C2.70 29.01 11.75 12.25 29.78 4.20 C48.86 -4.32 67.38 0.13 82.74 17.43 C88.88 19.78 95.48 23.19 98.97 26.72 C99.80 31.44 97.87 39.93 96.06 45.83 C99.11 71.17 88.52 87.34 69.44 95.87 C50.35 104.39 31.83 99.94 15.53 80.52 C9.92 77.93 3.79 75.59 0.83 71.82 Z';
const blobMask = `url("data:image/svg+xml,${encodeURIComponent(`<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><path d='${lemonBlobPath}'/></svg>`)}")`;
/** The Lemon mascot: soft lemon blob with a wonky face. Vector at every size; the smile hides below 18px. */
export function LemonFace({ color = botPalettes.yellow.avatar, size = 40, className, face = true }: { color?: string; size?: number; className?: string; face?: boolean }) {
  return <svg className={`lemon-face ${className || ''}`} width={size} height={size} viewBox="0 0 100 100" aria-hidden="true" focusable="false">
    <defs><radialGradient id="lemon-hl" cx="30%" cy="22%" r="55%"><stop offset="0" stopColor="#fff" stopOpacity=".32"/><stop offset="1" stopColor="#fff" stopOpacity="0"/></radialGradient></defs>
    <path d={lemonBlobPath} fill={color}/>
    <path d={lemonBlobPath} fill="url(#lemon-hl)"/>
    <path d={lemonBlobPath} fill="none" stroke="#000" strokeOpacity=".06" strokeWidth={Math.max(1.2, 50 / size)}/>
    {face && <>
      <ellipse cx="47" cy="42" rx="4.2" ry="7" transform="rotate(10.3 47 42)" fill="#27301F" fillOpacity=".88"/>
      <ellipse cx="63" cy="38.5" rx="4.8" ry="8.2" transform="rotate(6.9 63 38.5)" fill="#27301F" fillOpacity=".88"/>
      {size >= 18 && <path d="M49 58.5 Q58.5 66 66.5 55.5" fill="none" stroke="#27301F" strokeOpacity=".88" strokeWidth="4.5" strokeLinecap="round"/>}
    </>}
  </svg>;
}
/** Brand mark: the mascot in lemon plus a leaf at the top-right. */
export function LemonMark({ size = 30 }: { size?: number }) {
  return <span className="brand-mark" style={{ width: size, height: size }} aria-hidden="true"><LemonFace color="#E9D474" size={size}/><svg className="brand-leaf" viewBox="0 0 100 100" width={size} height={size}><ellipse cx="80" cy="14" rx="15" ry="9" transform="rotate(-28 80 14)" fill="#6E9A5B"/></svg></span>;
}
const presenceLabels: Record<string, string> = { idle: 'Idle', working: 'Working', making: 'Working', needs_input: 'Needs you', offline: 'Offline' };
export function presenceLabel(status: Bot['activity']): string { return presenceLabels[status] || status.replaceAll('_', ' '); }
/** Bot avatar with optional presence (bottom-right, hidden for idle) and unread (top-right) badges. */
export function BotAvatar({ bot, size = 40, presence = false, unread = false }: { bot: Bot; size?: number; presence?: boolean; unread?: boolean }) {
  const palette = botPalette(bot);
  const dot = Math.max(8, size * 0.24), unreadDot = Math.max(9, size * 0.2), ring = Math.max(2, size * 0.05);
  const body = bot.avatar.kind === 'image' && bot.avatar.attachmentId
    ? <span className="avatar-image" style={{ width: size, height: size, background: palette.avatar, WebkitMaskImage: blobMask, maskImage: blobMask }}><AvatarImage attachmentId={bot.avatar.attachmentId} name={bot.name}/></span>
    : <LemonFace color={palette.avatar} size={size}/>;
  return <span className="avatar" role="img" style={{ width: size, height: size }} aria-label={`${bot.name}${presence && bot.activity !== 'idle' ? `, ${presenceLabel(bot.activity)}` : ''}${unread ? ', unread' : ''}`}>
    {body}
    {presence && bot.activity !== 'idle' && <span className={`presence-badge ${bot.activity}`} style={{ width: dot, height: dot, borderWidth: ring }}/>}
    {unread && <span className="unread-badge" style={{ width: unreadDot, height: unreadDot, borderWidth: ring }}/>}
  </span>;
}
/** Account avatar: lemon circle with 1–2 initials. */
export function AccountAvatar({ name, size = 34 }: { name: string; size?: number }) {
  const initials = name.split(/\s+/).filter(Boolean).slice(0, 2).map(part => part[0]).join('').toUpperCase() || '?';
  return <span className="account-avatar" style={{ width: size, height: size, fontSize: size * 0.4 }} aria-hidden="true">{initials}</span>;
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
