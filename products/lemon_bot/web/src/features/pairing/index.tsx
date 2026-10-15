import { useEffect, useRef, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { LemonBotError, nonce, parsePairUrl, type AuthSession, type Device, type Mutation, type Pairing, type PairingApprove, type PairingDeny, type PairingIssued, type PairingStart } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, ConfirmDialog, EmptyState, ErrorNotice, Field, Loading, PageHeader, formatTime, useQuery } from '../../ui';
import { collect } from '../bots/shared';
import './pairing.css';

interface PairingState { pairings: Pairing[]; devices: Device[]; sessions: AuthSession[] }
interface PairingIntent { kind: 'create' | 'approve' | 'deny' | 'revoke'; clientNonce: string; resourceId: string | null; dispatchedAtMs: number }
const pairingLabels: Record<Pairing['status'], string> = { waiting: 'Waiting for your iPhone', pending_approval: 'Waiting for approval', approved: 'Approved — finish on your iPhone', consumed: 'Connected', denied: 'Denied', expired: 'Expired' };

export function PairingScreen() {
  const { client, snapshot, online, navigate } = useApp();
  const storageKey = `lemonbot.pairing-intent:${client.baseUrl}:${snapshot.workspace.id}:${snapshot.user.id}`;
  const [intent, setIntent] = useState<PairingIntent | null>(() => {
    try {
      const value: unknown = JSON.parse(sessionStorage.getItem(storageKey) || 'null');
      if (!value || typeof value !== 'object' || !('kind' in value) || !('clientNonce' in value) || !('resourceId' in value) || !('dispatchedAtMs' in value)) return null;
      if ((value.kind !== 'create' && value.kind !== 'approve' && value.kind !== 'deny' && value.kind !== 'revoke') || typeof value.clientNonce !== 'string' || value.clientNonce.length > 128
        || (value.resourceId !== null && typeof value.resourceId !== 'string') || typeof value.dispatchedAtMs !== 'number' || !Number.isFinite(value.dispatchedAtMs)) return null;
      return { kind: value.kind, clientNonce: value.clientNonce, resourceId: value.resourceId, dispatchedAtMs: value.dispatchedAtMs };
    } catch { return null; }
  });
  const intentRef = useRef(intent); intentRef.current = intent;
  const [issued, setIssued] = useState<PairingIssued | null>(null);
  const [revoking, setRevoking] = useState<Device>();
  const [busy, setBusy] = useState(false); const busyRef = useRef(false);
  const [error, setError] = useState<unknown>(); const [notice, setNotice] = useState('');
  const [now, setNow] = useState(Date.now());
  const watched = useRef(new Set<string>());
  if (intent?.resourceId && intent.kind !== 'revoke') watched.current.add(intent.resourceId);
  const query = useQuery<PairingState>(`pairings:${storageKey}`, async () => {
    const [pending, devices, sessions] = await Promise.all([
      client.call('GET /pairings'),
      collect(cursor => client.call('GET /devices', { query: { cursor, limit: 200 } })),
      collect(cursor => client.call('GET /auth/sessions', { query: { cursor, limit: 200 } })),
    ]);
    for (const item of pending) watched.current.add(item.id);
    const completed = await Promise.all([...watched.current].filter(id => !pending.some(item => item.id === id)).map(id => client.call('GET /pairings/:id', { params: { id } })));
    return { pairings: [...pending, ...completed].sort((a, b) => b.createdAtMs - a.createdAtMs), devices, sessions };
  });
  const pollBusy = useRef(false);
  useEffect(() => {
    const clock = window.setInterval(() => setNow(Date.now()), 1000);
    const poll = window.setInterval(() => {
      if (!navigator.onLine || pollBusy.current) return;
      pollBusy.current = true;
      void query.reload().catch(() => undefined).finally(() => { pollBusy.current = false; });
    }, 3000);
    return () => { clearInterval(clock); clearInterval(poll); };
  }, [query.reload]);
  useEffect(() => {
    if (issued && (issued.pairing.expiresAtMs <= now || query.data?.pairings.some(item => item.id === issued.pairing.id && item.status !== 'waiting'))) setIssued(null);
  }, [issued, query.data, now]);
  useEffect(() => {
    if (!intent || busy || !query.data || query.error) return;
    const pairing = query.data.pairings.find(item => item.id === intent.resourceId);
    const terminal = pairing && ['approved', 'consumed', 'denied', 'expired'].includes(pairing.status);
    const revoked = intent.kind === 'revoke' && !query.data.devices.some(item => item.id === intent.resourceId);
    if ((intent.kind !== 'revoke' && terminal) || revoked) {
      sessionStorage.removeItem(storageKey); intentRef.current = null; setIntent(null); setError(undefined);
      setNotice(revoked ? 'This device no longer has access.' : pairingLabels[pairing!.status]);
    }
  }, [intent, busy, query.data, query.error, storageKey]);

  async function dispatch(next: PairingIntent, action: () => Promise<void>) {
    if (!online || busyRef.current || intentRef.current) return;
    busyRef.current = true; setBusy(true); setError(undefined); setNotice('');
    let dispatched = false;
    try {
      // Only safe intent metadata survives navigation. QR/claim/session secrets never enter this journal.
      sessionStorage.setItem(storageKey, JSON.stringify(next)); intentRef.current = next; setIntent(next);
      dispatched = true;
      await action();
      sessionStorage.removeItem(storageKey); intentRef.current = null; setIntent(null);
    } catch (failure) {
      setError(failure);
      if (!dispatched || (failure instanceof LemonBotError && !failure.outcomeUnknown)) {
        sessionStorage.removeItem(storageKey); intentRef.current = null; setIntent(null);
      } else if (failure instanceof LemonBotError && next.kind === 'create' && failure.resourceIds.length === 1) {
        const saved = { ...next, resourceId: failure.resourceIds[0]! };
        watched.current.add(saved.resourceId); intentRef.current = saved; setIntent(saved); sessionStorage.setItem(storageKey, JSON.stringify(saved));
      }
    } finally { busyRef.current = false; setBusy(false); }
    // Observation is always GET-only, even after an uncertain mutation.
    void query.reload().catch(() => undefined);
  }

  function acceptIssued(result: PairingIssued) {
    watched.current.add(result.pairing.id);
    const link = parsePairUrl(result.pairUrl);
    if (link.workspaceId !== snapshot.workspace.id || link.workspaceId !== result.pairing.workspaceId || link.backendUrl !== result.pairing.backendUrl
      || result.pairing.ownerUserId !== snapshot.user.id) {
      throw new Error('The backend returned an inconsistent pairing receipt. The link was not displayed; read current pairing state before continuing.');
    }
    if (result.pairing.status === 'waiting' && result.pairing.expiresAtMs > Date.now()) {
      setIssued(result); setNotice('Scan this one-use QR with Lemon Bot on your iPhone, then compare the verification code below.');
    } else {
      setIssued(null); setNotice(`${pairingLabels[result.pairing.status]}. Used or expired QR codes can’t be reused.`);
    }
  }

  async function create() {
    const body: PairingStart = { clientNonce: nonce() };
    await dispatch({ kind: 'create', clientNonce: body.clientNonce, resourceId: null, dispatchedAtMs: Date.now() }, async () => {
      acceptIssued(await client.call('POST /pairings', { body }));
    });
  }

  async function recoverIssuance() {
    const original = intentRef.current;
    if (!online || busyRef.current || original?.kind !== 'create') return;
    busyRef.current = true; setBusy(true); setError(undefined);
    const body: PairingStart = { clientNonce: original.clientNonce };
    try {
      // Explicit owner reconciliation reuses the SAME issuance nonce; never a new pairing or automatic retry.
      const result = await client.call('POST /pairings', { body });
      watched.current.add(result.pairing.id);
      const current = await client.call('GET /pairings/:id', { params: { id: result.pairing.id } });
      acceptIssued({ pairing: current, pairUrl: result.pairUrl });
      sessionStorage.removeItem(storageKey); intentRef.current = null; setIntent(null);
    } catch (failure) {
      setError(failure);
      if (failure instanceof LemonBotError && failure.code === 'expired') {
        sessionStorage.removeItem(storageKey); intentRef.current = null; setIntent(null);
        setNotice('This QR has expired. Create a new QR code to pair your iPhone.');
      }
    } finally { busyRef.current = false; setBusy(false); }
    void query.reload().catch(() => undefined);
  }

  async function decide(pairing: Pairing, decision: 'approve' | 'deny') {
    if (pairing.expiresAtMs <= Date.now() || pairing.status !== 'pending_approval') return;
    if (decision === 'approve') {
      if (!pairing.verificationCode) return;
      const body: PairingApprove = { clientNonce: nonce(), revision: pairing.revision, verificationCode: pairing.verificationCode };
      await dispatch({ kind: decision, clientNonce: body.clientNonce, resourceId: pairing.id, dispatchedAtMs: Date.now() }, async () => {
        const result = await client.call('POST /pairings/:id/approve', { params: { id: pairing.id }, body });
        query.setData(previousState(result)); setNotice('Device approved. The iPhone must receive its own session before the pairing expires.');
      });
    } else {
      const body: PairingDeny = { clientNonce: nonce(), revision: pairing.revision };
      await dispatch({ kind: decision, clientNonce: body.clientNonce, resourceId: pairing.id, dispatchedAtMs: Date.now() }, async () => {
        const result = await client.call('POST /pairings/:id/deny', { params: { id: pairing.id }, body });
        query.setData(previousState(result)); setNotice('Pairing denied. This QR cannot connect a device.');
      });
    }
  }

  function previousState(pairing: Pairing): PairingState {
    const current = query.data;
    return { pairings: [...(current?.pairings || []).filter(item => item.id !== pairing.id), pairing], devices: current?.devices || [], sessions: current?.sessions || [] };
  }

  async function revoke(device: Device) {
    const body: Mutation = { clientNonce: nonce() };
    await dispatch({ kind: 'revoke', clientNonce: body.clientNonce, resourceId: device.id, dispatchedAtMs: Date.now() }, async () => {
      await client.call('DELETE /devices/:id', { params: { id: device.id }, body });
      setNotice('This device no longer has access. Checking the device list.');
    });
  }

  const disabled = !online || busy || !!intent || !query.data || !!query.error;
  const current = issued && query.data?.pairings.find(item => item.id === issued.pairing.id);
  const showQr = issued && (!current || current.status === 'waiting') && issued.pairing.expiresAtMs > now;
  const loopback = issued && ['localhost', '127.0.0.1', '[::1]'].includes(new URL(issued.pairing.backendUrl).hostname);
  return <section className="page stack">
    <PageHeader title="Connect iPhone" eyebrow="Your workspace · your own device"><button disabled={query.loading} onClick={() => void query.reload().catch(() => undefined)}>Refresh</button></PageHeader>
    <section className="panel stack"><h2>Connect once, stay connected</h2><p>Your iPhone gets its own sign-in and stays connected until you revoke access. Your browser stays signed in.</p><p className="muted">Your iPhone must be able to reach this Lemon Bot address, for example through Tailscale. Localhost only works with the iOS Simulator.</p><details><summary>Setup help</summary><p>Ask your administrator to configure a reachable HTTPS address for Lemon Bot. Tailscale Serve can provide one. Both devices need access to that address before pairing.</p></details><button className="primary" disabled={disabled || !!showQr} onClick={() => void create()}>{busy && intent?.kind === 'create' ? 'Creating QR code…' : 'Create QR code'}</button></section>
    <ErrorNotice error={error}/><ErrorNotice error={query.error}/>
    {notice && <p className="panel" role="status">{notice}</p>}
    {intent && !busy && <section className="error-notice stack" role="alert"><h2>{intent.kind === 'create' ? 'We couldn’t confirm the QR was created.' : 'We couldn’t confirm this change.'}</h2><p>Nothing was sent again or approved automatically. Check the current status before trying again.</p>{intent.kind === 'create' && <><p>You can check the QR you started during its original five-minute lifetime. This does not create another QR or extend its expiry.</p><button disabled={!online || busy} onClick={() => void recoverIssuance()}>Check the QR I started</button></>}<button disabled={query.loading} onClick={() => void query.reload().catch(() => undefined)}>Check status</button><details><summary>Details</summary><p>Reference: <code>{intent.clientNonce}</code>{intent.resourceId && <> · Resource: <code>{intent.resourceId}</code></>}</p><button onClick={() => void navigator.clipboard.writeText(intent.clientNonce)}>Copy reference</button></details></section>}
    {issued && showQr && <section className="panel pairing-issued stack"><h2>On your iPhone, choose “Scan QR code”</h2><div className="pairing-qr"><QRCodeSVG value={issued.pairUrl} size={256} level="M" marginSize={4} title="Lemon Bot iPhone pairing QR code"/></div><dl><dt>Workspace</dt><dd>{issued.pairing.clusterName}</dd><dt>Lemon Bot address</dt><dd><code>{issued.pairing.backendUrl}</code></dd><dt>Expires</dt><dd>{formatTime(issued.pairing.expiresAtMs)} · {Math.max(0, Math.ceil((issued.pairing.expiresAtMs - now) / 1000))} seconds left</dd></dl>{loopback && <p className="error-notice">This address only works on this computer or the iOS Simulator, not a physical iPhone. Ask your administrator for a reachable HTTPS address.</p>}<p className="muted small">This QR code works once and expires after five minutes. Compare the code shown on both devices before approving.</p></section>}
    {query.loading && !query.data && <Loading/>}
    {query.data && <section className="stack"><h2>Pairing requests</h2>{query.data.pairings.length ? query.data.pairings.map(pairing => <PairingRequest key={pairing.id} pairing={pairing} now={now} disabled={disabled} decide={decide} create={create}/>) : <EmptyState title="No pending pairing requests">Create a QR code, scan it in Lemon Bot for iOS, then return here to compare the code and approve your iPhone.</EmptyState>}</section>}
    {query.data && <section className="panel stack"><h2>Your iPhones</h2>{query.data.devices.filter(device => device.platform === 'ios').map(device => {
      const sessions = query.data!.sessions.filter(session => session.deviceId === device.id);
      return <article className="card stack" key={device.id}><div className="row spread"><strong>{device.name}</strong><Badge>iOS · {device.appVersion}</Badge></div><p>Last seen: {formatTime(device.lastSeenAtMs)}</p>{sessions.length ? <ul>{sessions.map(session => <li key={session.id}>Session: {session.expiresAtMs === null ? 'Until revoked' : `Expires ${formatTime(session.expiresAtMs)}`} · Last seen {formatTime(session.lastSeenAtMs)}</li>)}</ul> : <p className="muted">No active device session reported.</p>}<button className="danger" disabled={disabled} onClick={() => setRevoking(device)}>Revoke this iPhone</button></article>;
    })}{!query.data.devices.some(device => device.platform === 'ios') && <p className="muted">No iPhone is registered on your account.</p>}<button onClick={() => navigate({ screen: 'settings.account' })}>Manage all account sessions and devices</button></section>}
    {revoking && <ConfirmDialog title={`Revoke ${revoking.name}?`} disabled={disabled} onCancel={() => setRevoking(undefined)} onConfirm={async () => { await revoke(revoking); if (!intentRef.current) setRevoking(undefined); }}><p>Its sessions stop working on this Lemon Bot. The iPhone has to pair again.</p><ErrorNotice error={error}/></ConfirmDialog>}
  </section>;
}

