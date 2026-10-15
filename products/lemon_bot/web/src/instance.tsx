import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { LemonBotClient, LemonBotError, type InstanceRuntime, type InstanceStatus, type RuntimeAction, type RuntimeOperation } from '@lemon-bot/sdk';
import { Badge, formatTime, trapDialogFocus } from './ui';

/** Shared by connection recovery and the instance settings pane. Polling never sends commands. */
export function useInstance(client: LemonBotClient, enabled: boolean, onStatus?: (status: InstanceStatus) => void) {
  const [status, setStatus] = useState<InstanceStatus>();
  const [error, setError] = useState<unknown>();
  const [refreshing, setRefreshing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [uncertain, setUncertain] = useState(false);
  const reading = useRef(false), mutating = useRef(false), mounted = useRef(true);
  const notify = useRef(onStatus); notify.current = onStatus;
  const running = status?.runtime.operation?.state === 'running';
  const observing = enabled || running;
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  const refresh = useCallback(async () => {
    if (!observing || reading.current) return;
    reading.current = true; setRefreshing(true);
    try {
      const value = await client.instance();
      if (mounted.current) { setStatus(value); setError(undefined); notify.current?.(value); }
      return value;
    } catch (failure) { if (mounted.current) setError(failure); }
    finally { reading.current = false; if (mounted.current) setRefreshing(false); }
  }, [client, observing]);
  useEffect(() => {
    if (!observing) return;
    let disposed = false, timer: number | undefined;
    const poll = async () => {
      if (document.visibilityState === 'visible') await refresh();
      if (!disposed) timer = window.setTimeout(() => void poll(), running ? 2000 : 10000);
    };
    const visible = () => { if (document.visibilityState === 'visible') void refresh(); };
    void poll(); document.addEventListener('visibilitychange', visible);
    return () => { disposed = true; clearTimeout(timer); document.removeEventListener('visibilitychange', visible); };
  }, [observing, refresh, running]);
  const mutate = async (action?: RuntimeAction) => {
    if (mutating.current || uncertain || running || !navigator.onLine) return;
    mutating.current = true; setBusy(true); setError(undefined);
    try {
      if (action) {
        const operation = await client.runtimeAction(action, action !== 'start');
        if (mounted.current) setStatus(current => current ? { ...current, runtime: { ...current.runtime, operation } } : current);
      } else {
        const value = await client.reconnectController();
        if (mounted.current) { setStatus(value); notify.current?.(value); }
      }
      return true;
    } catch (failure) {
      if (mounted.current) {
        setError(failure);
        if (!(failure instanceof LemonBotError) || failure.outcomeUnknown || !failure.retrySafe) setUncertain(true);
      }
      return false;
    } finally { mutating.current = false; if (mounted.current) setBusy(false); }
  };
  return { status, error, refreshing, refresh, mutate, busy: busy || running || uncertain, uncertain };
}

export function InstanceError({ error, uncertain = false }: { error: unknown; uncertain?: boolean }) {
  const [copyError, setCopyError] = useState(false);
  if (!error && !uncertain) return null;
  const detail = error instanceof Error ? error.message : 'No response was received.';
  return <div className="stack small"><p role="alert">{uncertain ? 'The command may have started. Check the current instance details before doing anything else. It will not be sent again automatically.' : 'Instance details or the action couldn’t finish. Any details shown are from the last successful check.'}</p><details><summary>Details</summary><pre>{detail}</pre><button onClick={() => void navigator.clipboard.writeText(detail).catch(() => setCopyError(true))}>Copy details</button>{copyError && <p role="status">Couldn’t copy. Select the details and copy them manually.</p>}</details></div>;
}

export function RuntimeActions({ runtime, owner, available, busy, onAction, recovery = false }: { runtime: InstanceRuntime; owner: boolean; available: boolean; busy: boolean; onAction: (action: RuntimeAction) => void; recovery?: boolean }) {
  const actions = (['start', 'restart', 'stop'] as const).filter(action => runtime.actions.includes(action) && (!recovery || action !== 'stop'));
  const labels = { start: 'Start', restart: 'Restart', stop: 'Stop' };
  return <>
    {owner && actions.length > 0 && <div className="row">{actions.map(action => <button key={action} className={action === 'stop' ? 'danger' : undefined} disabled={!available || busy} onClick={() => onAction(action)}>{labels[action]}{recovery ? ' Lemon' : ''}</button>)}</div>}
    {!owner && actions.length > 0 && <p className="small muted">Only workspace owners can {recovery ? 'start or restart' : 'start, stop or restart'} Lemon.</p>}
    <RuntimeControlCopy runtime={runtime}/>
  </>;
}

export function RuntimeControlCopy({ runtime }: { runtime: InstanceRuntime }) {
  return <div className="small muted">
    {runtime.via === 'launcher' && <p>Runs the Lemon launcher on the service host to start, stop or restart Lemon.</p>}
    {runtime.via === 'controller' && <p>Restarts or stops Lemon remotely. Start isn’t available while Lemon is down.</p>}
    {runtime.reason && <p>{runtime.reason}</p>}
    {!runtime.via && !runtime.reason && <p>This service cannot control Lemon on this host.</p>}
  </div>;
}

export function RuntimeOperationView({ operation }: { operation: RuntimeOperation }) {
  const labels = { start: 'Starting Lemon', restart: 'Restarting Lemon', stop: 'Stopping Lemon' };
  return <div className="stack runtime-operation"><div role="status" aria-live="polite"><strong>{labels[operation.action]}</strong> <Badge tone={operation.state === 'failed' ? 'danger' : operation.state === 'succeeded' ? 'good' : 'warning'}>{operation.state === 'running' ? 'In progress' : operation.state === 'succeeded' ? 'Completed' : 'Failed'}</Badge></div><details><summary>Details · command output</summary><p>Started {formatTime(operation.startedAtMs)}</p>{operation.completedAtMs !== null && <p>Finished {formatTime(operation.completedAtMs)}</p>}{operation.exitCode !== null && <p>Exit code: {operation.exitCode}</p>}<pre>{operation.output || 'No output yet.'}</pre><button onClick={() => void navigator.clipboard.writeText(operation.output).catch(() => undefined)}>Copy output</button></details></div>;
}

export function RuntimeConfirmation({ action, via, busy, available, error, uncertain, onConfirm, onCancel }: { action: 'stop' | 'restart'; via: InstanceRuntime['via']; busy: boolean; available: boolean; error: unknown; uncertain: boolean; onConfirm: () => Promise<void>; onCancel: () => void }) {
  const titleId = useId(), descriptionId = useId();
  const cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    cancel.current?.focus();
    return () => { if (previous?.isConnected) previous.focus(); };
  }, []);
  const title = action === 'stop' ? 'Stop Lemon' : 'Restart Lemon';
  return <div className="modal-backdrop" onKeyDown={event => { trapDialogFocus(event); if (event.key === 'Escape' && (!busy || uncertain)) onCancel(); }}><section className="modal stack" role="dialog" aria-modal="true" aria-labelledby={titleId} aria-describedby={descriptionId}>
    <h2 id={titleId}>{title}?</h2>
    <p id={descriptionId}>{action === 'stop' ? `Bots stop working until Lemon is started again. ${via === 'launcher' ? 'Lemon Bot stays available so you can start it from here.' : 'Lemon Bot stays available, but you’ll need to start Lemon on its host. It can’t be started remotely from here.'}` : 'Bots stop working until Lemon has restarted and reconnected. Lemon Bot stays available during the restart.'}</p>
    <InstanceError error={error} uncertain={uncertain}/>
    <div className="row"><button ref={cancel} disabled={busy && !uncertain} onClick={onCancel}>Cancel</button><button className="danger" disabled={busy || !available} onClick={() => void onConfirm()}>{busy ? 'Waiting for Lemon…' : title}</button></div>
  </section></div>;
}
