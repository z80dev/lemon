import { useEffect, useRef, useState } from 'react';
import { QRCodeSVG } from 'qrcode.react';
import { LemonBotError, nonce, parsePairUrl, type AuthSession, type Device, type Mutation, type Pairing, type PairingApprove, type PairingDeny, type PairingIssued, type PairingStart } from '@lemon-bot/sdk';
import { useApp } from '../../app';
import { Badge, EmptyState, ErrorNotice, Field, Loading, PageHeader, formatTime, useQuery } from '../../ui';
import { collect } from '../bots/shared';
import './pairing.css';

interface PairingState { pairings: Pairing[]; devices: Device[]; sessions: AuthSession[] }
interface PairingIntent { kind: 'create' | 'approve' | 'deny' | 'revoke'; clientNonce: string; resourceId: string | null; dispatchedAtMs: number }

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
      setNotice(revoked ? 'Device revocation confirmed by the authoritative device list.' : `The pairing is ${pairing!.status.replaceAll('_', ' ')}. No mutation was repeated.`);
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
      setIssued(null); setNotice(`The original request is ${result.pairing.status.replaceAll('_', ' ')}. A consumed or expired QR is not reusable.`);
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
        setNotice('The original one-use issuance expired. Review a new pairing request; no credential was recreated.');
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
    if (!window.confirm(`Revoke ${device.name}? Its device-bound sessions lose access to this cluster. The iPhone will need to pair again.`)) return;
    const body: Mutation = { clientNonce: nonce() };
    await dispatch({ kind: 'revoke', clientNonce: body.clientNonce, resourceId: device.id, dispatchedAtMs: Date.now() }, async () => {
      await client.call('DELETE /devices/:id', { params: { id: device.id }, body });
      setNotice('Device revocation acknowledged. Refreshing the authoritative session and device lists.');
    });
  }

  const disabled = !online || busy || !!intent || !query.data || !!query.error;
  const current = issued && query.data?.pairings.find(item => item.id === issued.pairing.id);
  const showQr = issued && (!current || current.status === 'waiting') && issued.pairing.expiresAtMs > now;
  const loopback = issued && ['localhost', '127.0.0.1', '[::1]'].includes(new URL(issued.pairing.backendUrl).hostname);
  return <section className="page stack">
    <PageHeader title="Connect iPhone" eyebrow="Your cluster · your own device"><button disabled={query.loading} onClick={() => void query.reload().catch(() => undefined)}>Refresh pairing state</button></PageHeader>
    <section className="panel stack"><h2>One approval, persistent connection</h2><p>The iPhone receives its own device-bound session and reconnects until you revoke it. Your browser stays signed in with its normal product session.</p><p className="muted">Configure the backend's reachable HTTPS public URL, usually with Tailscale Serve. Desktop and iPhone must already be able to reach it. This screen does not provision Tailscale or verify phone reachability. Localhost HTTP is only for same-machine development or Simulator, not a physical iPhone.</p><button className="primary" disabled={disabled || !!showQr} onClick={() => void create()}>{busy && intent?.kind === 'create' ? 'Creating one-use QR…' : 'Create one-use pairing QR'}</button></section>
    <ErrorNotice error={error}/><ErrorNotice error={query.error}/>
    {notice && <p className="panel" role="status">{notice}</p>}
    {intent && !busy && <section className="error-notice stack" role="alert"><h2>Keep this fixed intent</h2><p>The {intent.kind} receipt is not confirmed. No action is automatically repeated. Read current state before another consequential action.</p><p className="small">Intent nonce: <code>{intent.clientNonce}</code>{intent.resourceId && <> · Resource: <code>{intent.resourceId}</code></>}</p>{intent.kind === 'create' && <><p>The safe pairing list contains no QR secret. An empty list is not proof the mutation did not happen. You can explicitly request the original issuance receipt with this same nonce until its original five-minute deadline. This never creates another device/session, extends expiry or makes a consumed QR reusable.</p><button disabled={!online || busy} onClick={() => void recoverIssuance()}>Reconcile original QR issuance · same nonce</button></>}<button disabled={query.loading} onClick={() => void query.reload().catch(() => undefined)}>Read authoritative pairing/device state</button></section>}
    {issued && showQr && <section className="panel pairing-issued stack"><h2>Scan with Lemon Bot for iOS</h2><div className="pairing-qr"><QRCodeSVG value={issued.pairUrl} size={256} level="M" marginSize={4} title="One-use Lemon Bot iPhone pairing QR"/></div><dl><dt>Cluster</dt><dd>{issued.pairing.clusterName}</dd><dt>Backend origin</dt><dd><code>{issued.pairing.backendUrl}</code></dd><dt>Expires</dt><dd>{formatTime(issued.pairing.expiresAtMs)} · {Math.max(0, Math.ceil((issued.pairing.expiresAtMs - now) / 1000))} seconds left</dd></dl>{loopback && <p className="error-notice">This QR points to localhost. It cannot connect a physical iPhone to this desktop. Configure a reachable HTTPS public URL before pairing your phone.</p>}<p className="muted small">One-use, five-minute link. No browser session, operator token or permanent credential is in the QR. The link is held only in this screen's memory, not saved or sent to an external QR service.</p></section>}
    {query.loading && !query.data && <Loading/>}
    {query.data && <section className="stack"><h2>Pairing requests</h2>{query.data.pairings.length ? query.data.pairings.map(pairing => <PairingRequest key={pairing.id} pairing={pairing} now={now} disabled={disabled} decide={decide}/>) : <EmptyState title="No pending pairing requests">Create a QR, scan it in Lemon Bot for iOS, then return here to verify and approve your own device.</EmptyState>}</section>}
    {query.data && <section className="panel stack"><h2>Your iPhones</h2>{query.data.devices.filter(device => device.platform === 'ios').map(device => {
      const sessions = query.data!.sessions.filter(session => session.deviceId === device.id);
      return <article className="card stack" key={device.id}><div className="row spread"><strong>{device.name}</strong><Badge>iOS · {device.appVersion}</Badge></div><p>Last seen: {formatTime(device.lastSeenAtMs)}</p>{sessions.length ? <ul>{sessions.map(session => <li key={session.id}>Session: {session.expiresAtMs === null ? 'Until revoked' : `Expires ${formatTime(session.expiresAtMs)}`} · Last seen {formatTime(session.lastSeenAtMs)}</li>)}</ul> : <p className="muted">No active device session reported.</p>}<button className="danger" disabled={disabled} onClick={() => void revoke(device)}>Revoke this iPhone and its sessions</button></article>;
    })}{!query.data.devices.some(device => device.platform === 'ios') && <p className="muted">No iPhone is registered on your account.</p>}<button onClick={() => navigate({ screen: 'settings.account' })}>Manage all account sessions and devices</button></section>}
  </section>;
}

