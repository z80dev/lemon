import { randomInt } from 'node:crypto';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext, Route } from './services';
import { ApiError, fail } from './errors';
import { opaqueToken, type SessionSecret } from './auth';
import { hasProductAccess } from '../enterprise/policy';
import { z, parse, principal, id, mutation, update } from './validation';

const lifetimeMs = 5 * 60 * 1000;
const secret = z.string().regex(/^[A-Za-z0-9_-]{43}$/);
const installation = z.string().min(1).max(128).regex(/^[^\u0000-\u0020\u007f]+$/);
const deviceName = z.string().min(1).max(120).regex(/^[^\u0000-\u001f\u007f]+$/);
const appVersion = z.string().min(1).max(64).regex(/^[^\u0000-\u001f\u007f]+$/);
const previewSchema = z.object({ pairCode: secret, workspaceId: id }).strict();
const claimSchema = mutation.extend({ pairCode: secret, workspaceId: id, installationId: installation, deviceName, appVersion });
const approveSchema = update.extend({ verificationCode: z.string().regex(/^\d{6}$/) });
const completeSchema = mutation.extend({ claimToken: secret });

interface PrivateMutation { nonce: string; hash: string; receipt: string | null }
interface PrivateClaim extends PrivateMutation { tokenDigest: string; installationId: string; appVersion: string }
interface PrivateApproval extends PrivateMutation { state: 'issuing' | 'issued' | 'outcome_unknown'; deviceId: string; sessionId: string | null; encryptedAuth: string | null }
interface PairingSecret {
  id: string;
  pairCodeDigest: string;
  revokedAtMs: number | null;
  creation: PrivateMutation;
  claim: PrivateClaim | null;
  approval: PrivateApproval | null;
  denial: PrivateMutation | null;
  completion: PrivateMutation | null;
}

/** The public origin is operator configuration, never a request Host or an overlay claim. */
function backendOrigin(s: BackendServices): string {
  const configured = s.config.publicUrl;
  if (configured.length > 2048 || /[\u0000-\u0020\u007f\\]/.test(configured)) fail('invalid_request', 'Configure a reachable HTTPS product origin before pairing.');
  let url: URL;
  try { url = new URL(configured); } catch { fail('invalid_request', 'Configure a reachable HTTPS product origin before pairing.'); }
  const loopback = url.hostname === 'localhost' || url.hostname === '127.0.0.1' || url.hostname === '[::1]';
  if (url.username || url.password || url.search || url.hash || url.pathname !== '/' || configured !== url.origin || !(url.protocol === 'https:' || url.protocol === 'http:' && loopback)) fail('invalid_request', 'Pairing requires an exact HTTPS origin; HTTP is only for loopback development.');
  return url.origin;
}

function currentOwner(s: BackendServices, context: RequestContext): Principal {
  const actor = principal(context.user);
  if (actor.kind !== 'user' || actor.sessionId === null) fail('unauthenticated', 'A current owner session is required.');
  const workspaceId = s.store.metadata<string>('workspaceId');
  const workspace = workspaceId ? s.store.get<P.Workspace>('workspaces', workspaceId) : null;
  if (!workspace || actor.workspaceId !== workspace.id || workspace.ownerUserId !== actor.userId) fail('forbidden', 'Only the current cluster owner can pair a phone.');
  s.auth.requireRole(actor, 'owner');
  if (!workspace.enabled || !s.store.get<P.User>('users', actor.userId) || s.store.metadata(`accountDeletion:${actor.userId}`) || !hasProductAccess(s, actor.userId)) fail('unauthenticated', 'Owner authority is no longer active.');
  const session = s.store.get<P.AuthSession>('authSessions', actor.sessionId);
  if (!session || session.userId !== actor.userId || session.deviceId !== actor.deviceId || session.expiresAtMs !== null && session.expiresAtMs <= s.now() || s.store.get<SessionSecret>('sessionSecrets', session.id)?.revoked !== false) fail('unauthenticated', 'Owner session expired or was revoked.');
  if (actor.deviceId !== null && s.store.get<P.Device>('devices', actor.deviceId)?.userId !== actor.userId) fail('unauthenticated', 'Owner device was revoked.');
  return actor;
}

