import { useEffect, useState, type ReactNode } from 'react';
import { LemonBotError, type Bot, type Page, type PageQuery } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { ErrorNotice, Field, Loading, RecoveryNotice, safeExternal, useAction, useQuery } from '../../ui';

export interface WorkAction {
  busy: boolean;
  error: unknown;
  uncertain: boolean;
  blocked: boolean;
  run: <T>(fn: () => Promise<T>) => Promise<T | undefined>;
  read: <T>(fn: () => Promise<T>) => Promise<T | undefined>;
  reconcile: (read: () => Promise<unknown>) => Promise<void>;
}

export function useWorkAction(): WorkAction {
  const action = useAction();
  const [uncertain, setUncertain] = useState(false);
  return { ...action, uncertain, blocked: action.busy || uncertain,
    read: action.run,
    run: <T,>(fn: () => Promise<T>) => action.run(async () => {
      try { return await fn(); } catch (error) {
        if (!(error instanceof LemonBotError) || error.outcomeUnknown) setUncertain(true);
        throw error;
      }
    }),
    reconcile: async (read: () => Promise<unknown>) => {
      await action.run(async () => { await read(); setUncertain(false); });
    },
  };
}

export function useDeadlineClock() {
  const [, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
}

export function ActionNotice({ action, reconcile }: { action: WorkAction; reconcile: () => Promise<unknown> }) {
  return <RecoveryNotice error={action.error} uncertain={action.uncertain} busy={action.busy} onCheck={() => action.reconcile(reconcile)}/>;
}

export function usePages<T>(key: string, load: (query: PageQuery) => Promise<Page<T>>) {
  const [cursor, setCursor] = useState<string>();
  const [previous, setPrevious] = useState<(string | undefined)[]>([]);
  useEffect(() => { setCursor(undefined); setPrevious([]); }, [key]);
  const query = useQuery(`${key}:${cursor ?? 'first'}`, () => load({ limit: 50, ...(cursor ? { cursor } : {}) }));
  return { ...query, controls: <div className="row"><button disabled={!previous.length || query.loading} onClick={() => { setCursor(previous.at(-1)); setPrevious(previous.slice(0, -1)); }}>Previous page</button><button disabled={!query.data?.nextCursor || query.loading} onClick={() => { if (query.data?.nextCursor) { setPrevious([...previous, cursor]); setCursor(query.data.nextCursor); } }}>Next page</button><button disabled={query.loading} onClick={() => void query.reload()}>Refresh</button></div> };
}
export function useInventory<T extends { id: string }>(key: string, load: (query: PageQuery) => Promise<Page<T>>) {
  return useQuery(key, async () => {
    const items: T[] = [];
    const seen = new Set<string>();
    let cursor: string | undefined;
    do {
      const page = await load({ limit: 200, ...(cursor ? { cursor } : {}) });
      for (const item of page.items) if (!seen.has(item.id)) { seen.add(item.id); items.push(item); }
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    return items;
  });
}


export function QueryState({ query, children }: { query: { loading: boolean; error: unknown; data: unknown; reload?: () => Promise<void> }; children: ReactNode }) {
  return <><ErrorNotice error={query.error}/>{query.loading && <Loading/>}{!!query.error && query.reload && <button type="button" disabled={query.loading} onClick={() => void query.reload?.()}>Try again</button>}{query.data !== undefined && <div hidden={!!query.error} aria-busy={query.loading}>{children}</div>}</>;
}

export function canManage(bot: Bot, userId: string) { return bot.ownerUserId === userId; }

export function BotSelect({ value, onChange, label = 'Bot' }: { value: string; onChange: (id: string) => void; label?: string }) {
  const { client, snapshot } = useApp();
  const inventory = useInventory('work-bot-picker', query => client.call('GET /bots', { query }));
  const machines = useInventory('work-machine-labels', query => client.call('GET /machines', { query }));
  const bots = (inventory.data ?? snapshot.bots).filter(bot => bot.ownerUserId === snapshot.user.id);
  return <Field label={label}>
    <select required disabled={inventory.loading || !!inventory.error} value={value} onChange={event => onChange(event.target.value)}>
      <option value="">Choose a Bot</option>{bots.map(bot => <option key={bot.id} value={bot.id}>{bot.name} · {(machines.data ?? snapshot.machines).find(machine => machine.id === bot.machineId)?.name ?? `Machine ${bot.machineId}`}</option>)}
    </select>
    <ErrorNotice error={inventory.error} /><ErrorNotice error={machines.error} />
  </Field>;
}

export function ExternalLink({ url, children }: { url: string | null; children: ReactNode }) {
  const safe = url ? safeExternal(url) : undefined;
  return safe ? <a className="button" href={safe} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">{children}</a> : null;
}

export function splitList(value: string) { return value.split(/[,\n]/).map(item => item.trim()).filter(Boolean); }
export function CopyButton({ value, label }: { value: string; label: string }) {
  const action = useAction();
  const [copied, setCopied] = useState(false);
  useEffect(() => setCopied(false), [value]);
  return <><button type="button" disabled={action.busy} onClick={() => void action.run(async () => { await navigator.clipboard.writeText(value); setCopied(true); })}>{label}</button><span role="status">{copied ? 'Copied' : ''}</span><ErrorNotice error={action.error} /></>;
}
