import { useEffect, useState } from 'react';
import { type InstanceStatus, type LemonBotClient, type RealtimeState } from '@lemon-bot/sdk';
import { connectionIssue } from './connection-state';
import { InstanceError, RuntimeActions, RuntimeConfirmation, RuntimeOperationView, useInstance } from './instance';
import { formatTime } from './ui';
import './connection.css';

export function ConnectionPanel({ client, state, browserOnline, controlConnected, error, nextRetryAtMs, lastAttemptAtMs, retry, busy, role, onInstance, onRunning, viewInstance }: {
  client: LemonBotClient; state: RealtimeState; browserOnline: boolean; controlConnected?: boolean; error: unknown;
  nextRetryAtMs: number | null; lastAttemptAtMs: number; retry: () => void; busy: boolean; role?: string; onInstance: (status: InstanceStatus) => void; onRunning: (running: boolean) => void; viewInstance: () => void;
}) {
  const issue = connectionIssue(state, browserOnline, controlConnected, error);
  const controllerDown = issue.layer === 'controller';
  const canView = role === 'owner' || role === 'admin';
  const instance = useInstance(client, controllerDown && canView, onInstance);
  const [now, setNow] = useState(Date.now());
  const running = instance.status?.runtime.operation?.state === 'running';
  useEffect(() => { onRunning(running); }, [running, onRunning]);
  const [copied, setCopied] = useState(false), [copyFailed, setCopyFailed] = useState(false);
  const [restart, setRestart] = useState(false);
  useEffect(() => { const timer = setInterval(() => setNow(Date.now()), 1000); return () => clearInterval(timer); }, []);
  const origin = new URL(client.baseUrl).origin;
  const deadline = controllerDown ? instance.status?.controller.nextRetryAtMs : nextRetryAtMs;
  const remaining = deadline ? Math.max(0, Math.ceil((deadline - now) / 1000)) : 0;
  const detail = [origin, `Last attempt: ${formatTime(lastAttemptAtMs)}`, error instanceof Error ? error.message : '', instance.status?.controller.state, instance.status?.controller.url, instance.status?.controller.lastError ? `${instance.status.controller.lastError.code}: ${instance.status.controller.lastError.message}` : ''].filter(Boolean).join('\n');
  return <section className="connection-panel stack" aria-label="Connection status">
    <div aria-live="polite" role="status"><h2>{running && state === 'live' && controlConnected ? 'Lemon command in progress' : issue.title}</h2><p>Trying to reach <strong>{origin}</strong>{import.meta.env.DEV && origin === location.origin ? ' through the development proxy' : ''}</p><p>{running && state === 'live' && controlConnected ? 'The Lemon link is connected. Waiting for the command to finish.' : issue.reason}</p>{remaining > 0 ? <p className="small">Retrying in {remaining}s</p> : busy && <p className="small">Trying to connect…</p>}</div>
    <div className="row"><button className="primary" disabled={busy || !browserOnline} onClick={retry}>Try again</button>
      {controllerDown && canView && <button disabled={instance.busy || !browserOnline} onClick={() => void instance.mutate()}>Reconnect Lemon link</button>}
    </div>
    {controllerDown && instance.status && <RuntimeActions runtime={instance.status.runtime} owner={role === 'owner'} available={browserOnline && state === 'live'} busy={instance.busy} recovery onAction={action => { if (action === 'start') void instance.mutate(action); else if (action === 'restart') setRestart(true); }}/>}
    {canView && <div className="row"><button onClick={viewInstance}>View instance details</button></div>}
    {instance.status?.runtime.operation && <RuntimeOperationView operation={instance.status.runtime.operation}/>}
    <InstanceError error={instance.error} uncertain={instance.uncertain}/>
    {restart && <RuntimeConfirmation action="restart" via={instance.status?.runtime.via ?? null} busy={instance.busy} available={browserOnline && state === 'live' && !!instance.status?.runtime.actions.includes('restart')} error={instance.error} uncertain={instance.uncertain} onCancel={() => setRestart(false)} onConfirm={async () => { if (await instance.mutate('restart')) setRestart(false); }}/>}
    <details><summary>Details</summary><pre>{detail}</pre><button onClick={() => void navigator.clipboard.writeText(detail).then(() => { setCopied(true); setCopyFailed(false); }).catch(() => setCopyFailed(true))}>Copy details</button>{copied && <p role="status">Details copied.</p>}{copyFailed && <p role="status">Couldn’t copy. Select the details and copy them manually.</p>}</details>
  </section>;
}