function claimProof(s: BackendServices, context: RequestContext): PairingSecret {
  const proof = z.object({ pairCode: secret }).passthrough().safeParse(context.body);
  if (!proof.success) fail('unauthenticated', 'Invalid pairing proof.');
  const digest = s.mutations.digest(proof.data.pairCode);
  const row = s.store.list<PairingSecret>('pairingSecrets', value => value.pairCodeDigest === digest)[0];
  if (!row) fail('unauthenticated', 'Invalid pairing proof.');
  return row;
}

function completionProof(s: BackendServices, context: RequestContext): PairingSecret {
  const proof = z.object({ claimToken: secret }).passthrough().safeParse(context.body);
  if (!proof.success) fail('unauthenticated', 'Invalid pairing proof.');
  const pairingId = parse(id, context.params.id);
  const row = s.store.get<PairingSecret>('pairingSecrets', pairingId);
  if (!row?.claim || row.claim.tokenDigest !== s.mutations.digest(proof.data.claimToken)) fail('unauthenticated', 'Invalid pairing proof.');
  return row;
}

function pairingAuthority(s: BackendServices, pairing: P.Pairing): void {
  const row = s.store.get<PairingSecret>('pairingSecrets', pairing.id);
  if (!row || row.revokedAtMs !== null) fail('unauthenticated', 'Pairing authority was revoked.');
  if (row.approval) {
    const device = s.store.get<P.Device>('devices', row.approval.deviceId);
    if (!device || device.userId !== pairing.ownerUserId || device.platform !== 'ios' || !row.claim || s.store.metadata<string>(`deviceInstallation:${device.id}`) !== row.claim.installationId) fail('unauthenticated', 'Paired installation authority was revoked.');
  }
  const workspaceId = s.store.metadata<string>('workspaceId');
  const workspace = workspaceId ? s.store.get<P.Workspace>('workspaces', workspaceId) : null;
  const member = s.store.list<P.Member>('members', value => value.userId === pairing.ownerUserId)[0];
  if (!workspace || workspace.id !== pairing.workspaceId || workspace.ownerUserId !== pairing.ownerUserId || !workspace.enabled || !member?.enabled || member.role !== 'owner' || !s.store.get<P.User>('users', pairing.ownerUserId) || s.store.metadata(`accountDeletion:${pairing.ownerUserId}`) || !hasProductAccess(s, pairing.ownerUserId)) fail('unauthenticated', 'Pairing authority was revoked.');
  if (backendOrigin(s) !== pairing.backendUrl) fail('forbidden', 'The configured cluster origin changed; create a new pairing.');
}

function sessionAuthority(s: BackendServices, pairing: P.Pairing, row: PairingSecret): void {
  pairingAuthority(s, pairing);
  const approval = row.approval;
  if (!approval?.sessionId || !row.claim) fail('outcome_unknown', 'Pairing session issuance is not confirmed.', false, { resourceIds: [pairing.id] });
  const device = s.store.get<P.Device>('devices', approval.deviceId);
  const session = s.store.get<P.AuthSession>('authSessions', approval.sessionId);
  if (!device || device.userId !== pairing.ownerUserId || device.platform !== 'ios' || s.store.metadata<string>(`deviceInstallation:${device.id}`) !== row.claim.installationId || !session || session.userId !== pairing.ownerUserId || session.deviceId !== device.id || session.expiresAtMs !== null || s.store.get<SessionSecret>('sessionSecrets', session.id)?.revoked !== false) fail('unauthenticated', 'Paired device or session was revoked.');
}

function discardCredentialCustody(row: PairingSecret): PairingSecret {
  return { ...row, creation: { ...row.creation, receipt: null }, claim: row.claim ? { ...row.claim, receipt: null } : null, approval: row.approval ? { ...row.approval, encryptedAuth: null } : null, completion: row.completion ? { ...row.completion, receipt: null } : null };
}

