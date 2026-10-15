import { useEffect, useRef, useState } from 'react';
import { LemonBotError } from '@lemon-bot/sdk';
import type { TranscriptEntry } from '@lemon-bot/sdk';
import { RecoveryNotice } from '../../ui';

export function mergeEntries(current: TranscriptEntry[], incoming: TranscriptEntry[]): TranscriptEntry[] {
  const entries = new Map(current.map(entry => [entry.id, entry]));
  for (const entry of incoming) {
    const old = entries.get(entry.id);
    if (!old || old.revision < entry.revision || (old.revision === entry.revision && !(old.kind === 'message' && entry.kind === 'message' && old.streaming && entry.streaming && old.text.length > entry.text.length))) entries.set(entry.id, entry);
  }
  return [...entries.values()].sort((a, b) => a.seq - b.seq || a.id.localeCompare(b.id));
}

export function unknownOutcome(error: unknown): boolean {
  return error instanceof LemonBotError ? error.outcomeUnknown || error.code === 'outcome_unknown' || (!error.retrySafe && error.status >= 500) : true;
}

export interface ChatIntent {
  run<T>(operation: () => Promise<T>): Promise<T | undefined>;
  reconcile(read: () => Promise<void>): Promise<void>;
  busy: boolean;
  error: unknown;
  uncertain: boolean;
  lastError: { current: unknown };
}

/** A user intent is never replayed. Read reconciliation is a separate explicit action. */
export function useIntent(): ChatIntent {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<unknown>();
  const [uncertain, setUncertain] = useState(false);
  const lock = useRef(false);
  const lastError = useRef<unknown>(undefined);
  async function run<T>(operation: () => Promise<T>): Promise<T | undefined> {
    if (lock.current || uncertain) return undefined;
    lock.current = true; setBusy(true); setError(undefined); lastError.current = undefined;
    try { return await operation(); }
    catch (failure) { lastError.current = failure; setError(failure); setUncertain(unknownOutcome(failure)); return undefined; }
    finally { lock.current = false; setBusy(false); }
  }
  async function reconcile(read: () => Promise<void>) {
    if (lock.current) return;
    lock.current = true; setBusy(true);
    try { await read(); lastError.current = undefined; setError(undefined); setUncertain(false); }
    catch (failure) { setError(failure); }
    finally { lock.current = false; setBusy(false); }
  }
  return { run, reconcile, busy, error, uncertain, lastError };
}

export function IntentNotice({ intent, reconcile }: { intent: ChatIntent; reconcile: () => Promise<void> }) {
  return <RecoveryNotice error={intent.error} uncertain={intent.uncertain} busy={intent.busy} onCheck={() => intent.reconcile(reconcile)}/>;
}

export function useClock(interval = 1000) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => { const timer = window.setInterval(() => setNow(Date.now()), interval); return () => clearInterval(timer); }, [interval]);
  return now;
}

export async function copyText(value: string) { await navigator.clipboard.writeText(value); }
