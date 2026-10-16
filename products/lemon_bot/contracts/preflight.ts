import type { BackendIdentity, SetupStatus } from './protocol.ts';

export type BotPreflightCode = 'invalid_origin' | 'loopback_origin' | 'tls_required' | 'unavailable' | 'wrong_service' | 'pairing_unavailable' | 'instance_mismatch' | 'workspace_mismatch';
export class BotPreflightError extends Error {
  constructor(readonly code: BotPreflightCode, message: string) { super(message); this.name = 'BotPreflightError'; }
}
export type BotOriginUse = 'phone' | 'same-machine';
const invalidOrigin = () => new BotPreflightError('invalid_origin', 'Use an exact product origin without credentials, path, query or fragment.');

/** A network alias is not identity. Phone origins always require system-validated HTTPS. */
export function validateBotOrigin(value: string, use: BotOriginUse = 'phone'): string {
  if (typeof value !== 'string' || value.length > 2048 || /[\u0000-\u0020\u007f\\]/.test(value)) throw invalidOrigin();
  let url: URL;
  try { url = new URL(value); } catch { throw invalidOrigin(); }
  if (value !== url.origin || url.username || url.password || url.pathname !== '/' || url.search || url.hash) throw invalidOrigin();
  const host = url.hostname.toLowerCase().replace(/\.$/, '');
  // WHATWG URL canonicalizes abbreviated/numeric IPv4 and IPv6 before these checks.
  const loopback = host === 'localhost' || host.endsWith('.localhost') || /^127\./.test(host)
    || host === '[::1]' || /^\[::ffff:7f[0-9a-f]{2}:[0-9a-f]+\]$/.test(host)
    || host === '0.0.0.0' || host === '[::]';
  if (use === 'phone' && loopback) throw new BotPreflightError('loopback_origin', 'A physical phone cannot use this machine-local origin. Configure a reachable HTTPS Bot origin.');
  if (url.protocol !== 'https:' && !(use === 'same-machine' && loopback && url.protocol === 'http:')) {
    throw new BotPreflightError('tls_required', 'Pairing requires HTTPS with normal certificate validation; an overlay is not a TLS bypass.');
  }
  return url.origin;
}

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw wrongService();
  return value as Record<string, unknown>;
}
function wrongService(): BotPreflightError {
  return new BotPreflightError('wrong_service', 'This origin is not the supported Lemon Bot product API (/v1/setup). Check the backend service and proxy route.');
}
function identifier(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= 128 && !/[\u0000-\u001f\u007f]/.test(value);
}
function descriptor(value: unknown): Record<string, unknown> {
  const row = object(value);
  if (row.product !== 'lemon_bot' || row.apiVersion !== 1 || !identifier(row.instanceId)
    || typeof row.version !== 'string' || !row.version || row.version.length > 128 || typeof row.publicUrl !== 'string'
    || typeof object(row.capabilities).pairing !== 'boolean') throw wrongService();
  return row;
}

/** Validate the public fingerprint before sending any pairing proof or product credential. */
export function validateBotSetup(value: unknown, expectedInstanceId: string, use: BotOriginUse = 'phone'): SetupStatus {
  const row = descriptor(value);
  if (typeof row.setupRequired !== 'boolean') throw wrongService();
  if (!identifier(expectedInstanceId) || row.instanceId !== expectedInstanceId) {
    throw new BotPreflightError('instance_mismatch', 'The backend identity changed or does not match the configured Bot backend. Reconnect explicitly; do not replace it automatically.');
  }
  validateBotOrigin(row.publicUrl as string, use);
  if (row.setupRequired || !object(row.capabilities).pairing) throw new BotPreflightError('pairing_unavailable', 'This Bot backend is not configured for phone pairing.');
  return value as SetupStatus;
}

