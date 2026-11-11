import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { nonce, type ProviderDeviceLogin, type ProviderManagement } from '@lemon-bot/sdk';
import { Key, LogIn, Sparkles, X } from 'lucide-react';
import { useApp } from '../../app';
import { Badge, Field, Loading, formatTime, useQuery } from '../../ui';
import { checkedDeviceLogin, providerApi, providerFailure, type ProviderIntent } from '../settings/providers-api';
import { SecureApiKeyForm, readinessBadgeTone, readinessReasonLabels, readinessStateLabels, readinessStateSummaries } from '../settings/providers';
import './bots.css';

/** Skip is remembered per (workspace, machine) in client UI state only; the server keeps no skip state. */
function skipKey(workspaceId: string, machineId: string) { return `lemonbot.model-readiness-skip:${workspaceId}:${machineId}`; }

export function getModelReadinessSkip(workspaceId: string, machineId: string): boolean {
  try { return sessionStorage.getItem(skipKey(workspaceId, machineId)) === 'true'; }
  catch { return false; }
}

export function setModelReadinessSkip(workspaceId: string, machineId: string, skip: boolean): void {
  try {
    if (skip) sessionStorage.setItem(skipKey(workspaceId, machineId), 'true');
    else sessionStorage.removeItem(skipKey(workspaceId, machineId));
  } catch { /* Storage may be unavailable; the in-memory choice still applies to this view. */ }
}

export function isReadyState(management: ProviderManagement | null | undefined): boolean {
  const state = management?.readiness?.state;
  return state === 'verified' || state === 'saved';
}

/** First-run card line for one online owned machine; silent when readiness cannot be read. */
export function ModelStatusLine({ machineId }: { machineId: string }) {
  const { client, snapshot } = useApp();
  const machine = snapshot.machines.find(item => item.id === machineId);
  const readable = !!machine && machine.status === 'online' && machine.ownerUserId === snapshot.user.id
    && snapshot.member.role === 'owner' && snapshot.workspace.ownerUserId === snapshot.user.id;
  const api = useMemo(() => providerApi(client, machineId), [client, machineId]);
  const query = useQuery(`model-status-line:${snapshot.workspace.id}:${readable ? machineId : 'none'}`, async () => {
    if (!readable) return null;
    try { return (await api.status()).readiness; }
    catch { return null; }
  });
  const state = query.data?.state;
  if (!state) return null;
  return <p className="muted small">
    <strong>{state === 'verified' ? 'Model: Verified' : state === 'saved' ? 'Model: Saved' : 'Model: Not connected'}</strong> on {machine?.name}
  </p>;
}

/**
 * "Connect a model on <machine>" (spec §2.5): auto-check the selected execution target, offer detected
 * logins first with explicit consent, then device sign-in, API key and Skip. Every request keeps its own
 * nonce; nothing is retried after an uncertain response. `ignoreSkip` shows the connect options without
 * forgetting a remembered skip, so closing the panel leaves the reminder in place.
 */
