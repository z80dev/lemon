import { useEffect, useState, type ReactNode } from 'react';
import { LemonBotError, type Bot, type Machine, type Page } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, Field, Loading, RecoveryNotice, useAction, useQuery } from '../../ui';

export async function collect<T extends { id: string }>(load: (cursor?: string) => Promise<Page<T>>): Promise<T[]> {
  const items = new Map<string, T>();
  let cursor: string | undefined;
  do { const page = await load(cursor); page.items.forEach(item => items.set(item.id, item)); cursor = page.nextCursor ?? undefined; } while (cursor);
  return [...items.values()];
}
export interface Intent {
  run: <T>(fn: () => Promise<T>) => Promise<T | undefined>;
  busy: boolean;
  error: unknown;
  uncertain: boolean;
  disabled: boolean;
  markUnknown: () => void;
}
export function useIntent(): Intent {
  const action = useAction();
  const { online } = useApp();
  const [uncertain, setUncertain] = useState(false);
  return { ...action, uncertain, disabled: !online || action.busy || uncertain,
    markUnknown: () => setUncertain(true),
    run: <T,>(fn: () => Promise<T>) => action.run(async () => {
      if (!online || uncertain) throw new Error('Reconnect and check the current status before making another change.');
      try { return await fn(); } catch (error) {
        if (!(error instanceof LemonBotError) || error.outcomeUnknown || !error.retrySafe) setUncertain(true);
        throw error;
      }
    }),
  };
}
export function IntentNotice({ intent, reconcile }: { intent: Intent; reconcile?: () => Promise<unknown> }) {
  const read = useAction();
  return <><ErrorNotice error={read.error}/><RecoveryNotice error={intent.error} uncertain={intent.uncertain} busy={read.busy} onCheck={reconcile ? () => read.run(reconcile) : undefined}/></>;
}
export function Check({ checked, onChange, children, disabled = false }: { checked: boolean; onChange: (value: boolean) => void; children: ReactNode; disabled?: boolean }) {
  return <label className="row"><input type="checkbox" checked={checked} disabled={disabled} onChange={event => onChange(event.target.checked)} />{children}</label>;
}
export function Selection({ title, items, selected, onChange, disabled = false }: { title: string; items: { id: string; name: string; description?: string }[]; selected: string[]; onChange: (ids: string[]) => void; disabled?: boolean }) {
  return <fieldset className="panel stack" disabled={disabled}><legend>{title}</legend>{items.length === 0 && <p className="muted">No accessible items.</p>}{items.map(item => <Check key={item.id} checked={selected.includes(item.id)} onChange={yes => onChange(yes ? [...selected, item.id] : selected.filter(id => id !== item.id))}><span>{item.name}{item.description && <small className="muted"> — {item.description}</small>}</span></Check>)}</fieldset>;
}
export function useMachines() {
  const { client } = useApp();
  return useQuery('bots:machine-picker', () => collect(cursor => client.call('GET /machines', { query: { cursor, limit: 200 } })));
}
export function MachineChoice({ value, onChange, consent, onConsent, exclude }: { value: string; onChange: (id: string) => void; consent: boolean; onConsent: (yes: boolean) => void; exclude?: string }) {
  const { snapshot, navigate } = useApp();
  const machines = useMachines();
  const rows = machines.data ?? snapshot.machines;
  return <fieldset className="panel stack"><legend>Execution machine</legend><ErrorNotice error={machines.error} />{machines.loading && <Loading />}<Field label="Assigned machine"><select required value={value} onChange={event => { onChange(event.target.value); onConsent(false); }}><option value="">Choose an online machine</option>{rows.filter(machine => machine.id !== exclude).map(machine => <option key={machine.id} value={machine.id} disabled={machine.status !== 'online'}>{machine.name} · {machine.status}</option>)}</select></Field><p className="muted">All conversations execute here, even while this app is closed. Bots on this OS account share files, browser sessions and CLI credentials. Personas are not sandboxes. Private OAuth authority is never automatically lent.</p><Check checked={consent} onChange={onConsent}>I trust this host and explicitly accept its shared access.</Check><button type="button" onClick={() => navigate({ screen: 'machine.attach' })}>Connect a computer</button></fieldset>;
}
export function useBot(id: string) {
  const { client } = useApp();
  return useQuery(`bot:${id}`, () => client.call('GET /bots/:id', { params: { id } }));
}
export function canManage(bot: Bot, userId: string) { return bot.ownerUserId === userId; }
export function machineAccess(machine: Machine | undefined, userId: string, admin: boolean) { return !!machine && (machine.ownerUserId === userId || machine.accessUserIds.includes(userId) || admin); }
export function useObjectUrl(blob?: Blob) {
  const [url, setUrl] = useState<string>();
  useEffect(() => { if (!blob) { setUrl(undefined); return; } const next = URL.createObjectURL(blob); setUrl(next); return () => URL.revokeObjectURL(next); }, [blob]);
  return url;
}
export function downloadJson(value: unknown, filename: string) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(value, null, 2)], { type: 'application/json' }));
  const link = document.createElement('a'); link.href = url; link.download = filename; link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
}