function PairingRequest({ pairing, now, disabled, decide, create }: { pairing: Pairing; now: number; disabled: boolean; decide: (pairing: Pairing, decision: 'approve' | 'deny') => Promise<void>; create: () => Promise<void> }) {
  const [confirmation, setConfirmation] = useState('');
  useEffect(() => { setConfirmation(''); }, [pairing.verificationCode, pairing.revision]);
  const expired = pairing.expiresAtMs <= now;
  const pending = pairing.status === 'pending_approval' && !expired;
  return <article className="panel stack">
    <div className="row spread"><h3>{pairing.deviceName || 'Waiting for an iPhone to scan'}</h3><Badge tone={pending ? 'warning' : pairing.status === 'consumed' ? 'good' : 'muted'}>{expired && ['waiting', 'pending_approval'].includes(pairing.status) ? 'Expired' : pairingLabels[pairing.status]}</Badge></div>
    <p>{pairing.clusterName} · <code>{pairing.backendUrl}</code></p><p>Expires: {formatTime(pairing.expiresAtMs)}</p>
    {pending && <>
      <p>Compare this code with the iPhone that you requested to connect. Approve only your own device.</p>
      <strong className="pairing-verification" aria-label={`Verification code ${pairing.verificationCode}`}>{pairing.verificationCode}</strong>
      <Field label="Enter the matching code shown on your iPhone" hint="If the codes don’t match, deny this request and scan a new QR code."><input value={confirmation} inputMode="numeric" pattern="[0-9]{6}" maxLength={6} autoComplete="off" onChange={event => setConfirmation(event.target.value.replace(/\D/g, ''))}/></Field>
      <button className="primary" title="Type the 6-digit code from your iPhone first." disabled={disabled || !pairing.verificationCode || confirmation !== pairing.verificationCode} onClick={() => void decide(pairing, 'approve')}>Approve this iPhone</button>
      <button className="danger" disabled={disabled} onClick={() => void decide(pairing, 'deny')}>Deny</button>
    </>}
    {pairing.status === 'waiting' && !expired && <p>The unused QR expires automatically. Once your iPhone requests connection, you can approve or deny that device.</p>}
    {pairing.status === 'approved' && <p>The device is approved. The phone must complete before this request expires; approval is not proof that the phone received its credential.</p>}
    {pairing.status === 'consumed' && <p>The phone completed this pairing. Its device-bound session remains valid until revoked.</p>}
    {pairing.status === 'denied' && <p>This request was denied and cannot connect.</p>}
    {(expired || pairing.status === 'expired') && pairing.status !== 'consumed' && pairing.status !== 'denied' && <><p>This QR code has expired. Create a new one to pair.</p><button disabled={disabled} onClick={() => void create()}>Create a new QR code</button></>}
  </article>;
}
