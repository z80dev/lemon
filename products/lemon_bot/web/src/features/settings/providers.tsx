import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { nonce, type ManagedProvider, type ProviderDeviceLogin, type ProviderManagement } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, ConfirmDialog, Field, Loading, formatTime, useQuery } from '../../ui';
import { allPages } from './shared';
import { checkedDeviceLogin, providerApi, providerFailure, readProviderIntent, type DeviceAction, type ProviderApi, type ProviderIntent } from './providers-api';

const statusLabels: Record<ManagedProvider['status'], string> = { ready: 'Ready', needs_login: 'Needs login', expired: 'Expired', configured: 'Configured' };
const deviceLabels: Record<ProviderDeviceLogin['status'], string> = { starting: 'Starting', pending: 'Waiting for sign-in', completed: 'Sign-in completed', denied: 'Sign-in denied', expired: 'Sign-in expired', cancelled: 'Sign-in cancelled', lost: 'Sign-in no longer available', failed: 'Sign-in failed' };
const overrideLabels = { project_configuration: 'Project configuration', credential_pool: 'Credential pool', external_secret_source: 'External secret source' };

export function ProvidersSettings() {
  const { client, snapshot } = useApp();
  // A new product session/client must never inherit another client's pending async work.
  const clientScope = useMemo(() => nonce(), [client]);
  if (snapshot.member.role !== 'owner' || snapshot.workspace.ownerUserId !== snapshot.user.id) return <section className="panel"><p>Only the workspace owner can manage Providers.</p></section>;
  return <ProviderInventory key={`${clientScope}:${snapshot.workspace.id}:${snapshot.user.id}`}/>;
}

function ProviderInventory() {
  const { client, snapshot } = useApp();
  const [machineId, setMachineId] = useState('');
  const inventory = useQuery('providers:inventory', async () => {
    try {
      const [machines, sessions] = await Promise.all([
        allPages(cursor => client.call('GET /machines', { query: { cursor, limit: 200 } })),
        allPages(cursor => client.call('GET /auth/sessions', { query: { cursor, limit: 200 } })),
      ]);
      const session = sessions.find(item => item.current);
      if (!session) throw new Error('Current session unavailable');
      return { machines: machines.filter(item => item.ownerUserId === snapshot.user.id && item.nodeId && item.status !== 'revoked'), sessionId: session.id };
    } catch { throw new Error('Provider targets could not be loaded. Check your owner session and connection.'); }
  });
  const selected = inventory.data?.machines.find(item => item.id === machineId);
  return <div className="stack">
    <p>Manage model-provider credentials on an existing running execution target. Credentials stay on that target; adding, signing in or disconnecting never changes its default or any Bot/profile.</p>
    {inventory.loading && !inventory.data && <Loading label="Loading execution targets…"/>}
    {!!inventory.error && <p role="alert">Provider targets could not be loaded. <button onClick={() => void inventory.reload().catch(() => undefined)}>Refresh and check again</button></p>}
    {inventory.data && <>
      <Field label="Execution target"><select value={machineId} onChange={event => setMachineId(event.target.value)}><option value="">Controller</option>{inventory.data.machines.map(machine => <option key={machine.id} value={machine.id}>{machine.name} · {machine.id} · {machine.nodeId}</option>)}</select></Field>
      {machineId && !selected ? <p role="alert">This machine is no longer an owned execution target. Choose another target.</p> : <ProviderTarget key={`${inventory.data.sessionId}:${machineId}:${selected?.nodeId || ''}`} machineId={machineId || undefined} expectedNodeId={selected?.nodeId || undefined} sessionId={inventory.data.sessionId}/>}
    </>}
  </div>;
}