/** Only a known, never-delivered staged session may be removed by pairing cleanup. */
function revokeStagedSession(s: BackendServices, pairing: P.Pairing, row: PairingSecret): void {
  if (pairing.status === 'consumed' || !row.approval?.sessionId) return;
  const session = s.store.get<P.AuthSession>('authSessions', row.approval.sessionId);
  if (session?.userId !== pairing.ownerUserId || session.deviceId !== row.approval.deviceId) return;
  const authority = s.store.get<SessionSecret>('sessionSecrets', session.id);
  if (authority) s.store.put('sessionSecrets', { ...authority, revoked: true });
  s.store.remove('authSessions', session.id);
}

function expire(s: BackendServices, pairing: P.Pairing): P.Pairing {
  if (pairing.expiresAtMs > s.now()) return pairing;
  return s.store.transaction(() => {
    const latest = s.store.require<P.Pairing>('pairings', pairing.id);
    if (latest.expiresAtMs > s.now()) return latest;
    const row = s.store.get<PairingSecret>('pairingSecrets', latest.id);
    if (row) {
      revokeStagedSession(s, latest, row);
      if (row.creation.receipt || row.claim?.receipt || row.approval?.encryptedAuth || row.completion?.receipt) s.store.put('pairingSecrets', discardCredentialCustody(row));
    }
    if (latest.status === 'consumed' || latest.status === 'denied' || latest.status === 'expired') return latest;
    const expired = s.update(latest, { status: 'expired' as const });
    s.store.put('pairings', expired);
    s.events.emit('pairing.upserted', expired, { userIds: [expired.ownerUserId], desktopOnly: true });
    return expired;
  });
}

function revokeMatchingPairings(s: BackendServices, matches: (pairing: P.Pairing) => boolean): void {
  s.store.transaction(() => {
    for (const pairing of s.store.list<P.Pairing>('pairings', matches)) {
      const row = s.store.get<PairingSecret>('pairingSecrets', pairing.id);
      if (!row || row.revokedAtMs !== null) continue;
      s.store.put('pairingSecrets', { ...discardCredentialCustody(row), revokedAtMs: s.now() });
      if (pairing.status === 'consumed' || pairing.status === 'denied' || pairing.status === 'expired') continue;
      const expired = s.update(pairing, { status: 'expired' as const });
      s.store.put('pairings', expired);
      s.events.emit('pairing.upserted', expired, { userIds: [pairing.ownerUserId], desktopOnly: true });
    }
  });
}

/** Auth/account owners call these in the authority-revocation transaction before re-enabling is possible. */
export function revokeWorkspacePairings(s: BackendServices, workspaceId: string): void {
  revokeMatchingPairings(s, pairing => pairing.workspaceId === workspaceId);
}
export function revokeUserPairings(s: BackendServices, userId: string): void {
  revokeMatchingPairings(s, pairing => pairing.ownerUserId === userId);
}

/** Actual account deletion removes private installation/proof data, not just its revocation tombstone. */
export function deleteUserPairings(s: BackendServices, userId: string): void {
  s.store.transaction(() => {
    const creations = new Set<string>();
    for (const pairing of s.store.list<P.Pairing>('pairings', value => value.ownerUserId === userId)) {
      const scope = `${pairing.workspaceId}:user:${userId}:POST:`;
      creations.add(`${scope}/v1/pairings`);
      s.store.db.query('DELETE FROM nonces WHERE scope IN (?,?)').run(`${scope}/v1/pairings/${encodeURIComponent(pairing.id)}/approve`, `${scope}/v1/pairings/${encodeURIComponent(pairing.id)}/deny`);
      s.store.remove('pairingSecrets', pairing.id);
      s.store.remove('pairings', pairing.id);
    }
    for (const scope of creations) s.store.db.query('DELETE FROM nonces WHERE scope=?').run(scope);
  });
}

