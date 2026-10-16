import { randomBytes } from 'node:crypto';
import type { AuthResult, BackendIdentity, Pairing, PairingIssued } from '../../../contracts/protocol';
import { BotPreflightError, preflightBotOrigin, requireBotSystemTLS, validateBotIdentity, validateBotOrigin, validateBotSetup } from '../../../contracts/preflight';
import { parsePairUrl } from '../../../sdk/ts/src/pairing';

class ConnectError extends Error {}
const nonce = () => randomBytes(32).toString('base64url');
const usage = 'Usage: lemon connect iphone --backend ORIGIN [--origin HTTPS_ORIGIN]';
const safe = (value: string) => value.replace(/[\p{Cc}\p{Cf}]/gu, '').slice(0, 256);

export interface ConnectTerminal {
  interactive: boolean;
  write(message: string): void;
  /** Deliberately secret-bearing, terminal-only output; never a diagnostic/log sink. */
  sensitive(message: string): void;
  read(label: string, hidden?: boolean, deadline?: number): Promise<string>;
}
export interface ConnectOptions {
  terminal?: ConnectTerminal;
  fetch?: typeof fetch;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
}

/** Raw terminal input never enters a shell, readline history, or the process argument vector. */
export function terminal(): ConnectTerminal {
  return {
    interactive: Boolean(process.stdin.isTTY && process.stdout.isTTY && process.stderr.isTTY),
    write: message => { process.stdout.write(`${message}\n`); },
    sensitive: message => { process.stdout.write(`${message}\n`); },
    read(label, hidden = false, deadline) {
      process.stdout.write(label);
      const { promise, resolve, reject } = Promise.withResolvers<string>();
      let value = '';
      const wasRaw = process.stdin.isRaw;
      const timer = deadline === undefined ? undefined : setTimeout(() => finish(new ConnectError('Pairing expired; start again explicitly.')), Math.max(0, deadline - Date.now()));
      function finish(error?: Error) {
        clearTimeout(timer);
        process.stdin.off('data', data); process.stdin.off('end', ended); process.stdin.off('error', ended);
        process.stdin.setRawMode(wasRaw); process.stdin.pause();
        process.stdout.write('\n');
        if (error) reject(error); else resolve(value);
      }
      const ended = () => finish(new ConnectError('Terminal input ended; no approval was given.'));
      function data(chunk: Buffer) {
        for (const character of chunk.toString('utf8')) {
          if (character === '\u0003' || character === '\u0004') { finish(new ConnectError('Cancelled; no automatic approval or mutation retry.')); return; }
          if (character === '\r' || character === '\n') { finish(); return; }
          if (character === '\u007f' || character === '\b') { value = Array.from(value).slice(0, -1).join(''); if (!hidden) process.stdout.write('\b \b'); }
          else if (!/[\p{Cc}\p{Cf}]/u.test(character)) { value += character; if (!hidden) process.stdout.write(character); }
          if (Buffer.byteLength(value) > 1024) { finish(new ConnectError('Input is too long.')); return; }
        }
      }
      process.stdin.setRawMode(true); process.stdin.resume();
      process.stdin.on('data', data); process.stdin.once('end', ended); process.stdin.once('error', ended);
      return promise;
    },
  };
}

function argumentsFor(args: string[]): { backend: string; origin?: string } | null {
  if (args[0] !== 'iphone') return null;
  const values: Record<string, string> = {};
  for (let index = 1; index < args.length; index += 2) {
    const key = args[index], value = args[index + 1];
    if ((key !== '--backend' && key !== '--origin') || values[key] !== undefined || !value || value.startsWith('--')) return null;
    values[key] = value;
  }
  return values['--backend'] ? { backend: values['--backend'], origin: values['--origin'] } : null;
}