function ProviderTarget({ machineId, sessionId, expectedNodeId }: { machineId?: string; sessionId: string; expectedNodeId?: string }) {
  const { client } = useApp();
  const api = useMemo(() => providerApi(client, machineId), [client, machineId]);
  const query = useQuery(`providers:${sessionId}:${machineId || 'controller'}`, async () => {
    try {
      const result = await api.status();
      if (expectedNodeId && result.target.nodeId !== expectedNodeId) throw new Error('Execution target changed');
      return result;
    }
    catch { throw new Error('Provider status could not be loaded.'); }
  });
  return <>
    {query.loading && !query.data && <Loading label="Loading provider status…"/>}
    {!!query.error && <p role="alert">Provider status could not be loaded. Existing details may be out of date. <button onClick={() => void query.reload().catch(() => undefined)}>Refresh and check again</button></p>}
    {query.data && <ProviderControls key={`${query.data.target.id}:${query.data.target.nodeId}:${query.data.target.hostname}`} management={query.data} stale={!!query.error} api={api} machineId={machineId} sessionId={sessionId} reload={query.reload} accept={query.setData}/>}
  </>;
}

function ProviderControls({ management, stale, api, machineId, sessionId, reload, accept }: {
  management: ProviderManagement; stale: boolean; api: ProviderApi; machineId?: string; sessionId: string;
  reload: () => Promise<void>; accept: (result: ProviderManagement) => void;
}) {
  const { client, snapshot, online } = useApp();
  const { target } = management;
  const storageKey = `lemonbot.provider-intent:${client.baseUrl}:${snapshot.workspace.id}:${snapshot.user.id}:${sessionId}:${machineId || 'controller'}:${target.id}`;
  const [intent, setIntent] = useState<ProviderIntent | null>(() => readProviderIntent(storageKey));
  const intentRef = useRef(intent); intentRef.current = intent;
  const [busy, setBusy] = useState(false); const busyRef = useRef(false);
  const [message, setMessage] = useState('');
  const [reviewed, setReviewed] = useState(false);
  const [uncertain, setUncertain] = useState(!!intent);
  const [login, setLogin] = useState<ProviderDeviceLogin | null>(null);
  const [foreground, setForeground] = useState(document.visibilityState !== 'hidden');
  const [editing, setEditing] = useState<ManagedProvider | null>(null);
  const [disconnecting, setDisconnecting] = useState<ManagedProvider | null>(null);
  const [defaultOpen, setDefaultOpen] = useState(false);
  const [providerId, setProviderId] = useState('');
  const [modelId, setModelId] = useState('');
  const [defaultConfirmation, setDefaultConfirmation] = useState<{ providerId: string; modelId: string } | null>(null);
  const mounted = useRef(true);
  useLayoutEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);
  useEffect(() => {
    const hide = () => { foregroundRef.current = false; setForeground(false); setEditing(null); setDisconnecting(null); setDefaultConfirmation(null); setLogin(null); };
    const show = () => { foregroundRef.current = document.visibilityState !== 'hidden'; setForeground(foregroundRef.current); };
    const visibility = () => { if (document.visibilityState === 'hidden') hide(); else show(); };
    document.addEventListener('visibilitychange', visibility); window.addEventListener('pagehide', hide); window.addEventListener('blur', hide); window.addEventListener('focus', show);
    return () => { document.removeEventListener('visibilitychange', visibility); window.removeEventListener('pagehide', hide); window.removeEventListener('blur', hide); window.removeEventListener('focus', show); };
  }, []);

  function save(next: ProviderIntent | null) {
    if (next) sessionStorage.setItem(storageKey, JSON.stringify(next)); else sessionStorage.removeItem(storageKey);
    intentRef.current = next; if (mounted.current) setIntent(next);
  }
  function acceptStatus(result: ProviderManagement) {
    if (result.target.id !== target.id || result.target.nodeId !== target.nodeId || result.target.hostname !== target.hostname) throw new Error('Execution target changed');
    if (mounted.current) accept(result);
  }
  async function checkStatus() {
    if (busyRef.current || !online) return;
    busyRef.current = true; setBusy(true); setReviewed(false);
    try { await reload(); if (mounted.current && intentRef.current?.kind !== 'device') setReviewed(true); }
    catch { if (mounted.current) setMessage('Status could not be checked. The previous change is still unconfirmed.'); }
    finally { busyRef.current = false; if (mounted.current) setBusy(false); }
  }
  async function mutate(next: Exclude<ProviderIntent, { kind: 'device' }>, operation: () => Promise<ProviderManagement>) {
    if (!online || busyRef.current || intentRef.current || stale || !foreground) return;
    busyRef.current = true; setBusy(true); setMessage(''); setReviewed(false);
    let dispatched = false;
    try {
      save(next); dispatched = true;
      const result = await operation();
      acceptStatus(result); save(null);
      if (mounted.current) { setUncertain(false); setMessage('Change acknowledged. Review the provider status and Current default below.'); }
    } catch (failure) {
      const safe = providerFailure(failure);
      if (!dispatched || !safe.unknown) { try { save(null); } catch { /* Keep the in-memory fence when storage fails. */ } }
      if (mounted.current) { setMessage(safe.message); setUncertain(dispatched && safe.unknown); }
    } finally { busyRef.current = false; if (mounted.current) setBusy(false); }
  }
  async function deviceAction(action: DeviceAction, original?: Extract<ProviderIntent, { kind: 'device' }>, reconciliation = false) {
    if (!online || busyRef.current || stale || !foreground || (uncertain && !reconciliation)) return;
    const existing = intentRef.current;
    if (!original && existing) return;
    if (original && (existing?.kind !== 'device' || existing.clientNonce !== original.clientNonce)) return;
    const next: Extract<ProviderIntent, { kind: 'device' }> = original ? { ...original, action } : { kind: 'device', providerId: 'openai_codex', targetId: target.id, clientNonce: nonce(), pollNonce: nonce(), cancelNonce: nonce(), action: 'start', startedAtMs: Date.now() };
    busyRef.current = true; setBusy(true); setMessage(''); setReviewed(false);
    let dispatched = false;
    try {
      save(next); dispatched = true;
      const result = checkedDeviceLogin(await api.device(next), next);
      if (!mounted.current) return;
      setUncertain(false);
      if (result.status === 'starting' || result.status === 'pending') {
        save({ ...next, action: 'poll' });
        // A response arriving after backgrounding must not restore a code or browser link.
        if (document.visibilityState !== 'hidden' && foregroundRef.current) setLogin(result);
      } else {
        setLogin(result); save(null);
        setMessage(`${deviceLabels[result.status]}. Checking provider status; completion alone does not prove readiness. The default was not changed.`);
        await reload().catch(() => { if (mounted.current) setMessage(`${deviceLabels[result.status]}. Provider status could not be reloaded; use Check status. Completion alone does not prove readiness.`); });
      }
    } catch (failure) {
      // A generic rejection while reconciling cannot settle an earlier uncertain device operation.
      const safe = providerFailure(failure);
      const fenced = dispatched && (reconciliation || !!original || safe.unknown);
      if (!fenced) { try { save(null); } catch { /* No credential or device state is saved. */ } }
      if (mounted.current) { setLogin(null); setUncertain(fenced); setMessage(safe.message); }
    } finally { busyRef.current = false; if (mounted.current) setBusy(false); }
  }
  const foregroundRef = useRef(foreground); foregroundRef.current = foreground;
  useEffect(() => {
    if (!foreground || !online || busy || uncertain || intent?.kind !== 'device' || !login || !['starting', 'pending'].includes(login.status)) return;
    const remaining = Math.min(login.expiresAtMs ?? intent.startedAtMs + 900000, intent.startedAtMs + 900000) - Date.now();
    if (remaining <= 0) { setLogin(null); setUncertain(true); setMessage('The displayed sign-in code expired. Check this exact login before starting another.'); return; }
    const timer = window.setTimeout(() => {
      if (document.visibilityState === 'hidden' || !foregroundRef.current) return;
      if (Date.now() >= Math.min(login.expiresAtMs ?? intent.startedAtMs + 900000, intent.startedAtMs + 900000)) {
        setLogin(null); setUncertain(true); setMessage('The displayed sign-in code expired. Check this exact login before starting another.'); return;
      }
      void deviceAction('poll', intent);
    }, Math.min(remaining, login.pollIntervalMs || 1000));
    return () => window.clearTimeout(timer);
  }, [foreground, online, busy, uncertain, intent, login]);

  const disabled = !online || !foreground || busy || !!intent || stale;
  const deviceIntent = intent?.kind === 'device' ? intent : null;
  return <div className="stack">
    <section className="panel stack"><h2>Execution target</h2><dl className="settings-facts"><dt>Workspace</dt><dd>{snapshot.workspace.name} · {snapshot.workspace.id}</dd><dt>Backend</dt><dd><code>{new URL(client.baseUrl).origin}</code></dd><dt>Target</dt><dd>{machineId ? 'Owned execution machine' : 'Controller'} · {target.hostname}</dd><dt>Target ID</dt><dd><code>{target.id}</code></dd>{machineId && <><dt>Machine ID</dt><dd><code>{machineId}</code></dd></>}<dt>Node ID</dt><dd><code>{target.nodeId || 'Controller (no node ID)'}</code></dd></dl><button disabled={!online || busy} onClick={() => void checkStatus()}>Check status</button></section>
    {!online && <p role="status">You’re offline. Provider changes are never queued.</p>}
    {message && <p role="status" className="panel">{message}</p>}
    {intent && <section className="panel stack" role="status"><h2>{deviceIntent ? 'Device sign-in' : 'Unconfirmed provider change'}</h2><p>Provider: {intent.providerId} · Target: {intent.targetId}</p>
      {deviceIntent ? <><p>Sign-in stays bound to this product session and execution target. Nothing is retried after an uncertain response.</p>{(!login || uncertain) && <button disabled={!online || !foreground || busy || stale} onClick={() => void deviceAction(deviceIntent.action, deviceIntent, true)}>Check this login</button>}<button disabled={!online || !foreground || busy || stale || uncertain} onClick={() => { setLogin(null); void deviceAction('cancel', deviceIntent); }}>Cancel sign-in</button></> : <><p>The credential field has been cleared. A generic status listing cannot prove that the original mutation settled. Check the exact target and provider configuration before starting another change.</p>{reviewed && <><p>Current status was refreshed for review. This does not confirm the earlier change.</p><button disabled={busy || !online} onClick={() => { try { save(null); setUncertain(false); setReviewed(false); setMessage('Status reviewed. Any next change is a new explicit intent; the previous request was not retried.'); } catch { setMessage('The reconciliation reference could not be cleared. No new change was started.'); } }}>I’ve checked — start a new change</button></>}</>}
      <details><summary>Details · reconciliation reference</summary><code>{intent.clientNonce}</code></details>
    </section>}
    {login && <section className="panel stack"><h2>{deviceLabels[login.status]}</h2>{login.status === 'pending' && foreground && <><p>Sign in using your normal browser. Your provider account or organization may need device-code sign-in enabled.</p><Field label="User code"><code>{login.userCode}</code></Field><p>Expires {formatTime(login.expiresAtMs!)}. Status is checked no faster than every {login.pollIntervalMs! / 1000} seconds while this page is visible and foreground.</p><a className="button" href={login.verificationUrl!} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Open sign-in in browser</a><p>If the new tab does not open, enter <code>{login.verificationUrl}</code> in your browser and use the code above.</p></>}</section>}
    <section className="panel stack"><h2>Current default</h2><dl className="settings-facts"><dt>Provider</dt><dd>{management.default.providerId || 'Not selected'}</dd><dt>Model</dt><dd>{management.default.modelId || 'Not selected'}</dd></dl><p>This is the effective target default. Changing the global default is separate from credentials, never rewrites Bots or profiles, and may remain overridden by project or environment settings.</p><button disabled={disabled} onClick={() => { setProviderId(management.default.providerId || management.providers[0]?.id || ''); setModelId(management.default.modelId || ''); setDefaultOpen(true); }}>Change default</button>
      {defaultOpen && <form className="stack" onSubmit={event => { event.preventDefault(); if (!disabled && providerId && modelId.trim()) setDefaultConfirmation({ providerId, modelId: modelId.trim() }); }}><Field label="Default provider"><select value={providerId} onChange={event => setProviderId(event.target.value)} disabled={disabled}>{management.providers.map(provider => <option key={provider.id} value={provider.id}>{provider.displayName} · {provider.id}</option>)}</select></Field><Field label="Default model"><input value={modelId} maxLength={256} onChange={event => setModelId(event.target.value)} required disabled={disabled} autoComplete="off"/></Field><div className="row"><button disabled={disabled || !modelId.trim()}>Review default change</button><button type="button" onClick={() => { setDefaultOpen(false); setModelId(''); setDefaultConfirmation(null); }}>Cancel</button></div></form>}
    </section>
    <section className="stack" aria-label="Providers"><h2>Providers</h2>{!management.providers.length && <p>No provider methods are advertised by this target.</p>}{management.providers.map(provider => <article className="panel stack" key={provider.id}><div className="row spread"><h3>{provider.displayName}</h3><Badge tone={provider.status === 'ready' ? 'good' : provider.status === 'configured' ? 'muted' : 'warning'}>{statusLabels[provider.status]}</Badge></div><p><code>{provider.id}</code> · Configured: {provider.configured ? 'Yes' : 'No'}</p><p>{provider.lastValidation ? `Last resolver validation: ${provider.lastValidation.ready ? 'Ready' : 'Not ready'} · ${formatTime(provider.lastValidation.atMs)}` : 'Last resolver validation: Not checked'}. This static resolver check does not validate the provider account, quota or a model call.</p>
      {!!provider.environmentOverrides.length && <p className="warning-text">Environment overrides: {provider.environmentOverrides.join(', ')}. A global credential change may not become effective.</p>}
      {!!provider.configurationOverrides.length && <p className="warning-text">Configuration overrides: {provider.configurationOverrides.map(item => overrideLabels[item]).join(', ')}. Resolve these on the target; this screen never resets credential pools or project configuration.</p>}
      <div className="row">{provider.methods.includes('api_key') && <button disabled={disabled} onClick={() => setEditing(provider)}>{provider.configured ? 'Replace credential' : 'Add API key'}</button>}{provider.id === 'openai_codex' && provider.methods.includes('device_code') && <button disabled={disabled} onClick={() => void deviceAction('start')}>{provider.configured ? 'Re-authenticate' : 'Sign in with device code'}</button>}<button className="danger" disabled={disabled || !provider.configured} onClick={() => setDisconnecting(provider)}>Disconnect</button></div>
      {!provider.methods.includes('api_key') && !(provider.id === 'openai_codex' && provider.methods.includes('device_code')) && <p className="muted">No supported sign-in method is advertised for this client on the target.</p>}
    </article>)}</section>
    {editing && <SecureApiKeyForm key={editing.id} provider={editing} management={management} machineId={machineId} disabled={disabled} cancel={() => setEditing(null)} submit={value => {
      const provider = editing; setEditing(null);
      const next: ProviderIntent = { kind: 'api_key', clientNonce: nonce(), targetId: target.id, providerId: provider.id };
      return mutate(next, () => api.key(provider.id, { clientNonce: next.clientNonce, targetId: target.id, value }));
    }}/>}
    {disconnecting && <ConfirmDialog title={`Disconnect ${disconnecting.displayName}?`} disabled={disabled} onCancel={() => setDisconnecting(null)} onConfirm={async () => {
      const provider = disconnecting; setDisconnecting(null);
      const next: ProviderIntent = { kind: 'disconnect', clientNonce: nonce(), targetId: target.id, providerId: provider.id };
      await mutate(next, () => api.disconnect(provider.id, { clientNonce: next.clientNonce, targetId: target.id }));
    }}><TargetReview management={management} machineId={machineId}/><p>This removes the local credential/configuration on this target only. It is not provider-side key or OAuth grant revocation. Revoke access separately in the provider dashboard. Environment and external credentials can still resolve. The default and all Bots/profiles are unchanged.</p></ConfirmDialog>}
    {defaultConfirmation && <ConfirmDialog title="Change default?" disabled={disabled} onCancel={() => setDefaultConfirmation(null)} onConfirm={async () => {
      const choice = defaultConfirmation; setDefaultConfirmation(null); setDefaultOpen(false);
      const next: ProviderIntent = { kind: 'default', clientNonce: nonce(), targetId: target.id, ...choice };
      await mutate(next, () => api.changeDefault({ clientNonce: next.clientNonce, targetId: target.id, ...choice }));
    }}><TargetReview management={management} machineId={machineId}/><p>Set the global default to {defaultConfirmation.providerId} / {defaultConfirmation.modelId}? Higher-priority overrides may leave Current default unchanged. No credential changes and no Bot/profile rewrites.</p></ConfirmDialog>}
  </div>;
}

