import { useState } from 'react';
import { LemonBotError } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { useQuery, ErrorNotice, Loading, Field, formatTime } from '../../ui';
import { allPages } from './shared';

export function AboutSettings() {
  const { client, snapshot, device, online, navigate, reportError } = useApp();
  const setup = useQuery('settings:product-version', () => client.call('GET /setup'));
  const capabilities = useQuery('settings:about-capabilities', () => client.call('GET /capabilities'));
  const machines = useQuery('settings:about-machines', () => allPages(cursor => client.call('GET /machines', { query: { cursor, limit: 200 } })));
  const [machineId, setMachineId] = useState('');
  const host = useQuery(`settings:about-host:${machineId}`, async () => machineId ? client.call('GET /machines/:id/host', { params: { id: machineId } }) : null);
  const [conversationId, setConversationId] = useState(''); const [copyError, setCopyError] = useState<unknown>(); const [copied, setCopied] = useState(false);
  const diagnosticErrors = [setup.error, capabilities.error, machines.error, host.error].filter((error): error is LemonBotError => error instanceof LemonBotError);
  const newerRequired = capabilities.data?.minClientVersions.web ? compareVersions('1.0.0', capabilities.data.minClientVersions.web) < 0 : false;
  return <div className="stack">
    <section className="panel stack">
      <h2>Lemon Bot</h2><p>Durable teammates on machines you own. Web, backend and destination workers are updated independently.</p>
      <ErrorNotice error={setup.error} /><ErrorNotice error={capabilities.error} />{setup.loading && <Loading />}
      <dl className="settings-facts">
        <dt>Web client</dt><dd>1.0.0</dd>
        <dt>Product backend</dt><dd>{setup.data?.version ?? 'Unavailable / loading'}</dd>
        <dt>Product API</dt><dd>{setup.data ? `v${setup.data.apiVersion}` : 'Unknown'}</dd>
        <dt>Platform</dt><dd>Web · {navigator.platform || 'Browser platform not reported'}</dd>
        <dt>Browser network</dt><dd>{online ? 'Online' : 'Offline'}</dd>
        <dt>Swarm control service</dt><dd>{capabilities.data ? capabilities.data.controlConnected ? 'Connected' : 'Disconnected — running truth requires reconciliation' : 'Unknown'}</dd>
        <dt>Minimum supported web version</dt><dd>{capabilities.data?.minClientVersions.web ?? 'Unknown'}</dd>
        <dt>Current device</dt><dd>{device ? `${device.name} · ${device.id}` : 'Not registered'}</dd>
      </dl>
      {newerRequired && <p role="alert" className="error-notice">This client is below the configured minimum version. Ask the operator to deploy current web assets, reload, and reconcile before continuing.</p>}
      <div className="row">
        <button disabled={setup.loading || capabilities.loading} onClick={() => void Promise.all([setup.reload(), capabilities.reload(), machines.reload()]).catch(reportError)}>Retry service/version reads</button>
        <button onClick={() => navigate({ screen: 'machines' })}>Machine inventory & service status</button>
      </div>
    </section>
  <section className="panel stack"><h2>Destination worker versions</h2><ErrorNotice error={machines.error} /><Field label="Inspect authorized machine"><select value={machineId} onChange={e => setMachineId(e.target.value)}><option value="">Select a machine for a live host read</option>{machines.data?.map(machine => <option value={machine.id} key={machine.id}>{machine.name} · {machine.status}</option>)}</select></Field><ErrorNotice error={host.error} />{host.loading && <Loading />}{host.data && <dl className="settings-facts"><dt>Lemon worker version</dt><dd>{host.data.lemonVersion}</dd><dt>OS / architecture</dt><dd>{host.data.os} {host.data.osVersion} · {host.data.arch}</dd><dt>Measurement</dt><dd>{formatTime(host.data.measuredAtMs)} — measured, not an inferred current state</dd></dl>}<p className="muted">Offline host/version reads can fail; they are not replaced with fabricated measurements. Updating web assets does not update a worker or reset its disk.</p><button disabled={!machineId} onClick={() => navigate({ screen: 'machine.detail', id: machineId })}>Open selected machine</button></section>
  <section className="panel stack"><h2>Safe support diagnostics</h2><p className="muted">Only version, service state and selected opaque IDs/timestamps are copied. No session tokens, push keys, provider credentials, private transcript, host paths or exception message bodies are included. Nothing is automatically uploaded.</p><Field label="Conversation ID to include (optional)"><select value={conversationId} onChange={e => setConversationId(e.target.value)}><option value="">Do not include a conversation</option>{snapshot.conversations.map(conversation => <option key={conversation.id} value={conversation.id}>{conversation.id}</option>)}</select></Field><ErrorNotice error={copyError} /><button onClick={() => void (async () => {
    setCopied(false); setCopyError(undefined);
    try {
      const diagnostics = { generatedAt: new Date().toISOString(), clientVersion: '1.0.0', productVersion: setup.data?.version ?? null, apiVersion: setup.data?.apiVersion ?? null, platform: 'web', browserPlatform: navigator.platform || null, online, controlConnected: capabilities.data?.controlConnected ?? null, workspaceId: snapshot.workspace.id, deviceId: device?.id ?? null, conversationId: conversationId || null, machineId: machineId || null, workerVersion: host.data?.lemonVersion ?? null, workerMeasuredAtMs: host.data?.measuredAtMs ?? null, requests: diagnosticErrors.map(error => ({ requestId: error.requestId, code: error.code, status: error.status, retrySafe: error.retrySafe, outcomeUnknown: error.outcomeUnknown })), attempts: 'Not exposed by this API; no automatic mutation retries' };
      await navigator.clipboard.writeText(JSON.stringify(diagnostics, null, 2)); setCopied(true);
    } catch (error) { setCopyError(error); }
  })()}>Copy redacted diagnostics</button>{copied && <p role="status">Redacted diagnostics copied. Review before sharing.</p>}</section>
  <section className="panel stack"><h2>Operator update & recovery guidance</h2><ol><li>Check the authenticated backend’s capabilities and controller connection before changing clients. A closed browser does not stop Bots; an offline execution host does.</li><li>Deploy the intended Lemon Bot backend and built web assets together using the deployment’s service manager. Reload this page after deployment. Do not put operator credentials in browser configuration.</li><li>Update each worker using its installed Lemon package/service process. Use configured host-management update operations only after previewing scope and safe points.</li><li>For failures, preserve request IDs and timestamps, inspect the relevant service’s redacted logs, and reconcile unknown mutations. Never recreate an environment just because a client looks stale.</li></ol><button onClick={() => navigate({ screen: 'machines.operations' })}>Configured host operations</button></section></div>;
}
function compareVersions(left: string, right: string) {
  const a = left.split('.').map(Number); const b = right.split('.').map(Number);
  for (let index = 0; index < Math.max(a.length, b.length); index++) { const delta = (a[index] ?? 0) - (b[index] ?? 0); if (Number.isFinite(delta) && delta !== 0) return delta; }
  return 0;
}
