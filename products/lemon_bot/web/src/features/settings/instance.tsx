import { useState } from 'react';
import { type ControllerLinkState, type InstanceChannel, type InstanceLemonStatus, type InstanceProvider, type RuntimeAction } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, formatTime } from '../../ui';
import { InstanceError, RuntimeActions, RuntimeConfirmation, RuntimeOperationView, useInstance } from '../../instance';
import { relativeTime } from '../../live';

const linkLabels: Record<ControllerLinkState, string> = { connected: 'Connected', connecting: 'Connecting', reconnecting: 'Reconnecting', rejected: 'Connection rejected', stopped: 'Disconnected' };
export function instanceUptime(milliseconds: number): string {
  const seconds = Math.floor(Math.max(0, milliseconds) / 1000);
  if (seconds >= 86400) return `${Math.floor(seconds / 86400)}d ${Math.floor(seconds % 86400 / 3600)}h`;
  if (seconds >= 3600) return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  if (seconds >= 60) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${seconds}s`;
}

export function instanceBuild(lemon: Pick<InstanceLemonStatus, 'version' | 'build'>): string {
  return [lemon.version, lemon.build?.channel, lemon.build?.commit?.slice(0, 7)].filter(Boolean).join(' · ') || 'Unavailable';
}

function HealthError({ error }: { error: InstanceChannel['lastError'] }) {
  return error && <p className="small"><span>Last error: {error.message}</span> <time className="muted" dateTime={new Date(error.atMs).toISOString()} title={formatTime(error.atMs)}>· {relativeTime(error.atMs)}</time></p>;
}

export function ChannelHealth({ channels }: { channels: InstanceChannel[] }) {
  const labels = { connected: 'Connected', configured: 'Configured', error: 'Error' };
  return <div className="stack"><h3>Channels</h3>{channels.length ? <ul className="list instance-health">{channels.map(channel => <li className="list-row" key={channel.id}>
    <div><div className="row spread"><strong>{channel.id}</strong><Badge tone={channel.state === 'connected' ? 'good' : channel.state === 'error' ? 'danger' : 'muted'}>{labels[channel.state]}</Badge></div><HealthError error={channel.lastError}/></div>
  </li>)}</ul> : <p className="muted">No channels configured.</p>}</div>;
}

export function ProviderHealth({ providers }: { providers: InstanceProvider[] | null }) {
  const labels = { present: 'Key available', missing: 'Key missing', not_required: 'Key not required' };
  return <section className="panel stack"><h2>Provider diagnostic history</h2><p className="small muted">Controller-only observations, not live readiness or the execution target’s Current default. Historical errors remain after successful calls and clear when Lemon restarts. Manage credentials in Settings → Providers.</p>{providers === null ? <p className="muted">Provider details are unavailable.</p> : providers.length ? <ul className="list instance-health">{providers.map(provider => <li className="list-row" key={provider.id}>
    <div><div className="row spread"><strong>{provider.id}</strong><Badge tone={provider.credential === 'missing' ? 'warning' : provider.credential === 'present' ? 'good' : 'muted'}>{labels[provider.credential]}</Badge></div>
      {!provider.configured && <p className="small muted">Not configured</p>}
      <HealthError error={provider.lastError}/>
    </div>
  </li>)}</ul> : <p className="muted">No providers configured.</p>}</section>;
}

export function InstanceSettings() {
  const { client, snapshot, realtime, updateInstance, navigate } = useApp();
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
  const linkError = link?.lastError ? `${link.url}\n${link.lastError.code}: ${link.lastError.message}\n${formatTime(link.lastError.atMs)}` : '';
  return <div className="stack instance-page">
    <div className="row spread"><p className="small muted">Refreshes every 10 seconds while visible, or every 2 seconds during a command.</p><button disabled={instance.refreshing} onClick={() => void instance.refresh()}>{instance.refreshing ? 'Refreshing…' : 'Refresh'}</button></div>
    {!status && instance.refreshing && <p role="status">Loading Lemon instance…</p>}
    <InstanceError error={instance.error} uncertain={instance.uncertain}/>
    {status && <>
      <section className="panel stack"><h2>Lifecycle</h2>
        <RuntimeActions runtime={status.runtime} owner={role === 'owner'} available={available} busy={instance.busy} onAction={run}/>
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
          <dt>Build</dt><dd>{instanceBuild(lemon)}</dd>
          <dt>Uptime</dt><dd>{lemon.uptimeMs === null ? 'Unavailable' : instanceUptime(lemon.uptimeMs)}</dd>
          <dt>Memory</dt><dd>{lemon.memoryMb === null ? 'Unavailable' : `${lemon.memoryMb.toLocaleString(undefined, { maximumFractionDigits: 1 })} MB`}</dd>
          {lemon.runs && <><dt>Active / queued runs</dt><dd>{lemon.runs.active} / {lemon.runs.queued}</dd><dt>Completed today</dt><dd>{lemon.runs.completedToday}</dd></>}
          {lemon.activeSessions !== null && <><dt>Active sessions</dt><dd>{lemon.activeSessions}</dd></>}
          {lemon.nodes && <><dt>Nodes online</dt><dd>{lemon.nodes.online} of {lemon.nodes.total}</dd></>}
          {lemon.connections && <><dt>Connections</dt><dd>{lemon.connections.active} active · {lemon.connections.operators} operator · {lemon.connections.nodes} node</dd></>}
          {lemon.skills && <><dt>Skills</dt><dd>{lemon.skills.enabled} enabled / {lemon.skills.installed} installed</dd></>}
        </dl>
        {channels && <ChannelHealth channels={channels.details}/>}</>}
        {status.lemonUnavailableReason && <p className="muted">{status.lemonUnavailableReason}</p>}
        {!lemon && !status.lemonUnavailableReason && <p className="muted">Lemon details are unavailable while the link is down.</p>}
      </section>
      {lemon && <ProviderHealth providers={lemon.providers}/>}
      {role === 'owner' && <button onClick={() => navigate({ screen: 'settings.providers' })}>Manage providers</button>}
      <p className="small muted">Measured {formatTime(status.measuredAtMs)}</p>
      {confirmation && <RuntimeConfirmation action={confirmation} via={status.runtime.via} busy={instance.busy} available={available && status.runtime.actions.includes(confirmation)} error={instance.error} uncertain={instance.uncertain} onCancel={() => setConfirmation(undefined)} onConfirm={async () => { if (await instance.mutate(confirmation)) setConfirmation(undefined); }}/>}
    </>}
  </div>;
}
