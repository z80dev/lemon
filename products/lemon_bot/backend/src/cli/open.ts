import { timingSafeEqual } from 'node:crypto';
import { closeSync, openSync, unlinkSync, writeSync } from 'node:fs';
import { hostname, userInfo } from 'node:os';
import { opaqueToken } from '../core/auth';
import { localSettings, loopbackOrigin } from '../core/config';
import { createMutationDigest } from '../core/mutations';
import { productVersion } from '../core/version';
import { issueLocalSignInTicket, localBackendChallengeProof, localSignInTicketState, revokeLocalSignInTicket, sweepLocalSignIn, type LocalTicketDeps } from '../core/local-signin';
import { openPrivateStore, readInstanceId, type PrivateLocalStore } from './local-store';
import { browserOpener, detectHeadless, headlessInstructions, openPath, writeHandoffFile } from './handoff';

export interface SignInTerminal { write(value: string): void; close(): void }
export interface SignInDeliveryDependencies {
  openTerminal(): SignInTerminal;
  openPath(path: string): Promise<boolean>;
  stdout(value: string): void;
  stderr(value: string): void;
  env: Record<string, string | undefined>;
  platform: string;
  openerAvailable: boolean;
  now(): number;
  sleep(ms: number): Promise<void>;
  onSignal(callback: (signal: 'SIGINT' | 'SIGTERM' | 'exit') => void): () => void;
}
export const signInDeliveryDefaults: SignInDeliveryDependencies = {
  openTerminal() { const fd = openSync('/dev/tty', 'w'); return { write(value) { writeSync(fd, value); }, close() { closeSync(fd); } }; },
  openPath,
  stdout: value => { process.stdout.write(value); }, stderr: value => { process.stderr.write(value); },
  env: process.env, platform: process.platform,
  openerAvailable: !!(browserOpener(process.platform) && Bun.which(browserOpener(process.platform)!)),
  now: Date.now, sleep: ms => Bun.sleep(ms),
  onSignal(callback) {
    const interrupt = () => callback('SIGINT'); const terminate = () => callback('SIGTERM'); const exit = () => callback('exit');
    process.once('SIGINT', interrupt); process.once('SIGTERM', terminate); process.once('exit', exit);
    return () => { process.off('SIGINT', interrupt); process.off('SIGTERM', terminate); process.off('exit', exit); };
  },
};

/** Shared with first startup: private proof never enters argv, stdout or stderr. */
export async function deliverLocalSignIn(tickets: LocalTicketDeps, origin: string, options: { headless?: boolean; noWait?: boolean }, deps: SignInDeliveryDependencies = signInDeliveryDefaults): Promise<number> {
  let terminal: SignInTerminal | undefined;
  let ticket: { id: string; url: string; expiresAtMs: number; handoffFile: string | null } | undefined;
  let delivered = false;
  let interrupted = 0;
  const { promise: cancelled, resolve: wake } = Promise.withResolvers<void>();
  const removeFile = () => { if (ticket?.handoffFile) { try { unlinkSync(ticket.handoffFile); } catch { /* Already redeemed, or unavailable. */ } } };
  const off = deps.onSignal(signal => { interrupted = signal === 'SIGINT' ? 130 : 143; removeFile(); wake(); });
  let headless = options.headless || detectHeadless(deps.env, deps.platform, deps.openerAvailable);
  const acquireTerminal = () => {
    try { terminal = deps.openTerminal(); return true; }
    catch { return false; }
  };
  try {
    if (headless && !acquireTerminal()) {
      deps.stderr('lemon-bot open --headless shows a private sign-in link and needs a terminal.\n'); return 2;
    }
    await sweepLocalSignIn(tickets);
    if (interrupted) return interrupted;
    ticket = issueLocalSignInTicket(tickets, { origin, channel: headless ? 'terminal' : 'browser', withHandoffFile: !headless });
    if (!headless) {
      await writeHandoffFile(ticket.handoffFile!, ticket.url);
      const opened = await Promise.race([deps.openPath(ticket.handoffFile!), cancelled.then(() => false)]);
      if (interrupted) return interrupted;
      if (!opened) {
        revokeLocalSignInTicket(tickets, ticket.id); removeFile(); ticket = undefined;
        if (!acquireTerminal()) { deps.stderr("Couldn't open a browser. Run: lemon-bot open --headless\n"); return 1; }
        headless = true;
        ticket = issueLocalSignInTicket(tickets, { origin, channel: 'terminal', withHandoffFile: false });
      } else deps.stdout('Opening Lemon Bot in your browser…\n');
    }
    if (headless) terminal!.write(headlessInstructions({ origin, url: ticket.url, env: deps.env, user: userInfo().username, host: hostname() }));
    delivered = true;
    if (options.noWait) return 0;
    const started = deps.now(); let hinted = false;
    while (!interrupted) {
      const state = localSignInTicketState(tickets, ticket.id);
      if (state === 'redeemed') { if (headless) terminal!.write('Signed in.\n'); else deps.stdout('Signed in.\n'); return 0; }
      if (state === 'expired' || state === 'missing') {
        deps.stderr('The sign-in link expired before a browser used it. Run lemon-bot open again (or lemon-bot open --headless).\n'); return 1;
      }
      if (!headless && !hinted && deps.now() - started >= 15_000) { deps.stdout("Browser didn't open Lemon Bot? Run: lemon-bot open --headless\n"); hinted = true; }
      await Promise.race([deps.sleep(250), cancelled]);
    }
    return interrupted;
  } catch {
    deps.stderr('Could not deliver a private sign-in link. Run lemon-bot open again.\n'); return 1;
  } finally {
    off();
    // --no-wait must leave the file readable until the browser opens it. The
    // backend removes it on redemption or expiry; its sweep also handles crashes.
    if (!(delivered && options.noWait && !interrupted)) removeFile();
    if (ticket && (!delivered || interrupted)) { try { revokeLocalSignInTicket(tickets, ticket.id); } catch { /* Keep private storage errors out of logs. */ } }
    try { terminal?.close(); } catch { /* No private terminal errors in logs. */ }
  }
}

