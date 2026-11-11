import { randomBytes } from 'node:crypto';
import { lstatSync, readdirSync, unlinkSync } from 'node:fs';
import { hostname, userInfo } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import type * as P from '../../../contracts/protocol';
import { opaqueToken } from './auth';
import { fail } from './errors';
import { requireLocalAccess } from './local-access';
import type { BackendServices, EntityStore, Route } from './services';
import { parse, z } from './validation';

export const localSignInFragment = 'lemonbot-signin';
export const localTicketLifetimeMs = { browser: 60_000, terminal: 300_000 } as const;
export const maxOutstandingLocalTickets = 5;
export const handoffDirectory = (dataDir: string) => join(dataDir, 'handoff');
export type LocalTicketChannel = keyof typeof localTicketLifetimeMs;
export interface LocalTicketRow { id: string; digest: string; channel: LocalTicketChannel; origin: string; displayName: string | null; handoffFile: string | null; createdAtMs: number; expiresAtMs: number; redeemedAtMs: number | null }
export interface LocalTicketDeps { store: EntityStore; now(): number; digest(value: unknown): string; dataDir: string }
export interface LocalTicketIssued { id: string; url: string; expiresAtMs: number; handoffFile: string | null }
const handoffName = /^open-lst_[A-Za-z0-9_-]+\.html$/;

/** Never traverse a symlinked handoff directory or unlink an arbitrary persisted path. */
function unlinkHandoff(deps: LocalTicketDeps, path: string | null): void {
  if (!path) return;
  const directory = resolve(handoffDirectory(deps.dataDir));
  const target = resolve(path);
  if (dirname(target) !== directory || !handoffName.test(target.slice(directory.length + 1))) return;
  try {
    const parent = lstatSync(directory);
    if (!parent.isDirectory() || parent.isSymbolicLink()) return;
    if (lstatSync(target).isFile()) unlinkSync(target);
  } catch { /* Cleanup is best effort; credentials expire independently of files. */ }
}

// Synchronous filesystem work makes issuance's sweep finish before the cap is checked,
// including when the issuer is a second CLI process. The public sweep remains awaitable.
function sweep(deps: LocalTicketDeps): void {
  const now = deps.now();
  deps.store.transaction(() => {
    for (const row of deps.store.list<LocalTicketRow>('signInTickets')) {
      if (row.expiresAtMs <= now) unlinkHandoff(deps, row.handoffFile);
      if (row.expiresAtMs < now - 60_000) deps.store.remove('signInTickets', row.id);
    }
  });
  const directory = handoffDirectory(deps.dataDir);
  try {
    const parent = lstatSync(directory);
    if (!parent.isDirectory() || parent.isSymbolicLink()) return;
    for (const name of readdirSync(directory)) {
      if (!handoffName.test(name)) continue;
      const path = join(directory, name);
      try { if (lstatSync(path).mtimeMs < now - 600_000) unlinkHandoff(deps, path); } catch { /* Concurrent cleanup. */ }
    }
  } catch { /* A headless installation need not have handoff files. */ }
}

/** Inserts a digest only. The caller delivers the URL privately and revokes on failure. */
export function issueLocalSignInTicket(deps: LocalTicketDeps, input: { origin: string; channel: LocalTicketChannel; displayName?: string; withHandoffFile: boolean }): LocalTicketIssued {
  const origin = new URL(input.origin);
  if (origin.origin !== input.origin || origin.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(origin.hostname)) fail('capability_unavailable', 'Sign-in links work only when Lemon Bot listens on 127.0.0.1.');
  sweep(deps);
  return deps.store.transaction(() => {
    const now = deps.now();
    if (deps.store.list<LocalTicketRow>('signInTickets', row => row.redeemedAtMs === null && row.expiresAtMs > now).length >= maxOutstandingLocalTickets) fail('rate_limited', 'Five sign-in links are already waiting. Use one or wait for it to expire.');
    const id = `lst_${randomBytes(18).toString('base64url')}`;
    const ticket = opaqueToken();
    const handoffFile = input.withHandoffFile ? join(handoffDirectory(deps.dataDir), `open-${id}.html`) : null;
    const expiresAtMs = now + localTicketLifetimeMs[input.channel];
    deps.store.put<LocalTicketRow>('signInTickets', { id, digest: deps.digest(ticket), channel: input.channel, origin: input.origin, displayName: input.displayName ?? null, handoffFile, createdAtMs: now, expiresAtMs, redeemedAtMs: null });
    return { id, url: `${input.origin}/#${localSignInFragment}=${ticket}`, expiresAtMs, handoffFile };
  });
}
export function revokeLocalSignInTicket(deps: LocalTicketDeps, id: string): void {
  const row = deps.store.get<LocalTicketRow>('signInTickets', id);
  if (row) { unlinkHandoff(deps, row.handoffFile); deps.store.remove('signInTickets', id); }
}
export function localSignInTicketState(deps: LocalTicketDeps, id: string): 'pending' | 'redeemed' | 'expired' | 'missing' {
  const row = deps.store.get<LocalTicketRow>('signInTickets', id);
  return !row ? 'missing' : row.redeemedAtMs !== null ? 'redeemed' : row.expiresAtMs <= deps.now() ? 'expired' : 'pending';
}
export async function sweepLocalSignIn(deps: LocalTicketDeps): Promise<void> { sweep(deps); }