export interface PairingService { sweep(): Promise<void>; close(): void }

/** Centralized startup/periodic sweep only; no timer and no uncertain issuance replay. */
export function createPairingService(s: BackendServices): PairingService {
  let closed = false;
  return {
    async sweep() {
      if (closed) return;
      for (const original of s.store.list<P.Pairing>('pairings')) {
        const pairing = expire(s, original);
        const row = s.store.get<PairingSecret>('pairingSecrets', pairing.id);
        if (!row) continue;
        try {
          pairingAuthority(s, pairing);
          if (row.approval?.state === 'issued' && pairing.status !== 'expired') sessionAuthority(s, pairing, row);
        } catch (error) {
          if (!(error instanceof ApiError)) throw error;
          s.store.transaction(() => {
            revokeStagedSession(s, pairing, row);
            revokeMatchingPairings(s, value => value.id === pairing.id);
          });
        }
      }
    },
    close() { closed = true; },
  };
}

function ownedPairing(s: BackendServices, actor: Principal, pairingId: string): P.Pairing {
  const pairing = s.store.get<P.Pairing>('pairings', pairingId);
  if (!pairing || pairing.ownerUserId !== actor.userId || pairing.workspaceId !== actor.workspaceId) fail('not_found', 'Pairing not found.');
  pairingAuthority(s, pairing);
  return expire(s, pairing);
}

function sameMutation(s: BackendServices, previous: PrivateMutation, body: { clientNonce: string }): void {
  if (previous.nonce !== body.clientNonce || previous.hash !== s.mutations.digest(body)) fail('nonce_conflict', 'This pairing is bound to its original request nonce and intent.');
}

function requireUnexpired(s: BackendServices, pairing: P.Pairing): void {
  if (pairing.expiresAtMs <= s.now() || pairing.status === 'expired') fail('expired', 'Pairing expired; create a new QR code.');
}