export async function probeLocalBackend(origin: string, nonce: string): Promise<unknown> {
  const response = await fetch(`${origin}/v1/auth/local/challenge`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ nonce }),
    redirect: 'manual',
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok || !response.body) throw new Error('Unavailable');
  const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
  try {
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      size += value.byteLength; if (size > 16 * 1024) throw new Error('Oversized challenge'); chunks.push(value);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally { await reader.cancel(); }
}
export interface OpenCliDependencies extends SignInDeliveryDependencies {
  readLocal(dataDir: string): Promise<{ instanceId: string }>;
  probe(origin: string, nonce: string): Promise<unknown>;
  openPrivateStore: typeof openPrivateStore;
}
const defaults: OpenCliDependencies = { ...signInDeliveryDefaults, async readLocal(dataDir) { return readInstanceId(dataDir); }, probe: probeLocalBackend, openPrivateStore };
function proofMatches(actual: unknown, expected: string): boolean {
  if (typeof actual !== 'string' || !/^[0-9a-f]{64}$/.test(actual)) return false;
  return timingSafeEqual(Buffer.from(actual, 'hex'), Buffer.from(expected, 'hex'));
}
export async function runOpenCli(args: string[], deps: OpenCliDependencies = defaults): Promise<number> {
  if (args.some(arg => arg !== '--headless' && arg !== '--no-wait') || new Set(args).size !== args.length) { deps.stderr('Unsupported open argument. Use lemon-bot --help.\n'); return 2; }
  let privateStore: PrivateLocalStore | undefined;
  try {
    const settings = localSettings(deps.env);
    const origin = loopbackOrigin(settings.host, settings.port);
    if (!origin) { deps.stderr(`lemon-bot open needs Lemon Bot listening on 127.0.0.1 (LEMON_BOT_HOST=${settings.host}). Sign in with your email and password at ${settings.publicUrl.origin}.\n`); return 1; }
    let local: { instanceId: string };
    try { local = await deps.readLocal(settings.dataDir); }
    catch { deps.stderr("Lemon Bot hasn't started on this computer yet. Start it with: lemon-bot\n"); return 1; }
    privateStore = await deps.openPrivateStore(settings.dataDir, local.instanceId, deps.env);
    const digest = createMutationDigest(privateStore.key);
    const nonce = opaqueToken();
    let challenge: unknown;
    try { challenge = await deps.probe(origin, nonce); }
    catch { deps.stderr(`Lemon Bot isn't running at ${origin}.\n`); return 1; }
    const answer = challenge as { product?: unknown; instanceId?: unknown; version?: unknown; proof?: unknown } | null;
    const identity = answer && answer.product === 'lemon_bot' && typeof answer.instanceId === 'string' && typeof answer.version === 'string'
      ? { product: 'lemon_bot' as const, instanceId: answer.instanceId, version: answer.version }
      : null;
    if (!identity || identity.instanceId !== local.instanceId || !proofMatches(answer?.proof, localBackendChallengeProof(digest, nonce, identity))) {
      deps.stderr(`A different Lemon Bot is answering at ${origin}.\n`); return 1;
    }
    if (identity.version !== productVersion) {
      const version = /^[0-9A-Za-z.+_-]{1,64}$/.test(identity.version) ? identity.version : 'unknown';
      deps.stderr(`Lemon Bot ${version} is running; restart it to use lemon-bot open (this is ${productVersion}).\n`); return 1;
    }
    return await deliverLocalSignIn({ store: privateStore.store, digest, now: deps.now, dataDir: settings.dataDir, instanceId: local.instanceId }, origin, { headless: args.includes('--headless'), noWait: args.includes('--no-wait') }, deps);
  } catch { deps.stderr('Local sign-in unavailable. Check the local instance configuration and private storage.\n'); return 1; }
  finally { try { privateStore?.store.close(); } catch { /* No private storage errors in logs. */ } }
}
