import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Principal, RequestContext } from '../core/services';
import { ApiError } from '../core/errors';

export { ApiError as IntegrationError } from '../core/errors';
export const randomToken = (bytes = 32): string => randomBytes(bytes).toString('base64url');
export const sha256 = (value: string | Uint8Array): string => createHash('sha256').update(value).digest('base64url');
export const hmac = (key: string | Uint8Array, value: string | Uint8Array): string => createHmac('sha256', key).update(value).digest('hex');
export function secureEqual(a: string, b: string): boolean { const aa = Buffer.from(a); const bb = Buffer.from(b); return aa.length === bb.length && timingSafeEqual(aa, bb); }
export function principal(context: RequestContext): Principal { if (!context.user) throw new ApiError('unauthenticated', 'Sign in to continue.'); return context.user; }
export function unavailable(prerequisite: string): never { throw new ApiError('capability_unavailable', prerequisite); }
export function providerFailure(message = 'Configured provider request failed.', uncertain = false): never { throw new ApiError(uncertain ? 'outcome_unknown' : 'upstream_unavailable', message, !uncertain); }
export function safeSummary(value: unknown, max = 512): string {
  const text = typeof value === 'string' ? value : 'Provider operation failed.';
  return text.replace(/(?:Bearer\s+|(?:token|password|secret|api[_-]?key)\s*[:=]\s*)[^\s,;]+/gi, '[redacted]').replace(/https?:\/\/[^\s]+/g, '[provider URL]').slice(0, max);
}
export function scrub(value: unknown): P.JSONValue {
  if (value === null || typeof value === 'boolean') return value;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  if (typeof value === 'string') return safeSummary(value, 65536);
  if (Array.isArray(value)) return value.slice(0, 1000).map(scrub);
  if (typeof value === 'object') { const result: P.JSONObject = {}; for (const [key, item] of Object.entries(value)) { if (/password|secret|authorization|cookie|access.?token|refresh.?token|private.?key|client.?secret/i.test(key)) result[key] = '[redacted]'; else result[key] = scrub(item); } return result; }
  return null;
}
export function isPublicAddress(address: string): boolean {
  const ip = address.toLowerCase();
  if (isIP(ip) === 4) { const [a, b] = ip.split('.').map(Number); return !(a === 0 || a === 10 || a === 127 || a === 169 && b === 254 || a === 172 && b! >= 16 && b! <= 31 || a === 192 && (b === 168 || b === 0) || a === 100 && b! >= 64 && b! <= 127 || a! >= 224 || a === 198 && (b === 18 || b === 19)); }
  if (isIP(ip) === 6) { if (ip.startsWith('::ffff:')) return isPublicAddress(ip.slice(7)); return !(ip === '::' || ip === '::1' || ip.startsWith('fc') || ip.startsWith('fd') || /^fe[89ab]/.test(ip) || ip.startsWith('ff') || ip.startsWith('2001:db8:')); }
  return false;
}
export interface ProviderRequestOptions { allowedOrigins: string[]; allowPrivate?: boolean; timeoutMs?: number; maxBytes?: number; mutation?: boolean; fetch?: typeof globalThis.fetch; beforeDispatch?: () => void }
export function pinnedUrl(input: string, origins: readonly string[]): URL {
  let url: URL; try { url = new URL(input); } catch { throw new ApiError('invalid_request', 'Provider URL is invalid.'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.hash || !origins.includes(url.origin)) throw new ApiError('policy_denied', 'Provider destination is not operator-approved.');
  return url;
}
export async function providerRequest(input: string, init: RequestInit, options: ProviderRequestOptions): Promise<Response> {
  const url = pinnedUrl(input, options.allowedOrigins);
  if (!options.allowPrivate) { const addresses = await lookup(url.hostname, { all: true }).catch(() => []); if (!addresses.length || addresses.some(row => !isPublicAddress(row.address))) throw new ApiError('policy_denied', 'Provider destination must resolve only to public addresses.'); }
  const timeout = AbortSignal.timeout(options.timeoutMs ?? 30000);
  const signal = init.signal ? AbortSignal.any([init.signal, timeout]) : timeout;
  signal.throwIfAborted();
  options.beforeDispatch?.();
  try { const response = await (options.fetch ?? globalThis.fetch)(url, { ...init, redirect: 'error', signal }); if (response.status >= 300 && response.status < 400) providerFailure('Provider redirects are not accepted.', options.mutation); return response; }
  catch (error) { if (error instanceof ApiError) throw error; providerFailure('Provider connection was interrupted.', options.mutation); }
}
export async function boundedBytes(response: Response, maxBytes = 1024 * 1024): Promise<Uint8Array> {
  const declared = response.headers.get('content-length'); if (declared && Number(declared) > maxBytes) throw new ApiError('too_large', 'Provider response exceeds the size limit.');
  const reader = response.body?.getReader(); if (!reader) return new Uint8Array(); const chunks: Uint8Array[] = []; let length = 0;
  try { while (true) { const part = await reader.read(); if (part.done) break; length += part.value.byteLength; if (length > maxBytes) { await reader.cancel(); throw new ApiError('too_large', 'Provider response exceeds the size limit.'); } chunks.push(part.value); } } finally { reader.releaseLock(); }
  const result = new Uint8Array(length); let offset = 0; for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; } return result;
}
export async function fetchJson<T = unknown>(input: string, init: RequestInit, options: ProviderRequestOptions): Promise<T> {
  const response = await providerRequest(input, init, options); const bytes = await boundedBytes(response, options.maxBytes); if (!response.ok) { if (response.status === 429) throw new ApiError('rate_limited', 'Provider rate limit reached.'); if ([401, 403].includes(response.status)) throw new ApiError('capability_unavailable', 'Configured provider credentials or permissions were refused.'); providerFailure('Provider returned a failure.', options.mutation && response.status >= 500); }
  try { return JSON.parse(new TextDecoder().decode(bytes)) as T; } catch { providerFailure('Provider returned malformed JSON.', options.mutation); }
}
export function privateMetadata<T>(services: BackendServices, key: string): T | null { const encrypted = services.store.metadata<string>(key); return encrypted === null ? null : services.decrypt<T>(encrypted); }
export function savePrivateMetadata(services: BackendServices, key: string, value: unknown): void { services.store.setMetadata(key, services.encrypt(value)); }
export function userPrincipal(services: BackendServices, userId: string): Principal { const member = services.auth.member(userId); if (!member.enabled) throw new ApiError('policy_denied', 'Workspace membership is disabled.'); return { kind: 'user', id: userId, userId, workspaceId: services.store.metadata<string>('workspaceId') ?? '', role: member.role, sessionId: null, botId: null, deviceId: null }; }

export function assertActiveAccount(services: BackendServices, userId: string, externalEffect = false): void {
  const member = services.store.list<P.Member>('members', member => member.userId === userId)[0];
  if (!services.store.get<P.User>('users', userId) || !member?.enabled || services.store.metadata(`accountDeletion:${userId}`)) throw new ApiError(externalEffect ? 'outcome_unknown' : 'conflict', 'Account deletion or deprovisioning fences new provider authorization; reconcile the existing account operation.', !externalEffect, { resourceIds: [userId] });
}