/** A small bounded product transport: no cookies, redirects, raw-body diagnostics or mutation retries. */
function transport(fetcher: typeof fetch) {
  return async function request<T>(origin: string, path: string, token?: string, body?: unknown, method: 'GET' | 'POST' | 'DELETE' = body === undefined ? 'GET' : 'POST'): Promise<T> {
    const url = `${origin}/v1/${path}`;
    let response: Response;
    try {
      response = await fetcher(url, { method,
        headers: { Accept: 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }), redirect: 'manual', credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer', signal: AbortSignal.timeout(10000) });
    } catch { throw new ConnectError('Product request unavailable or outcome unknown. Check the selected backend; mutations are never blindly repeated.'); }
    const expectedStatus = path === 'pairings' && body !== undefined ? 201 : 200;
    if ((response.url && response.url !== url) || response.redirected || response.status !== expectedStatus || !/^application\/json(?:\s*;|$)/i.test(response.headers.get('Content-Type') ?? '')) {
      await response.body?.cancel();
      throw new ConnectError('Product request refused. Check the Bot route, owner login/authority and current pairing state in the product UI; no mutation was retried.');
    }
    const reader = response.body?.getReader();
    if (!reader) throw new ConnectError('Invalid product response.');
    let content = '', size = 0;
    const decoder = new TextDecoder('utf-8', { fatal: true });
    try {
      while (true) {
        const { done, value } = await reader.read(); if (done) break;
        size += value.byteLength;
        if (size > 16384) { await reader.cancel(); throw new Error(); }
        content += decoder.decode(value, { stream: true });
      }
      content += decoder.decode();
      return JSON.parse(content) as T;
    } catch { throw new ConnectError('Invalid or unavailable product response; no mutation was retried.'); }
    finally { reader.releaseLock(); }
  };
}

function pairing(value: Pairing, expected: Pairing, now: number): Pairing {
  if (!value || value.id !== expected.id || value.workspaceId !== expected.workspaceId || value.ownerUserId !== expected.ownerUserId
    || value.backendUrl !== expected.backendUrl || value.expiresAtMs !== expected.expiresAtMs
    || !Number.isSafeInteger(value.revision) || value.revision < 1
    || !['waiting', 'pending_approval', 'approved', 'consumed', 'denied', 'expired'].includes(value.status)) throw new ConnectError('Pairing identity changed; review the intended backend explicitly.');
  if (value.expiresAtMs <= now || value.status === 'expired') throw new ConnectError('Pairing expired; create a new request explicitly.');
  return value;
}

export async function runConnect(args: string[], options: ConnectOptions = {}): Promise<number> {
  const io = options.terminal ?? terminal();
  const selected = argumentsFor(args);
  if (!selected) { io.write(usage); return 2; }
  if (!io.interactive) {
    io.write('Pairing requires an interactive private terminal for hidden owner login, sensitive one-time output and explicit device/code approval. Run lemon connect iphone in a terminal; no --yes or piped approval is supported.');
    return 1;
  }
  const fetcher = options.fetch ?? globalThis.fetch.bind(globalThis);
  const request = transport(fetcher), now = options.now ?? Date.now;
  const sleep = options.sleep ?? (ms => Bun.sleep(ms));
  let auth: AuthResult | undefined, backend: string | undefined;
  try {
    requireBotSystemTLS();
    // This public fingerprint is untrusted until login to the explicitly selected backend.
    backend = validateBotOrigin(selected.backend, 'same-machine');
    const descriptor = await request<Record<string, unknown>>(backend, 'setup');
    if (descriptor.setupRequired === true) throw new ConnectError('Complete owner setup at the selected Bot product UI using its existing private one-use setup code, then rerun this command. This command never starts or replaces a backend.');
    const setup = validateBotSetup(descriptor, descriptor.instanceId as string, 'same-machine');
    io.write(`Selected Bot backend: ${backend}\nConfirm this is your intended running workspace. No operator token is accepted.`);
    const email = await io.read('Owner email: ');
    const password = await io.read('Owner password (hidden; existing product account): ', true);
    auth = await request<AuthResult>(backend, 'auth/login', undefined, { email, password, clientNonce: nonce() });
    if (!auth || typeof auth.token !== 'string' || !auth.token || !auth.workspace?.id || !auth.user?.id) throw new ConnectError('Owner login did not return a valid product session.');
    const baseline = validateBotIdentity(await request<BackendIdentity>(backend, 'identity', auth.token), { instanceId: setup.instanceId, workspaceId: auth.workspace.id }, 'same-machine');
    if (auth.member?.role !== 'owner' || !auth.member.enabled || auth.workspace.ownerUserId !== auth.user.id) throw new ConnectError('Only the current workspace owner can pair a phone. Sign in through the existing owner account; operator credentials cannot substitute.');
    const origin = validateBotOrigin(selected.origin ?? baseline.publicUrl);
    if (origin !== baseline.publicUrl) throw new ConnectError('The phone origin must match this backend’s configured publicUrl, because the owner-issued QR uses that exact origin. Review the selected backend configuration; no routes or ports were changed.');
    await preflightBotOrigin({ origin, expectedInstanceId: baseline.instanceId, session: { token: auth.token, workspaceId: baseline.workspaceId }, fetch: fetcher });
    io.write(`Verified phone origin: ${origin}\nInstance: ${safe(baseline.instanceId)}\nWorkspace: ${safe(baseline.workspaceId)} (${safe(auth.workspace.name)})`);
    if (await io.read('Create a sensitive one-use pairing link for this workspace? Type create: ') !== 'create') throw new ConnectError('Cancelled; no pairing link was created.');
    const issued = await request<PairingIssued>(backend, 'pairings', auth.token, { clientNonce: nonce() });
    let link;
    try { link = parsePairUrl(issued?.pairUrl); } catch { throw new ConnectError('Invalid owner-issued pairing payload; nothing was displayed or approved.'); }
    const initial = issued.pairing;
    if (link.backendUrl !== origin || link.instanceId !== baseline.instanceId || link.workspaceId !== baseline.workspaceId
      || !initial || typeof initial.id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(initial.id)
      || initial.workspaceId !== baseline.workspaceId || initial.ownerUserId !== auth.user.id || initial.backendUrl !== origin
      || initial.status !== 'waiting' || !Number.isSafeInteger(initial.expiresAtMs) || initial.expiresAtMs <= now() || initial.expiresAtMs > now() + 300000) throw new ConnectError('Owner-issued pairing does not match the verified backend/workspace or expiry.');
    const path = `pairings/${encodeURIComponent(initial.id)}`;
    io.write(`Request: ${safe(initial.id)}\nExpires: ${new Date(initial.expiresAtMs).toISOString()}\nSENSITIVE ONE-TIME OUTPUT — do not record, log, screenshot or share. Paste only into Lemon Bot on your iPhone, then review and Request connection.`);
    io.sensitive(issued.pairUrl);
    let current = initial;
    while (current.status === 'waiting') {
      if (now() >= initial.expiresAtMs) throw new ConnectError('Pairing expired before a phone requested connection.');
      await sleep(Math.min(2000, initial.expiresAtMs - now()));
      current = pairing(await request<Pairing>(backend, path, auth.token), initial, now());
    }
    if (current.status !== 'pending_approval' || typeof current.deviceName !== 'string' || !/^\d{6}$/.test(current.verificationCode ?? '')) throw new ConnectError('This request is no longer awaiting your approval; review its state in the product UI.');
    io.write(`Request: ${safe(current.id)}\nDevice: ${safe(current.deviceName)}\nVerification code: ${current.verificationCode}\nCompare this exact device/code with your iPhone. Approval authorizes a separate revocable phone session.`);
    const answer = await io.read(`Type approve ${current.verificationCode} to approve, or deny: `, false, initial.expiresAtMs);
    const approve = answer === `approve ${current.verificationCode}`;
    // Every other answer fails closed by explicitly denying this exact pending revision.
    const body = { clientNonce: nonce(), revision: current.revision, ...(approve ? { verificationCode: current.verificationCode! } : {}) };
    try { await request<Pairing>(backend, `${path}/${approve ? 'approve' : 'deny'}`, auth.token, body); }
    catch { io.write('Decision response unavailable; reconciling only this request with read-only status. No approval or credential issuance will be repeated.'); }
    while (now() < initial.expiresAtMs) {
      current = pairing(await request<Pairing>(backend, path, auth.token), initial, now());
      if (current.status === 'denied') { io.write('Pairing denied. No phone session was authorized by this command.'); return approve ? 1 : 0; }
      if (current.status === 'consumed') {
        if (!approve) throw new ConnectError('A different client completed this request; review/revoke the device in the product UI.');
        await preflightBotOrigin({ origin, expectedInstanceId: baseline.instanceId, session: { token: auth.token, workspaceId: baseline.workspaceId }, fetch: fetcher });
        io.write('Phone completed pairing to the verified Bot workspace. Its independent session remains active when this terminal or the Mac UI closes; revoke it in Account → Devices/Sessions.');
        return 0;
      }
      await sleep(Math.min(2000, initial.expiresAtMs - now()));
    }
    throw new ConnectError('Pairing completion was not verified before expiry. Review the exact request/device in the product UI; do not blindly approve again.');
  } catch (error) {
    io.write(error instanceof ConnectError || error instanceof BotPreflightError ? error.message : 'Pairing could not be verified. Check the selected Bot backend and owner account; no mutation was retried.');
    return 1;
  } finally {
    // This transient login is never persisted and is not the phone credential.
    if (backend && auth?.token && auth.session?.id) {
      try { await request(backend, `auth/sessions/${encodeURIComponent(auth.session.id)}`, auth.token, { clientNonce: nonce() }, 'DELETE'); }
      catch { io.write('Temporary CLI session revocation could not be confirmed. Revoke that login in Account → Sessions; its bounded expiry still applies.'); }
    }
  }
}

if (import.meta.main) process.exitCode = await runConnect(process.argv.slice(2));
