import { useState } from 'react';
import { type ControllerLinkState, type RuntimeAction } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, formatTime } from '../../ui';
import { InstanceError, RuntimeConfirmation, RuntimeOperationView, useInstance } from '../../instance';

const linkLabels: Record<ControllerLinkState, string> = { connected: 'Connected', connecting: 'Connecting', reconnecting: 'Reconnecting', rejected: 'Connection rejected', stopped: 'Disconnected' };
export function instanceUptime(milliseconds: number): string {
  const seconds = Math.floor(Math.max(0, milliseconds) / 1000);
  if (seconds >= 86400) return `${Math.floor(seconds / 86400)}d ${Math.floor(seconds % 86400 / 3600)}h`;
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  if (seconds >= 60) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${seconds}s`;
}

export function InstanceSettings() {
  const { client, snapshot, realtime, updateInstance } = useApp();
  const role = snapshot.member.role;
  const canView = role === 'owner' || role === 'admin';
  const instance = useInstance(client, canView, updateInstance);
  const [confirmation, setConfirmation] = useState<'stop' | 'restart'>();
  const status = instance.status;
  const available = navigator.onLine && realtime?.state === 'live';
  const run = (action: RuntimeAction) => {
    if (action === 'start') void instance.mutate(action);
    else setConfirmation(action);
  };
  if (!canView) return <section className="panel"><p>Only workspace owners can view instance details.</p></section>;
  const origin = new URL(client.baseUrl).origin;
  const link = status?.controller, lemon = status?.lemon;
  const channels = lemon?.channels;
  const channelNames = channels ? [...new Set([...channels.configured, ...channels.connected])] : [];
  const linkError = link?.lastError ? `${link.url}\n${link.lastError.code}: ${link.lastError.message}\n${formatTime(link.lastError.atMs)}` : '';
  return <div className="stack instance-page">
    <div className="row spread"><p className="small muted">Refreshes every 10 seconds while visible, or every 2 seconds during a command.</p><button disabled={instance.refreshing} onClick={() => void instance.refresh()}>{instance.refreshing ? 'Refreshing…' : 'Refresh'}</button></div>
    {!status && instance.refreshing && <p role="status">Loading Lemon instance…</p>}
    <InstanceError error={instance.error} uncertain={instance.uncertain}/>
    {status && <>
      <section className="panel stack"><h2>Lifecycle</h2>
        {status.runtime.controllable ? role === 'owner' ? <div className="row">
          <button disabled={!available || instance.busy || link?.state === 'connected'} onClick={() => run('start')}>Start</button>
          <button disabled={!available || instance.busy} onClick={() => run('restart')}>Restart</button>
          <button className="danger" disabled={!available || instance.busy} onClick={() => run('stop')}>Stop</button>
        </div> : <p className="muted">Only workspace owners can start, stop or restart Lemon.</p> : <p className="muted">{status.runtime.reason || 'This service cannot control Lemon on this host.'}</p>}
        {status.runtime.operation && <RuntimeOperationView operation={status.runtime.operation}/>}
      </section>
      <section className="panel stack"><h2>Lemon Bot service</h2><dl className="settings-facts">
        <dt>Version</dt><dd>{status.backend.version} · API {status.backend.apiVersion}</dd>
        <dt>Address</dt><dd>{origin}</dd>
        {status.backend.publicUrl !== origin && <><dt>Public address</dt><dd>{status.backend.publicUrl}</dd></>}
        <dt>Up since</dt><dd>{formatTime(status.backend.startedAtMs)}</dd>
      </dl></section>
      {link && <section className="panel stack"><h2>Lemon link</h2><dl className="settings-facts">
        <dt>State</dt><dd><Badge tone={link.state === 'connected' ? 'good' : 'warning'}>{linkLabels[link.state]}</Badge></dd>
        <dt>Address</dt><dd>{link.url}</dd>
        {link.connectedAtMs !== null && <><dt>Connected since</dt><dd>{formatTime(link.connectedAtMs)}</dd></>}
        {link.lastDisconnectedAtMs !== null && <><dt>Last disconnected</dt><dd>{formatTime(link.lastDisconnectedAtMs)}</dd></>}
        {link.nextRetryAtMs !== null && <><dt>Next retry</dt><dd>{formatTime(link.nextRetryAtMs)}</dd></>}
      </dl>
        {link.lastError && <details><summary>Last error · Details</summary><pre>{linkError}</pre><button onClick={() => void navigator.clipboard.writeText(linkError).catch(() => undefined)}>Copy link error</button></details>}
        <div className="row"><button disabled={!available || instance.busy} onClick={() => void instance.mutate()}>Reconnect</button></div>
      </section>}
      <section className="panel stack"><h2>Lemon</h2>
        {lemon && <><dl className="settings-facts">
          <dt>Version</dt><dd>{lemon.version ?? 'Unavailable'}</dd>
          <dt>Uptime</dt><dd>{lemon.uptimeMs === null ? 'Unavailable' : instanceUptime(lemon.uptimeMs)}</dd>
          <dt>Memory</dt><dd>{lemon.memoryMb === null ? 'Unavailable' : `${lemon.memoryMb.toLocaleString(undefined, { maximumFractionDigits: 1 })} MB`}</dd>
          {lemon.runs && <><dt>Active / queued runs</dt><dd>{lemon.runs.active} / {lemon.runs.queued}</dd><dt>Completed today</dt><dd>{lemon.runs.completedToday}</dd></>}
          {lemon.activeSessions !== null && <><dt>Active sessions</dt><dd>{lemon.activeSessions}</dd></>}
          {lemon.nodes && <><dt>Nodes online</dt><dd>{lemon.nodes.online} of {lemon.nodes.total}</dd></>}
          {lemon.connections && <><dt>Connections</dt><dd>{lemon.connections.active} active · {lemon.connections.operators} operator · {lemon.connections.nodes} node</dd></>}
          {lemon.skills && <><dt>Skills</dt><dd>{lemon.skills.enabled} enabled / {lemon.skills.installed} installed</dd></>}
        </dl>
        {channels && <div className="stack"><h3>Channels</h3>{channelNames.length ? <div className="row">{channelNames.map(name => <Badge key={name} tone={channels.connected.includes(name) ? 'good' : 'warning'}>{name} · {channels.connected.includes(name) ? 'connected' : 'configured'}</Badge>)}</div> : <p className="muted">No channels configured.</p>}</div>}</>}
        {status.lemonUnavailableReason && <p className="muted">{status.lemonUnavailableReason}</p>}
        {!lemon && !status.lemonUnavailableReason && <p className="muted">Lemon details are unavailable while the link is down.</p>}
      </section>
      <p className="small muted">Measured {formatTime(status.measuredAtMs)}</p>
      {confirmation && <RuntimeConfirmation action={confirmation} busy={instance.busy} available={available} error={instance.error} uncertain={instance.uncertain} onCancel={() => setConfirmation(undefined)} onConfirm={async () => { if (await instance.mutate(confirmation)) setConfirmation(undefined); }}/>}
    </>}
  </div>;
}