export function ModelReadinessPanel({ machineId, onReadyChange, ignoreSkip = false }: { machineId: string; onReadyChange?: (ready: boolean) => void; ignoreSkip?: boolean }) {
  const { client, snapshot, online } = useApp();
  const machine = snapshot.machines.find(item => item.id === machineId);
  const workspaceOwner = snapshot.member.role === 'owner' && snapshot.workspace.ownerUserId === snapshot.user.id;
  const machineOwner = !!machine && machine.ownerUserId === snapshot.user.id;
  // No gate when the caller cannot read provider management, or the machine is not online.
  const unsupported = !machineId || !workspaceOwner || !machineOwner || machine?.status !== 'online';

  const api = useMemo(() => providerApi(client, machineId), [client, machineId]);
  const [skipped, setSkipped] = useState(() => (machineId ? getModelReadinessSkip(snapshot.workspace.id, machineId) : false));
  const [checking, setChecking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState('');
  const [form, setForm] = useState<'none' | 'api_key' | 'device'>('none');
  const [keyProviderId, setKeyProviderId] = useState('');
  const [login, setLogin] = useState<ProviderDeviceLogin | null>(null);
  const [deviceIntent, setDeviceIntent] = useState<Extract<ProviderIntent, { kind: 'device' }> | null>(null);
  const mounted = useRef(true);
  const busyRef = useRef(false);
  const autoChecked = useRef<Record<string, true>>({});
  useLayoutEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);

  const query = useQuery(`model-readiness:${snapshot.workspace.id}:${machineId || 'none'}`, async () => {
    if (unsupported) return null;
    return api.status();
  });
  const management = query.data ?? null;
  const readiness = management?.readiness ?? null;
  const host = machine?.name || management?.target.hostname || 'this computer';
  const accept = query.setData;

  useEffect(() => {
    setSkipped(machineId ? getModelReadinessSkip(snapshot.workspace.id, machineId) : false);
    setForm('none'); setLogin(null); setDeviceIntent(null); setMessage('');
  }, [snapshot.workspace.id, machineId]);

  const honouredSkip = skipped && !ignoreSkip;
  const ready = unsupported
    ? true
    : query.error
      ? true
      : !management
        ? false
        : management.readiness === null
          ? true
          : isReadyState(management) || honouredSkip;

  const readyCallback = useRef(onReadyChange); readyCallback.current = onReadyChange;
  useEffect(() => { readyCallback.current?.(ready); }, [ready]);

  // Auto-advance (§2.5): one automatic non-generating check per target when a credential may exist.
  useEffect(() => {
    if (unsupported || !management || management.readiness === null || !online) return;
    const key = `${machineId}:${management.target.id}`;
    if (autoChecked.current[key] || busyRef.current) return;
    const state = management.readiness.state;
    const credentialPresent = management.providers.some(provider => provider.configured);
    if (state === 'verified') return;
    if (state !== 'saved' && !(state === 'action_required' && credentialPresent)) return;
    autoChecked.current[key] = true;
    busyRef.current = true; setChecking(true);
    api.check({ targetId: management.target.id, clientNonce: nonce() })
      .then(result => { if (mounted.current) accept(result.management); })
      .catch(() => { /* A failed check leaves the last known state; nothing is retried. */ })
      .finally(() => { busyRef.current = false; if (mounted.current) setChecking(false); });
  }, [unsupported, management, machineId, online, api, accept]);

  /**
   * After any connect action: check this provider, set the default when it is unset or its own readiness
   * is not ready, then check the default. A provider-scoped check describes that provider only, so it can
   * never stand in for the current default's readiness — that comes from the last default-scoped listing.
   */
  const connectSequence = useCallback(async (providerId: string) => {
    const current = query.data;
    if (!current) return;
    const checked = await api.check({ targetId: current.target.id, clientNonce: nonce(), providerId });
    const defaultReady = !!current.default.providerId && isReadyState(current);
    const suggested = checked.readiness.suggestedModelId;
    if (!defaultReady && suggested) {
      await api.changeDefault({ targetId: current.target.id, clientNonce: nonce(), providerId, modelId: suggested });
    }
    const confirmed = await api.check({ targetId: current.target.id, clientNonce: nonce() });
    if (!mounted.current) return;
    accept(confirmed.management);
    setModelReadinessSkip(snapshot.workspace.id, machineId, false);
    setSkipped(false); setForm('none'); setLogin(null); setDeviceIntent(null);
  }, [api, query.data, accept, snapshot.workspace.id, machineId]);

  async function run(operation: () => Promise<void>) {
    if (busyRef.current || !online) return;
    busyRef.current = true; setBusy(true); setMessage('');
    try { await operation(); }
    catch (failure) { if (mounted.current) setMessage(providerFailure(failure).message); }
    finally { busyRef.current = false; if (mounted.current) setBusy(false); }
  }

  // Device sign-in polling while this view is visible and foreground.
  useEffect(() => {
    if (!login || !deviceIntent || !['starting', 'pending'].includes(login.status) || !online) return;
    const deadline = Math.min(login.expiresAtMs ?? deviceIntent.startedAtMs + 900000, deviceIntent.startedAtMs + 900000);
    const remaining = deadline - Date.now();
    if (remaining <= 0) { setLogin(null); setMessage('The displayed sign-in code expired. Start a new sign-in.'); return; }
    const timer = window.setTimeout(() => {
      if (document.visibilityState === 'hidden') return;
      void run(async () => {
        const next: Extract<ProviderIntent, { kind: 'device' }> = { ...deviceIntent, action: 'poll' };
        const result = checkedDeviceLogin(await api.device(next), next);
        if (!mounted.current) return;
        if (result.status === 'starting' || result.status === 'pending') { setLogin(result); return; }
        setLogin(null); setDeviceIntent(null);
        if (result.status === 'completed') await connectSequence('openai_codex');
        else setMessage('Sign-in did not complete. Start a new sign-in, or paste an API key.');
      });
    }, Math.min(remaining, login.pollIntervalMs || 1000));
    return () => window.clearTimeout(timer);
  }, [login, deviceIntent, online, api, connectSequence]);

  function skip() {
    setModelReadinessSkip(snapshot.workspace.id, machineId, true);
    setSkipped(true); setForm('none'); setLogin(null); setDeviceIntent(null);
  }

  if (!machineId) return null;
  if (unsupported || query.error || (management && management.readiness === null)) {
    return <section className="model-readiness panel stack" aria-label="Model readiness"><p className="muted small">Model status unavailable</p></section>;
  }
  if (!management) {
    return <section className="model-readiness panel stack" aria-label="Model readiness"><Loading label={`Loading model status on ${host}…`}/></section>;
  }

  const detected = management.detected ?? [];
  const codexDetected = detected.find(item => item.source === 'codex_cli');
  const envDetected = detected.flatMap(item => item.source === 'environment' ? [item] : []);
  const keyProviders = management.providers.filter(provider => provider.methods.includes('api_key'));
  const deviceProvider = management.providers.find(provider => provider.id === 'openai_codex' && provider.methods.includes('device_code'));
  const keyProvider = keyProviders.find(provider => provider.id === keyProviderId) || keyProviders[0];
  const actionable = !!readiness && !isReadyState(management);

  return <section className="model-readiness panel stack" aria-label="Model readiness">
    <div className="row spread">
      <h3 className="model-readiness-title"><Sparkles size={15} aria-hidden="true"/>Model on {host}</h3>
      {readiness && <Badge tone={readinessBadgeTone(readiness.state)}>{readinessStateLabels[readiness.state]}</Badge>}
    </div>

    {checking && <p className="model-readiness-checking small muted" role="status">
      <span className="spinner" aria-hidden="true"/>
      {readiness?.providerId === 'openai_codex'
        ? 'Checking your ChatGPT login with OpenAI — no message is sent'
        : 'Checking this model with its provider — no message is sent'}
    </p>}

    {!!message && <p className="error-notice" role="alert">{message}</p>}

    {!!readiness && isReadyState(management) && !checking && <p className="small muted">
      {`${readiness.providerId || 'Default provider'} · ${readiness.modelId || 'default model'} — ${readinessStateSummaries[readiness.state]}`}
      {readiness.reason ? ` (${readinessReasonLabels[readiness.reason]})` : ''}
      {readiness.checkedAtMs ? ` Checked ${formatTime(readiness.checkedAtMs)}.` : ''}
    </p>}

    {actionable && honouredSkip && <div className="row spread model-readiness-skipped">
      <span className="small muted">Skipped for now — replies on {host} will fail until a model is connected.</span>
      <button type="button" disabled={busy} onClick={() => { setModelReadinessSkip(snapshot.workspace.id, machineId, false); setSkipped(false); }}>Connect a model</button>
    </div>}

    {actionable && !honouredSkip && <div className="stack model-readiness-connect">
      <p className="small muted">
        Connect a model on {host} before this Bot can reply.
        {readiness?.reason ? ` ${readinessReasonLabels[readiness.reason]}.` : ''}
      </p>

      {codexDetected && form === 'none' && <div className="model-readiness-detected stack">
        <div className="row spread"><strong>Codex CLI ChatGPT login found on {host}</strong><Badge tone="good">Detected</Badge></div>
        <p className="consent-notice">
          Copy your Codex CLI ChatGPT login on {host} into Lemon. Your <code>~/.codex/auth.json</code> is not changed. Lemon and the Codex CLI will share this login; if either refreshes it, the other may need to sign in again. Use <em>Sign in with ChatGPT</em> to give Lemon its own login instead.
        </p>
        <button type="button" className="primary" disabled={busy || !online} onClick={() => void run(async () => {
          await api.importLogin('openai_codex', { targetId: management.target.id, clientNonce: nonce(), source: 'codex_cli', consent: 'copy_login' });
          await connectSequence('openai_codex');
        })}>Use your Codex CLI login</button>
      </div>}

      {form === 'none' && envDetected.map(item => <div className="model-readiness-detected stack" key={`${item.providerId}:${item.variable}`}>
        <div className="row spread"><strong>{item.variable} found on {host}</strong><Badge tone="muted">Detected</Badge></div>
        <p className="small muted">Lemon can use the provider credential already present in {host}’s process environment.</p>
        <button type="button" disabled={busy || !online} onClick={() => void run(() => connectSequence(item.providerId))}>Use {item.variable} found on {host}</button>
      </div>)}

      {form === 'device' && login && <div className="model-readiness-device stack" role="status">
        <div className="row spread"><strong>Sign in with ChatGPT</strong><Badge tone="warning">Waiting for sign-in</Badge></div>
        <p className="small muted">Sign in using your normal browser. Your provider account or organization may need device-code sign-in enabled.</p>
        <Field label="User code"><code>{login.userCode}</code></Field>
        {!!login.expiresAtMs && <p className="small muted">Expires {formatTime(login.expiresAtMs)}.</p>}
        <div className="row">
          {!!login.verificationUrl && <a className="button primary" href={login.verificationUrl} target="_blank" rel="noopener noreferrer" referrerPolicy="no-referrer">Open sign-in in browser</a>}
          <button type="button" disabled={busy} onClick={() => void run(async () => {
            if (!deviceIntent) return;
            const next: Extract<ProviderIntent, { kind: 'device' }> = { ...deviceIntent, action: 'cancel' };
            await api.device(next);
            if (mounted.current) { setLogin(null); setDeviceIntent(null); setForm('none'); }
          })}>Cancel sign-in</button>
        </div>
      </div>}

      {/* The Create Bot sheet is itself a form, so the write-only key form is dialogged out of that tree. */}
      {form === 'api_key' && keyProvider && createPortal(<div className="modal-backdrop" onKeyDown={event => { if (event.key === 'Escape' && !busy) setForm('none'); }}>
        <section className="modal stack" role="dialog" aria-modal="true" aria-label="Paste an API key">
          {keyProviders.length > 1 && <Field label="Provider">
            <select value={keyProvider.id} onChange={event => setKeyProviderId(event.target.value)}>
              {keyProviders.map(provider => <option key={provider.id} value={provider.id}>{provider.displayName}</option>)}
            </select>
          </Field>}
          <SecureApiKeyForm provider={keyProvider} management={management} machineId={machineId} disabled={busy || !online}
            cancel={() => setForm('none')}
            submit={value => run(async () => {
              await api.key(keyProvider.id, { targetId: management.target.id, clientNonce: nonce(), value });
              await connectSequence(keyProvider.id);
            })}/>
        </section>
      </div>, document.body)}

      {form === 'none' && <div className="row model-readiness-options">
        {!!deviceProvider && <button type="button" disabled={busy || !online} onClick={() => void run(async () => {
          const intent: Extract<ProviderIntent, { kind: 'device' }> = { kind: 'device', providerId: 'openai_codex', targetId: management.target.id, clientNonce: nonce(), pollNonce: nonce(), cancelNonce: nonce(), action: 'start', startedAtMs: Date.now() };
          setDeviceIntent(intent);
          const started = checkedDeviceLogin(await api.device(intent), intent);
          if (!mounted.current) return;
          setLogin(started); setForm('device');
        })}><LogIn size={14} aria-hidden="true"/>Sign in with ChatGPT (device code)</button>}
        {!!keyProviders.length && <button type="button" disabled={busy || !online} onClick={() => { setKeyProviderId(keyProviders[0].id); setForm('api_key'); }}>
          <Key size={14} aria-hidden="true"/>Paste an API key
        </button>}
        {!ignoreSkip && <button type="button" className="ghost-button" disabled={busy} onClick={skip}>Skip for now</button>}
      </div>}
    </div>}
  </section>;
}

/**
 * The same panel inside a dialog, opened from the conversation's non-blocking banner. The remembered skip
 * is kept until a connect action actually succeeds, so closing the dialog leaves the reminder in place.
 */
export function ModelReadinessModal({ machineId, onClose, onReady }: { machineId: string; onClose: () => void; onReady?: () => void }) {
  const reported = useRef(false);
  return <div className="modal-backdrop" onKeyDown={event => { if (event.key === 'Escape') onClose(); }}>
    <section className="modal stack" role="dialog" aria-modal="true" aria-label="Connect a model">
      <div className="row spread">
        <h2>Connect a model</h2>
        <button type="button" className="ghost-circle" aria-label="Close" onClick={onClose}><X size={16}/></button>
      </div>
      <ModelReadinessPanel machineId={machineId} ignoreSkip onReadyChange={value => { if (value && !reported.current) { reported.current = true; onReady?.(); } }}/>
      <div className="row"><button type="button" onClick={onClose}>Close</button></div>
    </section>
  </div>;
}
