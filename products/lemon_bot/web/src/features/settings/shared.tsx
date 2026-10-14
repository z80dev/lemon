import { useRef, useState, type ReactNode } from 'react';
import { LemonBotError, type Page, type Cursor } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice } from '../../ui';

export async function allPages<T extends { id: string }>(load: (cursor?: Cursor) => Promise<Page<T>>): Promise<T[]> {
  const items = new Map<string, T>();
  let cursor: Cursor | undefined;
  do {
    const page = await load(cursor);
    for (const item of page.items) items.set(item.id, item);
    cursor = page.nextCursor ?? undefined;
  } while (cursor);
  return [...items.values()];
}

// A failed transport can have committed. Only an explicit authoritative read unlocks a new intent.
export function useIntent(reconcile: () => Promise<void>) {
  const { online } = useApp();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [unknown, setUnknown] = useState(false);
  const inFlight = useRef(false);
  async function run<T>(operation: () => Promise<T>): Promise<T | undefined> {
    if (inFlight.current || unknown || !online) return undefined;
    inFlight.current = true; setBusy(true); setError(undefined);
    try { return await operation(); }
    catch (failure) {
      setError(failure);
      setUnknown(!(failure instanceof LemonBotError) || failure.outcomeUnknown || !failure.retrySafe);
      return undefined;
    } finally { inFlight.current = false; setBusy(false); }
  }
  async function reload() {
    if (inFlight.current || !online) return;
    inFlight.current = true; setBusy(true);
    try { await reconcile(); setUnknown(false); setError(undefined); }
    catch (failure) { setError(failure); }
    finally { inFlight.current = false; setBusy(false); }
  }
  return { run, reload, busy, error, unknown, disabled: busy || unknown || !online };
}
export interface Intent {
  run: <T>(operation: () => Promise<T>) => Promise<T | undefined>;
  reload: () => Promise<void>;
  busy: boolean;
  error: unknown;
  unknown: boolean;
  disabled: boolean;
}
export function IntentNotice({ intent }: { intent: Intent }) {
  const { online } = useApp();
  return <>{!online && <p role="status" className="error-notice">Offline. Changes are not queued. Reconnect before saving.</p>}<ErrorNotice error={intent.error} />{intent.unknown && <p role="alert">The outcome is not confirmed. Your input is retained. Read current server state before making another change; do not repeat an external action without checking its actual outcome.</p>}{intent.error != null && <button type="button" disabled={intent.busy || !online} onClick={() => void intent.reload()}>Reconcile with server</button>}</>;
}
export function Toggle({ label, checked, onChange, disabled = false, hint }: { label: string; checked: boolean; onChange: (value: boolean) => void; disabled?: boolean; hint?: string }) {
  return <label className="settings-toggle"><span><strong>{label}</strong>{hint && <span className="muted small">{hint}</span>}</span><input type="checkbox" checked={checked} onChange={e => onChange(e.target.checked)} disabled={disabled} /></label>;
}
export function NarrowConfirm({ title, children, busy, onConfirm, onCancel }: { title: string; children: ReactNode; busy: boolean; onConfirm: () => void; onCancel: () => void }) {
  return <section className="panel stack settings-confirm" role="dialog" aria-modal="false" aria-label={title}><h3>{title}</h3><div>{children}</div><div className="row"><button type="button" className="danger" disabled={busy} onClick={onConfirm}>Confirm</button><button type="button" disabled={busy} onClick={onCancel}>Cancel</button></div></section>;
}
export function money(value: number | null) { return value === null ? 'Unknown price' : new Intl.NumberFormat(undefined, { style: 'currency', currency: 'USD', maximumFractionDigits: 6 }).format(value); }