/** Compare authenticated identity after completion/reconnect, before installing credentials or syncing. */
export function validateBotIdentity(value: unknown, expected: Pick<BackendIdentity, 'instanceId' | 'workspaceId'>, use: BotOriginUse = 'phone'): BackendIdentity {
  const row = descriptor(value);
  if (!identifier(row.workspaceId)) throw wrongService();
  if (!identifier(expected.instanceId) || row.instanceId !== expected.instanceId) throw new BotPreflightError('instance_mismatch', 'The backend identity changed or does not match the configured Bot backend.');
  if (!identifier(expected.workspaceId) || row.workspaceId !== expected.workspaceId) throw new BotPreflightError('workspace_mismatch', 'This is a different Bot workspace. Keep the existing connection and review the intended backend.');
  validateBotOrigin(row.publicUrl as string, use);
  if (!object(row.capabilities).pairing) throw new BotPreflightError('pairing_unavailable', 'This Bot backend does not support pairing.');
  return value as BackendIdentity;
}

export interface BotPreflightOptions {
  origin: string;
  expectedInstanceId: string;
  use?: BotOriginUse;
  /** Only the caller's product session, never an operator credential. Omit on phone before completion. */
  session?: { token: string; workspaceId: string };
  signal?: AbortSignal;
  /** Trusted transport seam: implementations MUST preserve TLS validation and refuse redirects. */
  fetch?: typeof fetch;
}
export interface BotPreflightResult { origin: string; setup: SetupStatus; identity: BackendIdentity | null }

function requireSystemTLS(): void {
  const runtime = globalThis as typeof globalThis & { process?: { env?: Record<string, string | undefined> } };
  if (runtime.process?.env?.NODE_TLS_REJECT_UNAUTHORIZED === '0' || runtime.process?.env?.BUN_TLS_REJECT_UNAUTHORIZED === '0') {
    throw new BotPreflightError('tls_required', 'Remove the runtime TLS verification bypass before pairing.');
  }
}
async function readDescriptor(response: Response): Promise<unknown> {
  if (response.status !== 200 || response.redirected || !/^application\/json(?:\s*;|$)/i.test(response.headers.get('Content-Type') ?? '')) {
    await response.body?.cancel(); throw wrongService();
  }
  const reader = response.body?.getReader();
  if (!reader) throw wrongService();
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 16384) { await reader.cancel(); throw wrongService(); }
      chunks.push(value);
    }
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)) as unknown;
  } catch (error) { if (error instanceof BotPreflightError) throw error; throw wrongService(); }
  finally { reader.releaseLock(); }
}

/** Bounded read-only probes. No mutation retries, discovery, redirects or TLS exceptions. */
export async function preflightBotOrigin(options: BotPreflightOptions): Promise<BotPreflightResult> {
  requireSystemTLS();
  const use = options.use ?? 'phone';
  const origin = validateBotOrigin(options.origin, use);
  const signal = options.signal ? AbortSignal.any([options.signal, AbortSignal.timeout(10000)]) : AbortSignal.timeout(10000);
  const fetcher = options.fetch ?? globalThis.fetch.bind(globalThis);
  async function probe(path: string, token?: string): Promise<unknown> {
    try {
      const url = `${origin}/v1/${path}`;
      const response = await fetcher(url, { method: 'GET', headers: { Accept: 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
        redirect: 'manual', credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer', signal });
      if (response.url && response.url !== url) { await response.body?.cancel(); throw wrongService(); }
      return await readDescriptor(response);
    } catch (error) {
      if (error instanceof BotPreflightError) throw error;
      throw new BotPreflightError('unavailable', 'Cannot reach the Bot API with verified TLS. Check backend, Tailscale login/tailnet/ACL, DNS and certificate trust.');
    }
  }
  const setup = validateBotSetup(await probe('setup'), options.expectedInstanceId, use);
  const identity = options.session ? validateBotIdentity(await probe('identity', options.session.token),
    { instanceId: options.expectedInstanceId, workspaceId: options.session.workspaceId }, use) : null;
  return { origin, setup, identity };
}
