import { createCipheriv, createECDH, createHmac, createPrivateKey, ECDH, randomBytes, sign } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { readFileSync, statSync } from 'node:fs';
import { connect } from 'node:http2';
import { request as httpsRequest } from 'node:https';
import { isIP } from 'node:net';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal } from '../core/services';
import { fail } from '../core/errors';

export interface PushResponse { status: number; reason?: string; timestamp?: number }
export interface PushOptions {
  env?: Record<string, string | undefined>;
  resolve?: (host: string) => Promise<{ address: string; family: number }[]>;
  sendAPNs?: (origin: string, path: string, headers: Record<string, string>, body: Uint8Array) => Promise<PushResponse>;
  sendWebPush?: (url: URL, address: { address: string; family: number }, headers: Record<string, string>, body: Uint8Array) => Promise<PushResponse>;
  timeoutMs?: number;
}
export interface PushServices {
  emitProviderNotifications(notification: P.Notification): Promise<void>;
  providerCapabilities(): Pick<P.Capabilities, 'apns' | 'webPush' | 'vapidPublicKey'>;
  inventory(): { id: 'apns' | 'web_push'; configured: boolean }[];
}
const pushInstances = new WeakMap<BackendServices, PushServices>();
const DEFAULT_ORIGINS = ['https://fcm.googleapis.com', 'https://updates.push.services.mozilla.com', 'https://web.push.apple.com'];
const APNS_TOPIC = /^[A-Za-z0-9][A-Za-z0-9.-]{1,254}$/;
function decode(value: string, size: number): Buffer {
  if (value.length !== Math.ceil(size * 4 / 3) || !/^[A-Za-z0-9_-]+$/.test(value)) fail('invalid_request', 'Push key must be correctly sized unpadded base64url.');
  const bytes = Buffer.from(value, 'base64url'); if (bytes.length !== size || bytes.toString('base64url') !== value) fail('invalid_request', 'Invalid push key length.'); return bytes;
}
/** Deny all special-use/local ranges, including IPv4-mapped IPv6. */
export function isPublicPushAddress(address: string): boolean {
  const family = isIP(address);
  if (family === 4) {
    const [a, b, c] = address.split('.').map(Number) as [number, number, number, number];
    return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && (b === 168 || b === 0 || (b === 88 && c === 99))) || (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) || (a === 203 && b === 0 && c === 113));
  }
  if (family !== 6) return false;
  // Only global-unicast 2000::/3, excluding documentation and transition tunnels.
  const [firstText, secondText] = address.toLowerCase().split(':'), first = parseInt(firstText!, 16), second = parseInt(secondText ?? '0', 16);
  return first >= 0x2000 && first <= 0x3fff && first !== 0x2002 && first !== 0x3fff && !(first === 0x2001 && (second === 0 || second === 2 || second === 0xdb8 || (second >= 0x10 && second <= 0x2f)));
}
async function destination(endpoint: string, options: PushOptions): Promise<{ url: URL; address: { address: string; family: number } }> {
  const env = options.env ?? process.env;
  let url: URL; try { url = new URL(endpoint); } catch { return fail('invalid_request', 'Invalid Web Push endpoint.'); }
  const origins = env.LEMON_BOT_WEB_PUSH_ORIGINS?.split(',').map(s => s.trim()).filter(Boolean) ?? DEFAULT_ORIGINS;
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || (url.port && url.port !== '443') || !origins.includes(url.origin) || isIP(url.hostname)) fail('invalid_request', 'Web Push endpoint is not an allowed HTTPS push service.');
  let addresses: { address: string; family: number }[];
  const deadline = Promise.withResolvers<never>(), timer = setTimeout(() => deadline.reject(new Error('DNS timeout.')), options.timeoutMs ?? 15_000);
  try { addresses = await Promise.race([(options.resolve ?? (host => lookup(host, { all: true })))(url.hostname), deadline.promise]); } catch { return fail('upstream_unavailable', 'Push service DNS resolution failed or timed out.'); } finally { clearTimeout(timer); }
  if (!addresses.length || addresses.some(a => !isPublicPushAddress(a.address) || a.family !== isIP(a.address))) fail('invalid_request', 'Push service resolves to a prohibited address.');
  return { url, address: addresses[0]! };
}
export async function validatePushRegistration(registration: P.PushRegistration, options: PushOptions = {}): Promise<void> {
  const env = options.env ?? process.env;
  if (registration.kind === 'apns') {
    const topics = env.LEMON_BOT_APNS_TOPICS?.split(',').map(s => s.trim()).filter(Boolean) ?? [];
    const environments = env.LEMON_BOT_APNS_ENVIRONMENTS?.split(',').map(s => s.trim()) ?? ['sandbox', 'production'];
    if (!/^[a-fA-F0-9]{64}$/.test(registration.token) || !APNS_TOPIC.test(registration.topic) || !topics.includes(registration.topic) || !environments.includes(registration.environment) || !['sandbox', 'production'].includes(registration.environment)) fail('invalid_request', 'APNs token, topic or environment is not allowed.');
  } else if (registration.kind === 'web_push') {
    const publicKey = decode(registration.keys.p256dh, 65); decode(registration.keys.auth, 16);
    try { ECDH.convertKey(publicKey, 'prime256v1', undefined, undefined, 'uncompressed'); } catch { fail('invalid_request', 'Invalid Web Push P-256 key.'); }
    await destination(registration.endpoint, options);
  } else fail('invalid_request', 'Unsupported push registration.');
}
function expand(prk: Uint8Array, info: Uint8Array, size: number): Buffer {
  const result = createHmac('sha256', prk).update(info).update(Buffer.from([1])).digest(); return result.subarray(0, size);
}
/** RFC 8291 single-record aes128gcm, with deterministic salt/key injection for fixtures only. */
export function encryptWebPush(payload: Uint8Array, subscription: Extract<P.PushRegistration, { kind: 'web_push' }>, material?: { salt: Uint8Array; privateKey: Uint8Array }): Uint8Array {
  if (payload.length > 3993) fail('too_large', 'Web Push payload exceeds one encrypted record.');
  const receiver = decode(subscription.keys.p256dh, 65), auth = decode(subscription.keys.auth, 16);
  const sender = createECDH('prime256v1'); if (material) sender.setPrivateKey(material.privateKey); else sender.generateKeys();
  const publicKey = sender.getPublicKey(), salt = material ? Buffer.from(material.salt) : randomBytes(16); if (salt.length !== 16) fail('invalid_request', 'Invalid Web Push salt.');
  let secret: Buffer; try { secret = sender.computeSecret(receiver); } catch { return fail('invalid_request', 'Invalid Web Push receiver key.'); }
  const authPrk = createHmac('sha256', auth).update(secret).digest();
  const ikm = expand(authPrk, Buffer.concat([Buffer.from('WebPush: info\0'), receiver, publicKey]), 32);
  const prk = createHmac('sha256', salt).update(ikm).digest();
  const key = expand(prk, Buffer.from('Content-Encoding: aes128gcm\0'), 16), nonce = expand(prk, Buffer.from('Content-Encoding: nonce\0'), 12);
  const cipher = createCipheriv('aes-128-gcm', key, nonce);
  const encrypted = Buffer.concat([cipher.update(Buffer.concat([Buffer.from(payload), Buffer.from([2])])), cipher.final(), cipher.getAuthTag()]);
  const header = Buffer.alloc(21); salt.copy(header); header.writeUInt32BE(4096, 16); header[20] = publicKey.length;
  secret.fill(0); ikm.fill(0); key.fill(0);
  return Buffer.concat([header, publicKey, encrypted]);
}
export function vapidToken(origin: string, subject: string, publicKey: string, privateKey: string, now: number): string {
  if (!/^mailto:[^\s@]+@[^\s@]+$/.test(subject)) { let url: URL; try { url = new URL(subject); } catch { return fail('capability_unavailable', 'VAPID subject must be mailto or HTTPS.'); } if (url.protocol !== 'https:' || url.username || url.password) fail('capability_unavailable', 'VAPID subject must be mailto or HTTPS.'); }
  const pub = decode(publicKey, 65), priv = decode(privateKey, 32), key = createECDH('prime256v1'); key.setPrivateKey(priv);
  if (!key.getPublicKey().equals(pub)) fail('capability_unavailable', 'VAPID keys do not match.');
  const signer = createPrivateKey({ key: { kty: 'EC', crv: 'P-256', x: pub.subarray(1,33).toString('base64url'), y: pub.subarray(33).toString('base64url'), d: priv.toString('base64url') }, format: 'jwk' });
  const unsigned = `${Buffer.from(JSON.stringify({ typ: 'JWT', alg: 'ES256' })).toString('base64url')}.${Buffer.from(JSON.stringify({ aud: origin, exp: Math.floor(now / 1000) + 12 * 3600, sub: subject })).toString('base64url')}`;
  return `${unsigned}.${sign('sha256', Buffer.from(unsigned), { key: signer, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}
export function apnsToken(keyId: string, teamId: string, privateKey: string, now: number): string {
  const key = createPrivateKey(privateKey); if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') fail('capability_unavailable', 'APNs requires a P-256 .p8 key.');
  const unsigned = `${Buffer.from(JSON.stringify({ alg: 'ES256', kid: keyId })).toString('base64url')}.${Buffer.from(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) })).toString('base64url')}`;
  return `${unsigned}.${sign('sha256', Buffer.from(unsigned), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
}
function sendAPNs(origin: string, path: string, headers: Record<string, string>, body: Uint8Array, timeout: number): Promise<PushResponse> {
  const { promise, resolve, reject } = Promise.withResolvers<PushResponse>();
    const client = connect(origin); let settled = false;
    const finish = (error: boolean, result?: PushResponse) => { if (settled) return; settled = true; clearTimeout(timer); client.destroy(); if (error) reject(new Error('APNs request failed.')); else resolve(result!); };
    const timer = setTimeout(() => finish(true), timeout); client.on('error', () => finish(true));
    const stream = client.request({ ':method': 'POST', ':path': path, ...headers }); let status = 0, size = 0; const parts: Buffer[] = [];
    stream.on('response', h => { status = Number(h[':status']); }); stream.on('error', () => finish(true));
    stream.on('data', (chunk: Buffer) => { size += chunk.length; if (size > 4096) finish(true); else parts.push(chunk); });
    stream.on('end', () => { let data: unknown = null; try { data = JSON.parse(Buffer.concat(parts).toString('utf8')); } catch { /* Successful APNs responses have no body. */ } const record = typeof data === 'object' && data !== null ? data as Record<string, unknown> : {}; finish(false, { status, ...(typeof record.reason === 'string' ? { reason: record.reason } : {}), ...(typeof record.timestamp === 'number' ? { timestamp: record.timestamp } : {}) }); });
    stream.end(body);
  return promise;
}
function sendWebPush(url: URL, address: { address: string; family: number }, headers: Record<string, string>, body: Uint8Array, timeout: number): Promise<PushResponse> {
  const { promise, resolve, reject } = Promise.withResolvers<PushResponse>();
    // Pin DNS result into the TLS socket, while preserving hostname certificate/SNI validation.
    const req = httpsRequest(url, { method: 'POST', headers, lookup: (_host, lookupOptions, callback) => { if (typeof lookupOptions === 'object' && lookupOptions.all) callback(null, [address]); else callback(null, address.address, address.family); }, timeout }, response => {
      response.resume(); const status = response.statusCode ?? 0; response.on('end', () => resolve({ status })); response.on('error', () => reject(new Error('Push response failed.')));
    });
    const timer = setTimeout(() => req.destroy(new Error('Push request timed out.')), timeout); req.on('close', () => clearTimeout(timer)); req.on('timeout', () => req.destroy(new Error('Push request timed out.'))); req.on('error', () => reject(new Error('Push request failed.'))); req.end(body);
  return promise;
}

export function createPushServices(services: BackendServices, overrides?: PushOptions): PushServices {
  if (overrides === undefined) { const existing = pushInstances.get(services); if (existing) return existing; }
  const options: PushOptions = overrides ?? {}, env = options.env ?? process.env, timeout = options.timeoutMs ?? 15_000;
  let apnsKey: string | null = null;
  try { const path = env.LEMON_BOT_APNS_PRIVATE_KEY_PATH; if (path) { const info = statSync(path); if (!info.isFile() || (info.mode & 0o077) || (process.getuid && info.uid !== process.getuid())) throw new Error(); apnsKey = readFileSync(path, 'utf8'); if (!apnsKey.startsWith('-----BEGIN PRIVATE KEY-----')) throw new Error(); apnsToken(env.LEMON_BOT_APNS_KEY_ID ?? '', env.LEMON_BOT_APNS_TEAM_ID ?? '', apnsKey, services.now()); } } catch { apnsKey = null; }
  let apnsJwt: { value: string; createdAt: number } | null = null, vapidReady = false;
  try { if (env.LEMON_BOT_VAPID_PUBLIC_KEY && env.LEMON_BOT_VAPID_PRIVATE_KEY && env.LEMON_BOT_VAPID_SUBJECT) { vapidToken('https://fcm.googleapis.com', env.LEMON_BOT_VAPID_SUBJECT, env.LEMON_BOT_VAPID_PUBLIC_KEY, env.LEMON_BOT_VAPID_PRIVATE_KEY, services.now()); vapidReady = true; } } catch { vapidReady = false; }
  const apnsReady = !!(apnsKey && /^[A-Z0-9]{10}$/.test(env.LEMON_BOT_APNS_KEY_ID ?? '') && /^[A-Z0-9]{10}$/.test(env.LEMON_BOT_APNS_TEAM_ID ?? '') && env.LEMON_BOT_APNS_TOPICS?.split(',').some(topic => APNS_TOPIC.test(topic.trim())) && (env.LEMON_BOT_APNS_ENVIRONMENTS?.split(',').map(value => value.trim()) ?? ['sandbox', 'production']).some(value => value === 'sandbox' || value === 'production'));
  const providerCapabilities = () => ({ apns: apnsReady, webPush: vapidReady, vapidPublicKey: vapidReady ? env.LEMON_BOT_VAPID_PUBLIC_KEY! : null });
  async function emitProviderNotifications(notification: P.Notification): Promise<void> {
    const user = services.store.get<P.User>('users', notification.userId), member = services.store.list<P.Member>('members', m => m.userId === notification.userId)[0], workspace = services.store.list<P.Workspace>('workspaces')[0];
    if (!user || !member?.enabled || !workspace?.enabled || !user.notifications.enabled || notification.readAtMs !== null || notification.dismissedAtMs !== null) return;
    if ((notification.kind === 'result' && !user.notifications.completed) || (['approval', 'question', 'human_step'].includes(notification.kind) && !user.notifications.needsInput)) return;
    const principal: Principal = { kind: 'user', id: user.id, userId: user.id, workspaceId: workspace.id, role: member.role, sessionId: null, botId: null, deviceId: null };
    function canDeliverTarget(): boolean {
      try {
        const target = notification.target;
        if (target.botId !== notification.botId) return false;
        if ((target.kind === 'entry' || target.kind === 'approval') && (target.conversationId !== notification.conversationId || target.entryId !== notification.entryId)) return false;
        if (notification.conversationId && services.auth.conversation(principal, notification.conversationId).ownerUserId !== principal.userId) return false;
        if (notification.botId) { const bot = services.auth.bot(principal, notification.botId); if (bot.ownerUserId !== principal.userId || bot.sidebar.hidden || !bot.sidebar.notificationsEnabled) return false; }
        if (notification.entryId) { const entry = services.store.get<P.TranscriptEntry>('entries', notification.entryId); if (!entry || entry.conversationId !== notification.conversationId || !services.auth.canRead(principal, 'entries', entry)) return false; }
        if (target.kind === 'entry' && target.taskConversationId && services.auth.conversation(principal, target.taskConversationId).ownerUserId !== principal.userId) return false;
        if (target.kind === 'approval') { const approval = services.store.get<P.Approval>('approvals', target.approvalId); if (!approval || approval.botId !== target.botId || approval.entryId !== target.entryId || approval.conversationId !== target.conversationId || !services.auth.canRead(principal, 'approvals', approval)) return false; }
        if (target.kind === 'machine') services.auth.machine(principal, target.machineId);
        if (target.kind === 'routine') { const routine = services.store.get<P.Routine>('routines', target.routineId); if (!routine || routine.ownerUserId !== principal.userId || routine.botId !== target.botId || !services.auth.canRead(principal, 'routines', routine)) return false; if (target.routineRunId) { const run = services.store.get<P.RoutineRun>('routineRuns', target.routineRunId); if (!run || run.routineId !== routine.id || !services.auth.canRead(principal, 'routineRuns', run)) return false; } }
        return true;
      } catch { return false; }
    }
    if (!canDeliverTarget()) return;
    try { if (!(await services.integrations.effectivePolicy(principal, notification.botId ?? undefined)).productAccess) return; } catch { return; }
    // Only low-value completions/reconnect noise are coalesced. Gates are never coalesced.
    const coalesceKey = `pushCoalesce:${user.id}:${notification.kind}:${notification.conversationId ?? (notification.target.kind === 'machine' ? notification.target.machineId : notification.id)}`;
    if (['result', 'machine'].includes(notification.kind)) { const last = services.store.metadata<number>(coalesceKey); if (last !== null && services.now() - last < 5000) return; services.store.setMetadata(coalesceKey, services.now()); }
    const target = notification.target, enc = encodeURIComponent;
    let deepLink: string;
    const base = `lemonbot://workspace/${enc(workspace.id)}`;
    if (target.kind === 'machine') deepLink = `${base}/machine/${enc(target.machineId)}${target.botId ? `?botId=${enc(target.botId)}` : ''}`;
    else if (target.kind === 'routine') deepLink = `${base}/bot/${enc(target.botId)}/routine/${enc(target.routineId)}${target.routineRunId ? `?routineRunId=${enc(target.routineRunId)}` : ''}`;
    else deepLink = `${base}/bot/${enc(target.botId)}?conversationId=${enc(target.conversationId)}${target.kind === 'entry' && target.taskConversationId ? `&taskConversationId=${enc(target.taskConversationId)}` : ''}&entryId=${enc(target.entryId)}${target.kind === 'approval' ? `&approvalId=${enc(target.approvalId)}` : ''}`;
    // OS payloads intentionally contain no transcript/form/tool/terminal text, even with previews on.
    const categoryTitle = notification.kind === 'result' ? 'Bot task completed' : notification.kind === 'machine' ? 'Machine status changed' : 'Your Bot needs attention';
    const title = user.notifications.previews ? categoryTitle : 'Lemon Bot';
    const payload: P.PushPayload = { version: 1, notificationId: notification.id, workspaceId: workspace.id, conversationId: notification.conversationId, entryId: notification.entryId, title, body: 'Open Lemon Bot to view the update.', target, deepLink };
    const viewedConversationId = target.kind === 'entry' ? target.taskConversationId ?? notification.conversationId : notification.conversationId;
    const sessions = services.store.list<P.AuthSession>('authSessions', s => s.userId === user.id && (s.expiresAtMs === null || s.expiresAtMs > services.now()));
    for (const device of services.store.list<P.Device>('devices', d => d.userId === user.id && d.pushEnabled)) {
      if (!sessions.some(s => s.deviceId === device.id && services.store.get<{ revoked: boolean }>('sessionSecrets', s.id)?.revoked === false)) continue;
      const presence = services.store.metadata<{ userId: string; foreground: boolean; conversationId: string | null; updatedAtMs: number }>(`presence:${device.id}`);
      if (viewedConversationId && presence?.userId === user.id && presence.foreground && presence.conversationId === viewedConversationId && services.now() - presence.updatedAtMs >= 0 && services.now() - presence.updatedAtMs < 60_000) continue;
      const encrypted = services.store.metadata<string>(`devicePush:${device.id}`); if (!encrypted) continue;
      const stillAllowed = (): P.User | null => {
        const currentUser = services.store.get<P.User>('users', user.id), currentMember = services.store.get<P.Member>('members', member.id);
        if (services.store.metadata<string>(`devicePush:${device.id}`) !== encrypted || !services.store.get<P.Device>('devices', device.id)?.pushEnabled || !currentUser?.notifications.enabled || !currentMember?.enabled || !services.store.get<P.Workspace>('workspaces', workspace.id)?.enabled) return null;
        if ((notification.kind === 'result' && !currentUser.notifications.completed) || (['approval', 'question', 'human_step'].includes(notification.kind) && !currentUser.notifications.needsInput)) return null;
        principal.role = currentMember.role;
        if (!services.store.list<P.AuthSession>('authSessions', s => s.userId === user.id && s.deviceId === device.id && (s.expiresAtMs === null || s.expiresAtMs > services.now())).some(s => services.store.get<{ revoked: boolean }>('sessionSecrets', s.id)?.revoked === false)) return null;
        const currentPresence = services.store.metadata<{ userId: string; foreground: boolean; conversationId: string | null; updatedAtMs: number }>(`presence:${device.id}`);
        if (viewedConversationId && currentPresence?.userId === user.id && currentPresence.foreground && currentPresence.conversationId === viewedConversationId && services.now() - currentPresence.updatedAtMs >= 0 && services.now() - currentPresence.updatedAtMs < 60_000) return null;
        return canDeliverTarget() ? currentUser : null;
      };
      try {
        const registration = services.decrypt<P.PushRegistration>(encrypted); await validatePushRegistration(registration, options);
        let result: PushResponse;
        if (registration.kind === 'apns') {
          if (!providerCapabilities().apns || !apnsKey) continue;
          const origin = registration.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com';
          if (!stillAllowed() || !(await services.integrations.effectivePolicy(principal, notification.botId ?? undefined)).productAccess) continue;
          const currentUser = stillAllowed(); if (!currentUser) continue;
          if (!apnsJwt || services.now() - apnsJwt.createdAt >= 50 * 60_000 || services.now() < apnsJwt.createdAt) apnsJwt = { value: apnsToken(env.LEMON_BOT_APNS_KEY_ID!, env.LEMON_BOT_APNS_TEAM_ID!, apnsKey, services.now()), createdAt: services.now() };
          const currentTitle = currentUser.notifications.previews ? categoryTitle : 'Lemon Bot', deliveryPayload = currentTitle === payload.title ? payload : { ...payload, title: currentTitle };
          const body = Buffer.from(JSON.stringify({ ...deliveryPayload, aps: { alert: { title: deliveryPayload.title, body: deliveryPayload.body }, ...(currentUser.notifications.sound ? { sound: 'default' } : {}) } })); if (body.length > 4096) fail('too_large', 'APNs payload is too large.');
          result = await (options.sendAPNs ?? ((o, p, h, b) => sendAPNs(o, p, h, b, timeout)))(origin, `/3/device/${registration.token}`, { authorization: `bearer ${apnsJwt.value}`, 'apns-topic': registration.topic, 'apns-push-type': 'alert', 'apns-priority': '10', 'apns-expiration': String(Math.floor(services.now() / 1000) + 3600), 'content-type': 'application/json' }, body);
          if (result.status === 403 && result.reason === 'ExpiredProviderToken') apnsJwt = null;
        } else {
          if (!vapidReady) continue;
          const dest = await destination(registration.endpoint, options);
          if (!stillAllowed() || !(await services.integrations.effectivePolicy(principal, notification.botId ?? undefined)).productAccess) continue;
          const currentUser = stillAllowed(); if (!currentUser) continue;
          const currentTitle = currentUser.notifications.previews ? categoryTitle : 'Lemon Bot', deliveryPayload = currentTitle === payload.title ? payload : { ...payload, title: currentTitle };
          const body = encryptWebPush(Buffer.from(JSON.stringify(deliveryPayload)), registration), jwt = vapidToken(dest.url.origin, env.LEMON_BOT_VAPID_SUBJECT!, env.LEMON_BOT_VAPID_PUBLIC_KEY!, env.LEMON_BOT_VAPID_PRIVATE_KEY!, services.now());
          result = await (options.sendWebPush ?? ((u, a, h, b) => sendWebPush(u, a, h, b, timeout)))(dest.url, dest.address, { Authorization: `vapid t=${jwt}, k=${env.LEMON_BOT_VAPID_PUBLIC_KEY}`, 'Content-Encoding': 'aes128gcm', 'Content-Type': 'application/octet-stream', TTL: '3600', 'Content-Length': String(body.length) }, body);
        }
        const registeredAt = services.store.metadata<number>(`devicePushRegisteredAt:${device.id}`);
        const invalid = registration.kind === 'web_push' ? [404,410].includes(result.status) : (result.status === 410 && (result.timestamp === undefined || registeredAt === null || result.timestamp >= registeredAt)) || (result.status === 400 && ['BadDeviceToken', 'DeviceTokenNotForTopic'].includes(result.reason ?? ''));
        if (invalid) services.store.transaction(() => {
          if (services.store.metadata<string>(`devicePush:${device.id}`) !== encrypted) return;
          services.store.setMetadata(`devicePush:${device.id}`, null); services.store.setMetadata(`devicePushRegisteredAt:${device.id}`, null);
          const current = services.store.get<P.Device>('devices', device.id); if (!current) return;
          const disabled = services.update(current, { pushEnabled: false }); services.store.put('devices', disabled); services.events.emit('device.upserted', disabled, { userIds: [user.id] });
        });
        services.audit(principal, 'push.deliver', notification.id, result.status >= 200 && result.status < 300 ? 'succeeded' : 'failed', { provider: registration.kind, deviceId: device.id, status: result.status });
      } catch { services.audit(principal, 'push.deliver', notification.id, 'failed', { deviceId: device.id }); }
    }
  }
  const push: PushServices = { emitProviderNotifications, providerCapabilities, inventory: () => [{ id: 'apns', configured: providerCapabilities().apns }, { id: 'web_push', configured: providerCapabilities().webPush }] };
  if (overrides === undefined) pushInstances.set(services, push);
  return push;
}
