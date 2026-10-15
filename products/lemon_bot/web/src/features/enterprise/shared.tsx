import { useState, type ReactNode } from 'react';
import { LemonBotError, type Page, type PageQuery, type Machine } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ConfirmDialog, ErrorNotice, Loading, RecoveryNotice, useQuery } from '../../ui';

export const words = (value: string) => value.split(/[\n,]/).map(item => item.trim()).filter(Boolean);
export const label = (value: string) => value.replaceAll('_', ' ');

type CollectionItem = { id: string } | { machineId: string } | { limit: { id: string } };

export async function collect<T extends CollectionItem>(load: (query: PageQuery) => Promise<Page<T>>): Promise<T[]> {
  const items = new Map<string, T>();
  let cursor: string | undefined;
  do {
    const page = await load({ limit: 200, ...(cursor ? { cursor } : {}) });
    for (const item of page.items) {
      const key = 'id' in item ? item.id : 'limit' in item ? item.limit.id : item.machineId;
      items.set(key, item);
    }
    cursor = page.nextCursor ?? undefined;
  } while (cursor);
  return [...items.values()];
}

export function useCollection<T extends CollectionItem>(key: string, load: (query: PageQuery) => Promise<Page<T>>) {
  return useQuery(key, () => collect(load));
}

export function QueryNotice({ query }: { query: { error: unknown; loading: boolean; reload: () => Promise<void> } }) {
  const { reportError } = useApp();
  return <><ErrorNotice error={query.error} />{query.loading && <Loading />}{!!query.error && <button type="button" onClick={() => void query.reload().catch(reportError)}>Reload from server</button>}</>;
}

export class IntentInputError extends Error {}

// A transport-uncertain mutation is fenced until an explicit read and human review.
// Reconciliation is never a repeat of the mutation, and never announces success.
export function useIntent() {
  const { online } = useApp();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [uncertain, setUncertain] = useState(false);
  const [reviewed, setReviewed] = useState(false);
  async function perform<T>(intent: () => Promise<T>): Promise<T | undefined> {
    if (busy || uncertain) return undefined;
    if (!online) { setError(new Error('You’re offline. Reconnect before changing these settings.')); return undefined; }
    setBusy(true); setError(undefined); setReviewed(false);
    try { return await intent(); }
    catch (cause) {
      setError(cause);
      if (!(cause instanceof IntentInputError) && (!(cause instanceof LemonBotError) || cause.outcomeUnknown)) setUncertain(true);
      return undefined;
    } finally { setBusy(false); }
  }
  async function reconcile(read: () => Promise<void>) {
    setBusy(true);
    try { await read(); setReviewed(true); }
    catch (cause) { setError(cause); }
    finally { setBusy(false); }
  }
  return { busy, error, uncertain, reviewed, disabled: busy || uncertain || !online, perform, reconcile, resume: () => { setUncertain(false); setError(undefined); setReviewed(false); } };
}
export interface Intent {
  busy: boolean;
  error: unknown;
  uncertain: boolean;
  reviewed: boolean;
  disabled: boolean;
  perform: <T>(intent: () => Promise<T>) => Promise<T | undefined>;
  reconcile: (read: () => Promise<void>) => Promise<void>;
  resume: () => void;
}

export function IntentNotice({ intent, reconcile }: { intent: Intent; reconcile: () => Promise<void> }) {
  return <RecoveryNotice error={intent.error} uncertain={intent.uncertain} busy={intent.busy} onCheck={() => intent.reconcile(reconcile)} reviewed={intent.reviewed} onResume={intent.resume}/>;
}

export function Checks({ legend, options, value, onChange, disabled = false, hint }: { legend: string; options: { id: string; name: string; detail?: string }[]; value: string[]; onChange: (value: string[]) => void; disabled?: boolean; hint?: string }) {
  return <fieldset className="enterprise-choices" disabled={disabled}><legend>{legend}</legend>{hint && <p className="muted small">{hint}</p>}{options.length === 0 && <p className="muted">No available options.</p>}{options.map(option => <label key={option.id} className="row"><input type="checkbox" checked={value.includes(option.id)} onChange={event => onChange(event.target.checked ? [...value, option.id] : value.filter(id => id !== option.id))} /><span>{option.name}{option.detail && <small className="muted"> · {option.detail}</small>}</span></label>)}</fieldset>;
}

export function Toggle({ children, checked, onChange, disabled }: { children: ReactNode; checked: boolean; onChange: (checked: boolean) => void; disabled?: boolean }) {
  return <label className="row"><input type="checkbox" checked={checked} onChange={event => onChange(event.target.checked)} disabled={disabled} /><span>{children}</span></label>;
}

export function AccessNotice({ owner = false }: { owner?: boolean }) {
  return <aside className="panel"><p>{owner ? 'Only the workspace owner can manage identity providers.' : 'Workspace ownership is required to edit these controls.'} Your own identity links, effective permissions and spend limits remain separately scoped. Server ACLs are authoritative.</p></aside>;
}

export function machineOptions(machines: Machine[]) {
  return machines.filter(machine => machine.status !== 'revoked').map(machine => ({ id: machine.id, name: machine.name, detail: machine.status }));
}

export function DeleteButton({ name, disabled, error, onDelete }: { name: string; disabled: boolean; error: unknown; onDelete: () => Promise<boolean> }) {
  const [confirming, setConfirming] = useState(false);
  return <><button type="button" className="danger" aria-label={`Delete ${name}`} disabled={disabled} onClick={() => setConfirming(true)}>Delete</button>{confirming && <ConfirmDialog title={`Delete ${name}?`} disabled={disabled} onCancel={() => setConfirming(false)} onConfirm={async () => { if (await onDelete()) setConfirming(false); }}><p>Your computers and provider accounts are not changed. Only this configuration is deleted.</p><ErrorNotice error={error}/></ConfirmDialog>}</>;
}