function TargetReview({ management, machineId }: { management: ProviderManagement; machineId?: string }) {
  const { client, snapshot } = useApp();
  return <p>Workspace: {snapshot.workspace.name} · {snapshot.workspace.id}<br/>Backend: {new URL(client.baseUrl).origin}<br/>Execution target: {management.target.hostname} · {management.target.id} · Node ID: {management.target.nodeId || 'Controller'}{machineId && <> · Machine ID: {machineId}</>}</p>;
}

function SecureApiKeyForm({ provider, management, machineId, disabled, submit, cancel }: { provider: ManagedProvider; management: ProviderManagement; machineId?: string; disabled: boolean; submit: (value: string) => Promise<void>; cancel: () => void }) {
  const field = useRef<HTMLInputElement>(null);
  const [invalid, setInvalid] = useState(false);
  useLayoutEffect(() => {
    const input = field.current;
    const clear = () => { if (input) input.value = ''; };
    document.addEventListener('visibilitychange', clear); window.addEventListener('pagehide', clear); window.addEventListener('blur', clear);
    return () => { clear(); document.removeEventListener('visibilitychange', clear); window.removeEventListener('pagehide', clear); window.removeEventListener('blur', clear); };
  }, []);
  return <form className="panel stack" autoComplete="off" onSubmit={event => {
    event.preventDefault(); const input = field.current; if (!input) return;
    let value = input.value; input.value = '';
    if (disabled || !value || value.includes('\0') || new TextEncoder().encode(value).length > 16384) { value = ''; setInvalid(true); return; }
    const pending = submit(value); value = '';
    void pending.finally(() => { input.value = ''; });
  }}>
    <h2>{provider.configured ? 'Replace credential' : 'Add API key'} · {provider.displayName}</h2>
    <TargetReview management={management} machineId={machineId}/>
    <p>Write-only. Sent once to this execution target; never restored or saved in browser storage. The default does not change.</p>
    <Field label="API key"><input ref={field} type="password" autoComplete="off" autoCapitalize="none" spellCheck={false} disabled={disabled} maxLength={16384} data-private="true" data-1p-ignore="true" data-lpignore="true"/></Field>
    {invalid && <p role="alert">Enter a nonempty API key of at most 16,384 UTF-8 bytes without NUL. The field was cleared.</p>}
    <div className="row"><button disabled={disabled}>Submit API key</button><button type="button" onClick={() => { if (field.current) field.current.value = ''; cancel(); }}>Cancel</button></div>
  </form>;
}