function PairingRequest({ pairing, now, disabled, decide }: { pairing: Pairing; now: number; disabled: boolean; decide: (pairing: Pairing, decision: 'approve' | 'deny') => Promise<void> }) {
  const [confirmation, setConfirmation] = useState('');
  useEffect(() => { setConfirmation(''); }, [pairing.verificationCode, pairing.revision]);
  const expired = pairing.expiresAtMs <= now;
  const pending = pairing.status === 'pending_approval' && !expired;
  return <article className="panel stack">
    <div className="row spread"><h3>{pairing.deviceName || 'Waiting for an iPhone to scan'}</h3><Badge tone={pending ? 'warning' : pairing.status === 'consumed' ? 'good' : 'muted'}>{expired && ['waiting', 'pending_approval'].includes(pairing.status) ? 'Expiry reached · refresh to confirm' : pairing.status.replaceAll('_', ' ')}</Badge></div>
    <p>{pairing.clusterName} · <code>{pairing.backendUrl}</code></p><p>Expires: {formatTime(pairing.expiresAtMs)}</p>
    {pending && <>
      <p>Compare this code with the iPhone that you requested to connect. Approve only your own device.</p>
      <strong className="pairing-verification" aria-label={`Verification code ${pairing.verificationCode}`}>{pairing.verificationCode}</strong>
      <Field label="Enter the matching code shown on your iPhone"><input value={confirmation} inputMode="numeric" pattern="[0-9]{6}" maxLength={6} autoComplete="off" onChange={event => setConfirmation(event.target.value.replace(/\D/g, ''))}/></Field>
      <button className="primary" disabled={disabled || !pairing.verificationCode || confirmation !== pairing.verificationCode} onClick={() => void decide(pairing, 'approve')}>Approve this iPhone</button>
      <button className="danger" disabled={disabled} onClick={() => void decide(pairing, 'deny')}>Deny this device</button>
    </>}
    {pairing.status === 'waiting' && !expired && <p>The unused QR expires automatically. Once your iPhone requests connection, you can approve or deny that device.</p>}
    {pairing.status === 'approved' && <p>The device is approved. The phone must complete before this request expires; approval is not proof that the phone received its credential.</p>}
    {pairing.status === 'consumed' && <p>The phone completed this pairing. Its device-bound session remains valid until revoked.</p>}
    {pairing.status === 'denied' && <p>This request was denied and cannot connect.</p>}
  </article>;
}