/** Public proof gates precede argument validation and receipt lookup. No public route issues sessions. */
export function createPairingRoutes(s: BackendServices): Route[] {
  const { store } = s;
  const issuing = new Set<string>();
  const noQuery = (context: RequestContext) => { if (context.query.size) fail('invalid_request', 'Pairing endpoints do not accept query parameters.'); };
  const privateRow = (pairingId: string) => store.require<PairingSecret>('pairingSecrets', pairingId);
  const liveReceipt = (pairing: P.Pairing, row: PairingSecret) => {
    pairingAuthority(s, pairing);
    requireUnexpired(s, pairing);
    if (row.approval?.state === 'issued') sessionAuthority(s, pairing, row);
  };

  const routes: Route[] = [
    { method: 'POST', path: '/v1/pairings', auth: 'owner', mutation: false, status: 201, authorizeReplay: context => { currentOwner(s, context); }, handler: async context => {
      const actor = currentOwner(s, context); noQuery(context);
      const body: P.PairingStart = parse(mutation, context.body);
      const prior = store.list<PairingSecret>('pairingSecrets', row => row.creation.nonce === body.clientNonce).find(row => {
        const pairing = store.get<P.Pairing>('pairings', row.id);
        return pairing?.ownerUserId === actor.userId && pairing.workspaceId === actor.workspaceId;
      });
      if (prior) {
        sameMutation(s, prior.creation, body);
        liveReceipt(ownedPairing(s, actor, prior.id), prior);
        if (!prior.creation.receipt) fail('outcome_unknown', 'Original QR issuance custody is not confirmed.', false, { resourceIds: [prior.id] });
        return s.decrypt<P.PairingIssued>(prior.creation.receipt);
      }
      return s.mutations.execute(context, () => store.transaction(() => {
        currentOwner(s, context);
        const workspace = store.require<P.Workspace>('workspaces', actor.workspaceId);
        const backendUrl = backendOrigin(s);
        const pairCode = opaqueToken();
        const pairing: P.Pairing = s.resource('pairing', { workspaceId: workspace.id, ownerUserId: actor.userId, clusterName: workspace.name, backendUrl, status: 'waiting', expiresAtMs: s.now() + lifetimeMs, deviceName: null, verificationCode: null });
        const url = new URL('lemonbot://pair');
        url.searchParams.set('backend', backendUrl); url.searchParams.set('cluster', workspace.id); url.searchParams.set('code', pairCode);
        const result: P.PairingIssued = { pairing, pairUrl: url.toString() };
        const row: PairingSecret = { id: pairing.id, pairCodeDigest: s.mutations.digest(pairCode), revokedAtMs: null, creation: { nonce: body.clientNonce, hash: s.mutations.digest(body), receipt: s.encrypt(result) }, claim: null, approval: null, denial: null, completion: null };
        store.put('pairings', pairing); store.put('pairingSecrets', row);
        s.events.emit('pairing.upserted', pairing, { userIds: [actor.userId], desktopOnly: true });
        context.nonceResourceIds.push(pairing.id);
        return result;
      }));
    } },
    { method: 'GET', path: '/v1/pairings', auth: 'owner', status: 200, handler: context => {
      const actor = currentOwner(s, context); noQuery(context);
      return store.list<P.Pairing>('pairings', value => value.workspaceId === actor.workspaceId && value.ownerUserId === actor.userId && value.expiresAtMs > s.now() && (value.status === 'waiting' || value.status === 'pending_approval')).sort((a, b) => b.createdAtMs - a.createdAtMs || b.id.localeCompare(a.id)).slice(0, 200);
    } },
    { method: 'GET', path: '/v1/pairings/:id', auth: 'owner', status: 200, handler: context => {
      const actor = currentOwner(s, context); noQuery(context);
      return ownedPairing(s, actor, parse(id, context.params.id));
    } },
    { method: 'POST', path: '/v1/pairings/preview', auth: 'public', mutation: false, status: 200, handler: context => {
      const proven = claimProof(s, context); noQuery(context);
      const body: P.PairingPreviewRequest = parse(previewSchema, context.body);
      const pairing = expire(s, store.require<P.Pairing>('pairings', proven.id));
      pairingAuthority(s, pairing); requireUnexpired(s, pairing);
      if (pairing.workspaceId !== body.workspaceId) fail('forbidden', 'QR cluster does not match this pairing.');
      if (pairing.status !== 'waiting' || proven.claim) fail('conflict', 'QR code was already claimed.');
      return { clusterName: pairing.clusterName, backendUrl: pairing.backendUrl, expiresAtMs: pairing.expiresAtMs } satisfies P.PairingPreviewResult;
    } },
    { method: 'POST', path: '/v1/pairings/claim', auth: 'public', mutation: false, status: 200, handler: context => {
      const proven = claimProof(s, context); noQuery(context);
      const body: P.PairingClaim = parse(claimSchema, context.body);
      return store.transaction(() => {
        const row = privateRow(proven.id);
        const pairing = expire(s, store.require<P.Pairing>('pairings', row.id));
        pairingAuthority(s, pairing);
        if (pairing.workspaceId !== body.workspaceId) fail('forbidden', 'QR cluster does not match this pairing.');
        if (row.claim) {
          sameMutation(s, row.claim, body); liveReceipt(pairing, row);
          if (pairing.status === 'denied') fail('forbidden', 'Pairing was denied.');
          if (!row.claim.receipt) fail('outcome_unknown', 'The original claim is not confirmed.', false, { resourceIds: [pairing.id] });
          return s.decrypt<P.PairingClaimResult>(row.claim.receipt);
        }
        requireUnexpired(s, pairing);
        if (pairing.status !== 'waiting') fail('conflict', 'QR code is no longer available.');
        const claimedElsewhere = store.list<PairingSecret>('pairingSecrets', other => other.id !== row.id && other.claim?.installationId === body.installationId).some(other => {
          const target = store.get<P.Pairing>('pairings', other.id);
          if (!target || target.workspaceId !== pairing.workspaceId || target.ownerUserId !== pairing.ownerUserId || other.revokedAtMs !== null) return false;
          if (other.approval && other.approval.state !== 'issued' && store.get<P.Device>('devices', other.approval.deviceId)) return true;
          if (target.status === 'denied' || target.status === 'expired') return false;
          if (target.status !== 'consumed' && target.expiresAtMs > s.now()) return true;
          const session = other.approval?.sessionId ? store.get<P.AuthSession>('authSessions', other.approval.sessionId) : null;
          return session !== null && session.deviceId === other.approval?.deviceId && store.get<SessionSecret>('sessionSecrets', session.id)?.revoked === false;
        });
        if (claimedElsewhere) fail('conflict', 'This installation already has an active pairing.');
        const claimToken = opaqueToken();
        const verificationCode = randomInt(0, 1000000).toString().padStart(6, '0');
        const pending = s.update(pairing, { status: 'pending_approval' as const, deviceName: body.deviceName, verificationCode });
        const result: P.PairingClaimResult = { pairingId: pairing.id, claimToken, verificationCode, expiresAtMs: pairing.expiresAtMs, clusterName: pairing.clusterName, backendUrl: pairing.backendUrl };
        store.put('pairings', pending);
        store.put('pairingSecrets', { ...row, claim: { nonce: body.clientNonce, hash: s.mutations.digest(body), receipt: s.encrypt(result), tokenDigest: s.mutations.digest(claimToken), installationId: body.installationId, appVersion: body.appVersion } });
        s.events.emit('pairing.upserted', pending, { userIds: [pairing.ownerUserId], desktopOnly: true });
        return result;
      });
    } },
    { method: 'POST', path: '/v1/pairings/:id/approve', auth: 'owner', mutation: false, status: 200, authorizeReplay: context => {
      const actor = currentOwner(s, context);
      const pairingId = parse(id, context.params.id);
      liveReceipt(ownedPairing(s, actor, pairingId), privateRow(pairingId));
    }, handler: async context => {
      const actor = currentOwner(s, context); noQuery(context);
      const pairingId = parse(id, context.params.id);
      const pairing = ownedPairing(s, actor, pairingId);
      const body: P.PairingApprove = parse(approveSchema, context.body);
      const initial = privateRow(pairingId);
      requireUnexpired(s, pairing);
      if (pairing.verificationCode !== body.verificationCode) fail('confirmation_required', 'Verify the matching code shown on the phone.');
      if (initial.approval) {
        sameMutation(s, initial.approval, body);
        if (initial.approval.receipt) {
          sessionAuthority(s, pairing, initial);
          return s.decrypt<P.Pairing>(initial.approval.receipt);
        }
        if (initial.approval.state !== 'issuing' || !issuing.has(pairingId)) fail('outcome_unknown', 'The original session issuance requires reconciliation; it will not be repeated.', false, { resourceIds: [pairingId, initial.approval.deviceId] });
      }
      return s.mutations.execute(context, async () => {
        const prepared = store.transaction(() => {
          currentOwner(s, context);
          const current = ownedPairing(s, actor, pairingId);
          const row = privateRow(pairingId);
          requireUnexpired(s, current); s.mutations.checkRevision(current, body.revision);
          if (current.status !== 'pending_approval' || !row.claim || row.approval) fail('conflict', 'Pairing is not awaiting approval.');
          if (current.verificationCode !== body.verificationCode) fail('confirmation_required', 'Verification code changed; review the phone again.');
          const prior = store.list<P.Device>('devices', device => store.metadata<string>(`deviceInstallation:${device.id}`) === row.claim!.installationId)[0];
          if (prior && (prior.userId !== actor.userId || prior.platform !== 'ios')) fail('conflict', 'Installation is already bound to another device.');
          if (prior && store.list<P.AuthSession>('authSessions', session => session.deviceId === prior.id && (session.expiresAtMs === null || session.expiresAtMs > s.now()) && store.get<SessionSecret>('sessionSecrets', session.id)?.revoked === false).length) fail('conflict', 'Revoke the existing installation session before reconnecting it.');
          const fields = { userId: actor.userId, platform: 'ios' as const, name: current.deviceName!, appVersion: row.claim.appVersion, pushEnabled: false, lastSeenAtMs: s.now() };
          const device: P.Device = prior ? s.update(prior, fields) : s.resource('device', fields);
          const approval: PrivateApproval = { nonce: body.clientNonce, hash: s.mutations.digest(body), receipt: null, state: 'issuing', deviceId: device.id, sessionId: null, encryptedAuth: null };
          store.put('devices', device); store.setMetadata(`deviceInstallation:${device.id}`, row.claim.installationId);
          store.put('pairingSecrets', { ...row, approval });
          context.nonceResourceIds.push(pairingId, device.id);
          return { device, approval };
        });
        issuing.add(pairingId);
        try {
          const auth = await s.auth.session(actor.userId, prepared.device.id, { persistent: true });
          store.transaction(() => {
            const row = privateRow(pairingId);
            if (row.approval?.state !== 'issuing' || row.approval.nonce !== body.clientNonce || auth.session.userId !== actor.userId || auth.session.deviceId !== prepared.device.id) fail('outcome_unknown', 'Issued session does not match the reserved device.', false);
            store.put('pairingSecrets', { ...row, approval: { ...row.approval, sessionId: auth.session.id, encryptedAuth: s.encrypt(auth) } });
          });
          return store.transaction(() => {
            currentOwner(s, context);
            const current = ownedPairing(s, actor, pairingId); requireUnexpired(s, current);
            const row = privateRow(pairingId);
            if (row.approval?.state !== 'issuing' || row.approval.nonce !== body.clientNonce || current.status !== 'pending_approval') fail('outcome_unknown', 'Pairing changed during session issuance.', false, { resourceIds: [pairingId, prepared.device.id] });
            const approval: PrivateApproval = { ...row.approval, state: 'issued' };
            sessionAuthority(s, current, { ...row, approval });
            if (s.mutations.digest(auth.token) !== store.get<SessionSecret>('sessionSecrets', auth.session.id)?.tokenDigest) fail('outcome_unknown', 'The issued session proof is not confirmed.', false);
            const approved = s.update(current, { status: 'approved' as const });
            approval.receipt = s.encrypt(approved);
            store.put('pairingSecrets', { ...row, approval }); store.put('pairings', approved);
            s.events.emit('device.upserted', prepared.device, { userIds: [actor.userId] });
            s.events.emit('pairing.upserted', approved, { userIds: [actor.userId], desktopOnly: true });
            return approved;
          });
        } catch (error) {
          store.transaction(() => {
            const row = privateRow(pairingId);
            if (row.approval?.state === 'issuing') store.put('pairingSecrets', { ...row, approval: { ...row.approval, state: 'outcome_unknown' } });
            revokeStagedSession(s, store.require<P.Pairing>('pairings', pairingId), row);
          });
          throw new ApiError('outcome_unknown', 'Session issuance could not be confirmed and will not be repeated.', false, { resourceIds: [pairingId, prepared.device.id], cause: error instanceof ApiError ? error.code : 'internal_error' });
        } finally { issuing.delete(pairingId); }
      });
    } },
    { method: 'POST', path: '/v1/pairings/:id/deny', auth: 'owner', mutation: false, status: 200, authorizeReplay: context => {
      const actor = currentOwner(s, context);
      ownedPairing(s, actor, parse(id, context.params.id));
    }, handler: async context => {
      const actor = currentOwner(s, context); noQuery(context);
      const pairingId = parse(id, context.params.id);
      const pairing = ownedPairing(s, actor, pairingId);
      const body: P.PairingDeny = parse(update, context.body);
      const initial = privateRow(pairingId);
      requireUnexpired(s, pairing);
      if (initial.denial?.receipt) { sameMutation(s, initial.denial, body); return s.decrypt<P.Pairing>(initial.denial.receipt); }
      return s.mutations.execute(context, () => store.transaction(() => {
        currentOwner(s, context);
        const current = ownedPairing(s, actor, pairingId); requireUnexpired(s, current);
        const row = privateRow(pairingId);
        s.mutations.checkRevision(current, body.revision);
        if (row.approval) fail('outcome_unknown', 'Session issuance was already reserved; revoke the device instead.', false, { resourceIds: [pairingId, row.approval.deviceId] });
        if (current.status !== 'waiting' && current.status !== 'pending_approval') fail('conflict', 'Pairing is no longer awaiting a decision.');
        const denied = s.update(current, { status: 'denied' as const });
        store.put('pairings', denied); store.put('pairingSecrets', { ...row, denial: { nonce: body.clientNonce, hash: s.mutations.digest(body), receipt: s.encrypt(denied) } });
        s.events.emit('pairing.upserted', denied, { userIds: [actor.userId], desktopOnly: true });
        return denied;
      }));
    } },
    { method: 'POST', path: '/v1/pairings/:id/complete', auth: 'public', mutation: false, status: 200, handler: context => {
      const proven = completionProof(s, context); noQuery(context);
      const body: P.PairingComplete = parse(completeSchema, context.body);
      return store.transaction(() => {
        const pairing = expire(s, store.require<P.Pairing>('pairings', proven.id));
        const row = privateRow(proven.id);
        pairingAuthority(s, pairing);
        if (row.completion) sameMutation(s, row.completion, body);
        const completion: PrivateMutation = row.completion ?? { nonce: body.clientNonce, hash: s.mutations.digest(body), receipt: null };
        if (pairing.status === 'denied' || pairing.expiresAtMs <= s.now() || pairing.status === 'expired') {
          const result: P.PairingCompletion = { status: pairing.status === 'denied' ? 'denied' : 'expired', pairingId: pairing.id, expiresAtMs: pairing.expiresAtMs };
          store.put('pairingSecrets', { ...row, completion });
          return result;
        }
        if (row.approval && row.approval.state !== 'issued') fail('outcome_unknown', 'The original session issuance is not confirmed; no new credential will be issued.', false, { resourceIds: [pairing.id] });
        if (pairing.status === 'pending_approval') {
          store.put('pairingSecrets', { ...row, completion });
          return { status: 'pending', pairingId: pairing.id, expiresAtMs: pairing.expiresAtMs } satisfies P.PairingCompletion;
        }
        sessionAuthority(s, pairing, row);
        if (completion.receipt) return s.decrypt<P.PairingCompletion>(completion.receipt);
        if (pairing.status !== 'approved' || !row.approval?.encryptedAuth) fail('outcome_unknown', 'Original pairing credential custody is not confirmed.', false, { resourceIds: [pairing.id] });
        const auth = s.decrypt<P.AuthResult>(row.approval.encryptedAuth);
        if (auth.session.id !== row.approval.sessionId || auth.session.userId !== pairing.ownerUserId || auth.session.deviceId !== row.approval.deviceId || auth.session.expiresAtMs !== null || s.mutations.digest(auth.token) !== store.get<SessionSecret>('sessionSecrets', auth.session.id)?.tokenDigest) fail('outcome_unknown', 'Original pairing credential proof is not confirmed.', false, { resourceIds: [pairing.id] });
        const device = store.require<P.Device>('devices', row.approval.deviceId);
        const result: P.PairingCompletion = { status: 'connected', auth, device };
        store.put('pairingSecrets', { ...row, completion: { ...completion, receipt: s.encrypt(result) } });
        const consumed = s.update(pairing, { status: 'consumed' as const });
        store.put('pairings', consumed);
        s.events.emit('pairing.upserted', consumed, { userIds: [pairing.ownerUserId], desktopOnly: true });
        return result;
      });
    } },
  ];
  return routes;
}