export function ensureLocalOwner(services: BackendServices, displayName?: string | null): string {
  const { store } = services;
  return store.transaction(() => {
    const workspaceId = store.metadata<string>('workspaceId');
    if (workspaceId !== null) return store.require<P.Workspace>('workspaces', workspaceId).ownerUserId;
    const account = userInfo().username;
    const user = services.resource('user', { email: `${account.toLowerCase().replace(/[^a-z0-9_+-]/g, '') || 'owner'}@lemon.local`, displayName: displayName ?? account, avatarAttachmentId: null,
      preferences: { appearance: 'system' as const, language: null, timezone: 'UTC', botColors: true, threadsBesideChat: false, voice: { voiceId: 'default', speed: 1, language: null }, celebrationsEnabled: false },
      notifications: { enabled: true, sound: true, previews: true, completed: true, needsInput: true } });
    const member = services.resource('member', { userId: user.id, email: user.email, displayName: user.displayName, role: 'owner' as const, enabled: true });
    const created = services.resource('workspace', { name: hostname().replace(/\.local$/, '').slice(0, 120) || 'Lemon Bot', ownerUserId: user.id, enabled: true, timezone: 'UTC' });
    store.put('users', user); store.put('members', member); store.put('workspaces', created);
    store.setMetadata('workspaceId', created.id);
    for (const key of ['setupCode', 'setupCodeDigest', 'setupCodeState']) store.setMetadata(key, null);
    return user.id;
  });
}

const proxyHeaders = ['Forwarded', 'X-Forwarded-For', 'X-Forwarded-Host', 'X-Forwarded-Proto', 'X-Real-IP', 'Tailscale-User-Login'];
export function createLocalSignInRoutes(services: BackendServices): Route[] {
  const { store } = services;
  const deps: LocalTicketDeps = { store, now: services.now, digest: services.mutations.digest, dataDir: services.config.dataDir };
  function failure(error: unknown): never {
    const limited = store.transaction(() => {
      const now = services.now();
      const previous = store.metadata<{ startedAtMs: number; count: number }>('localTicketFail');
      const value = previous && now - previous.startedAtMs < 60_000 ? previous : { startedAtMs: now, count: 0 };
      store.setMetadata('localTicketFail', { startedAtMs: value.startedAtMs, count: value.count + 1 });
      return value.count >= 10;
    });
    if (limited) fail('rate_limited', 'Too many failed sign-in links. Wait a minute, then try again.');
    throw error;
  }
  return [
    { method: 'POST', path: '/v1/auth/local', auth: 'public', mutation: false, status: 200, handler: context => {
      if (context.query.size) fail('invalid_request', 'This endpoint does not accept query parameters.');
      requireLocalAccess(services.config.dataDir, context.request);
      const body = parse(z.object({ displayName: z.string().trim().min(1).max(120).optional() }).strict(), context.body);
      return services.auth.session(ensureLocalOwner(services, body.displayName), null, { localConfirmed: true });
    } },
    { method: 'POST', path: '/v1/auth/local/redeem', auth: 'public', mutation: false, status: 200, handler: async context => {
      let redeemed: { row: LocalTicketRow; result: Promise<P.AuthResult> };
      try {
        if (context.query.size) fail('invalid_request', 'This endpoint does not accept query parameters.');
        const origin = services.config.loopbackOrigin;
        if (!origin) fail('capability_unavailable', 'Sign-in links work only when Lemon Bot listens on 127.0.0.1.');
        const headers = context.request.headers;
        if (proxyHeaders.some(name => headers.has(name)) || headers.get('Host') !== new URL(origin).host || (headers.has('Origin') ? headers.get('Origin') !== origin : headers.get('Sec-Fetch-Site') !== 'same-origin')) fail('forbidden', 'Open the sign-in link on the computer running Lemon Bot, or through its SSH tunnel.');
        const body = parse(z.object({ ticket: z.string().regex(/^[A-Za-z0-9_-]{43}$/) }).strict(), context.body);
        redeemed = store.transaction(() => {
          const digest = services.mutations.digest(body.ticket);
          const row = store.list<LocalTicketRow>('signInTickets', row => row.digest === digest)[0];
          if (!row || row.redeemedAtMs !== null) fail('unauthenticated', "This sign-in link was already used or isn't valid.");
          if (row.expiresAtMs <= services.now()) fail('expired', 'This sign-in link expired. Run lemon-bot open for a new one.');
          if (row.origin !== origin) fail('forbidden', 'Open the sign-in link on the computer running Lemon Bot, or through its SSH tunnel.');
          store.put('signInTickets', { ...row, redeemedAtMs: services.now() });
          const result = services.auth.session(ensureLocalOwner(services, row.displayName), null, { localConfirmed: true });
          services.audit(null, 'auth.local_ticket.redeem', row.id, 'succeeded');
          return { row, result };
        });
      } catch (error) { return failure(error); }
      unlinkHandoff(deps, redeemed.row.handoffFile);
      return await redeemed.result;
    } },
  ];
}
