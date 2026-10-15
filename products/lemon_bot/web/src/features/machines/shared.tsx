import { useEffect, useRef, useState } from 'react';
import { LemonBotError } from '@lemon-bot/sdk';
import type { Machine, Page } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { RecoveryNotice, useAction, useQuery } from '../../ui';

export function usePages<T>(key: string, load: (cursor?: string) => Promise<Page<T>>, identity: (item: T) => string) {
  const query = useQuery(key, () => load());
  const more = useAction();
  const loadMore = () => more.run(async () => {
    if (!query.data?.nextCursor) return;
    const page = await load(query.data.nextCursor);
    query.setData(previous => previous ? { items: [...new Map([...previous.items, ...page.items].map(item => [identity(item), item])).values()], nextCursor: page.nextCursor } : page);
  });
  return { ...query, loadMore, moreBusy: more.busy, moreError: more.error };
}

export interface MachineIntent {
  run<T>(intent: () => Promise<T>): Promise<T | undefined>;
  reconcile(load: () => Promise<unknown>): Promise<void>;
  markUncertain(): void;
  busy: boolean;
  error: unknown;
  uncertain: boolean;
  disabled: boolean;
}

// Only GET reconciliation clears the fence. An unknown mutation is never replayed.
export function useIntent(): MachineIntent {
  const { online } = useApp();
  const action = useAction();
  const [uncertain, setUncertain] = useState(false);
  const locked = useRef(false);
  async function run<T>(intent: () => Promise<T>) {
    if (locked.current || uncertain) return;
    locked.current = true;
    try {
      return await action.run(async () => {
        if (!online) throw new Error('You’re offline. Reconnect before changing this computer.');
        try { return await intent(); }
        catch (error) {
          if (!(error instanceof LemonBotError) || error.outcomeUnknown || error.code === 'outcome_unknown') setUncertain(true);
          throw error;
        }
      });
    } finally { locked.current = false; }
  }
  async function reconcile(load: () => Promise<unknown>) {
    await action.run(async () => { await load(); setUncertain(false); });
  }
  return { run, reconcile, markUncertain: () => setUncertain(true), busy: action.busy, error: action.error, uncertain, disabled: !online || action.busy || uncertain };
}

export function IntentNotice({ intent, reconcile }: { intent: MachineIntent; reconcile: () => Promise<unknown> }) {
  return <RecoveryNotice error={intent.error} uncertain={intent.uncertain} busy={intent.busy} onCheck={() => intent.reconcile(reconcile)}/>;
}

export function usePoll(reload: () => Promise<unknown>, enabled = true, milliseconds = 10000) {
  const latest = useRef(reload);
  latest.current = reload;
  useEffect(() => {
    if (!enabled) return;
    let loading = false;
    const timer = window.setInterval(() => {
      if (loading || document.visibilityState !== 'visible') return;
      loading = true;
      void latest.current().catch(() => {}).finally(() => { loading = false; });
    }, milliseconds);
    return () => window.clearInterval(timer);
  }, [enabled, milliseconds]);
}

export function PrivilegeWarning() {
  return <aside className="machine-warning"><strong>Trusted host · full OS-user privileges</strong><p>Bots on this machine share its files, browser sessions and CLI credentials. Product access and Bot-scoped secrets are not OS sandboxes. Use separate machines, users or containers for isolation. Your SSH and host ownership remain yours.</p></aside>;
}

export function MachineTabs({ machine, selected }: { machine: Machine; selected: string }) {
  const { navigate } = useApp();
  return <nav className="tabs" aria-label="Machine sections">{[['detail', 'Overview'], ['files', 'Files'], ['terminal', 'Terminal'], ['secrets', 'Secrets']].map(([tab, title]) => <button key={tab} aria-current={selected === tab ? 'page' : undefined} className={selected === tab ? 'selected' : ''} onClick={() => navigate({ screen: `machine.${tab}`, id: machine.id })}>{title}</button>)}</nav>;
}

export function bytesFromBase64(value: string) {
  const binary = atob(value);
  return Uint8Array.from(binary, character => character.charCodeAt(0));
}
export function base64FromBytes(bytes: Uint8Array) {
  let binary = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  return btoa(binary);
}
export function joinPath(directory: string, name: string) { return `${directory.replace(/\/$/, '')}/${name}`; }
