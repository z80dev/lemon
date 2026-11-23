#!/usr/bin/env node
import { pathToFileURL } from 'node:url';

import { asBool, asInt, asString, parseCliArgs, type CliArgs } from './cli-args.js';
import { ChromeSession, OutcomeUnknownError, redactUrlCredentials } from './chrome.js';
import { dispatchBrowserRequest, isReadOnlyBrowserMethod } from './driver-dispatch.js';
import { resolveOpenClawUserDataDir } from './openclaw-profile.js';

export type RequestMsg = {
  id: string;
  method: string;
  args?: unknown;
  timeoutMs?: number;
  /** Absolute caller deadline (Unix epoch milliseconds, same host clock). */
  deadlineAtMs?: number;
};

export type LocalDriverConfig = {
  cdpPort: number;
  cdpEndpoint: string | null;
  headless: boolean;
  noSandbox: boolean;
  attachOnly: boolean;
  allowUnenforcedEgress: boolean;
  executablePath: string | null;
  openclawProfile: string;
  userDataDir: string;
  profileDirectory?: string;
  userProvidedProfile: boolean;
};

/**
 * `not_started`: the request was never run and may be retried.
 * `timeout`: a read-only request ran out of time.
 * `outcome_unknown`: a side-effecting request may have taken effect; never retry it.
 */
export type LocalDriverErrorCode = 'not_started' | 'timeout' | 'outcome_unknown';

export type LocalDriverResponse = {
  id: string;
  ok: boolean;
  result?: unknown;
  error?: string;
  code?: LocalDriverErrorCode;
};

/**
 * Runs one request. `begin` must be called immediately before the first
 * browser side effect: it throws once the request was answered as timed out,
 * so work that was still preparing (starting Chrome, say) never acts late.
 */
export type DriverInvoke = (method: string, args: unknown, begin: () => void) => Promise<unknown>;

export type DriverRequestQueue = {
  /** Accepts one stdin line; its deadline is stamped now. */
  submit(line: string): void;
  /** Resolves once every submitted request has settled. */
  drained(): Promise<void>;
};

export function resolveLocalDriverConfig(params: {
  args: CliArgs;
  env?: NodeJS.ProcessEnv;
}): LocalDriverConfig {
  const env = params.env ?? process.env;

  const cdpPort =
    asInt(params.args['cdp-port'], asInt(env.LEMON_BROWSER_CDP_PORT, 18800));
  const cdpEndpoint =
    asString(params.args['cdp-endpoint']) ?? asString(env.LEMON_BROWSER_CDP_ENDPOINT);
  const headless = asBool(params.args['headless']) || asBool(env.LEMON_BROWSER_HEADLESS);
  const noSandbox = asBool(params.args['no-sandbox']) || asBool(env.LEMON_BROWSER_NO_SANDBOX);
  const attachOnly =
    asBool(params.args['attach-only']) || asBool(env.LEMON_BROWSER_ATTACH_ONLY) || !!cdpEndpoint;
  const allowUnenforcedEgress =
    asBool(params.args['allow-unenforced-egress']) || asBool(env.LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS);
  const executablePath =
    asString(params.args['executable-path']) ?? asString(env.LEMON_BROWSER_EXECUTABLE);

  const openclawProfile = asString(params.args['openclaw-profile']) ?? 'openclaw';
  const userDataDir =
    asString(params.args['user-data-dir']) ??
    asString(env.LEMON_BROWSER_USER_DATA_DIR) ??
    resolveOpenClawUserDataDir(openclawProfile);

  return {
    cdpPort,
    cdpEndpoint,
    headless,
    noSandbox,
    attachOnly,
    allowUnenforcedEgress,
    executablePath,
    openclawProfile,
    userDataDir,
    profileDirectory: asString(params.args['profile-directory']) ?? asString(env.LEMON_BROWSER_PROFILE_DIRECTORY) ?? undefined,
    userProvidedProfile: !!(asString(params.args['user-data-dir']) ?? asString(env.LEMON_BROWSER_USER_DATA_DIR)),
  };
}

class NotStartedError extends Error {}

/**
 * Serializes requests: one runs at a time, and the next starts only after the
 * previous invocation has actually settled, never merely timed out. Each
 * request's deadline is the earlier of `timeoutMs` after the line was read
 * and the caller's absolute `deadlineAtMs`. A request still queued at its
 * deadline is answered `not_started` and never invoked. A side-effecting
 * request still running at its deadline is answered `outcome_unknown`; a
 * read-only one `timeout`. An invocation that has not settled `settleGraceMs`
 * after its deadline is wedged: `onWedged` runs and later requests stay queued.
 */
export function createDriverRequestQueue(params: {
  invoke: DriverInvoke;
  reply: (response: LocalDriverResponse) => void;
  isReadOnly: (method: string, args: unknown) => boolean;
  onWedged: () => void;
  defaultTimeoutMs?: number;
  settleGraceMs?: number;
  now?: () => number;
}): DriverRequestQueue {
  const now = params.now ?? Date.now;
  const defaultTimeoutMs = params.defaultTimeoutMs ?? 30_000;
  const settleGraceMs = params.settleGraceMs ?? 10_000;
  let tail: Promise<void> = Promise.resolve();

  const submit = (line: string) => {
    const receivedAt = now();
    let msg: RequestMsg;
    try {
      msg = JSON.parse(line) as RequestMsg;
    } catch (err) {
      params.reply({ id: 'unknown', ok: false, error: `invalid json: ${String(err)}` });
      return;
    }

    const id = asString(msg.id) ?? 'unknown';
    const method = asString(msg.method) ?? '';
    const args = msg.args ?? {};
    const timeoutMs =
      typeof msg.timeoutMs === 'number' && msg.timeoutMs > 0 ? msg.timeoutMs : defaultTimeoutMs;
    const deadline =
      typeof msg.deadlineAtMs === 'number' && Number.isFinite(msg.deadlineAtMs)
        ? Math.min(receivedAt + timeoutMs, msg.deadlineAtMs)
        : receivedAt + timeoutMs;

    let answered = false;
    const answer = (response: LocalDriverResponse) => {
      if (answered) return;
      answered = true;
      params.reply(response);
    };
    const notStarted = () =>
      answer({
        id,
        ok: false,
        code: 'not_started',
        error: 'request deadline passed before it started; it was not run',
      });

    // A queued request is answered at its deadline, not when the queue reaches it.
    let running = false;
    const queuedTimer = setTimeout(() => {
      if (!running) notStarted();
    }, Math.max(0, deadline - now()));

    const run = async () => {
      clearTimeout(queuedTimer);
      if (answered || now() >= deadline) {
        notStarted();
        return;
      }
      running = true;

      let begun = false;
      const begin = () => {
        if (answered) throw new NotStartedError('request deadline passed before it started');
        begun = true;
      };
      const execution = Promise.resolve()
        .then(() => params.invoke(method, args, begin))
        .then(
          (result) => ({ ok: true as const, result }),
          (err: unknown) => ({ ok: false as const, err }),
        );

      const expiry = timer(Math.max(0, deadline - now()));
      const outcome = await Promise.race([execution, expiry.promise.then(() => 'expired' as const)]);
      expiry.cancel();

      if (outcome !== 'expired') {
        answer(outcome.ok ? { id, ok: true, result: outcome.result } : errorResponse(id, outcome.err));
        return;
      }

      if (!begun) {
        notStarted();
      } else if (params.isReadOnly(method, args)) {
        answer({ id, ok: false, code: 'timeout', error: `timeout after ${timeoutMs}ms` });
      } else {
        answer({
          id,
          ok: false,
          code: 'outcome_unknown',
          error: `${method} did not finish before its deadline; it may have taken effect`,
        });
      }

      // The abandoned invocation holds the queue until it settles, so it never
      // overlaps the next request.
      const grace = timer(settleGraceMs);
      const wedged = await Promise.race([execution.then(() => false), grace.promise.then(() => true)]);
      grace.cancel();
      if (wedged) {
        params.onWedged();
        await execution;
      }
    };

    tail = tail.then(run, run);
  };

  return { submit, drained: () => tail };
}

function timer(ms: number): { promise: Promise<void>; cancel: () => void } {
  let handle: NodeJS.Timeout | undefined;
  // lib is ES2022, which has no Promise.withResolvers.
  const promise = new Promise<void>((resolve) => {
    handle = setTimeout(resolve, ms);
  });
  return { promise, cancel: () => clearTimeout(handle) };
}

function errorResponse(id: string, err: unknown): LocalDriverResponse {
  // Errors can echo a CDP or page URL; never serialize its credentials.
  const error = redactUrlCredentials(err instanceof Error ? err.message : String(err));
  if (err instanceof NotStartedError) return { id, ok: false, code: 'not_started', error };
  if (err instanceof OutcomeUnknownError) return { id, ok: false, code: 'outcome_unknown', error };
  return { id, ok: false, error };
}

function writeLine(obj: unknown) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

async function main() {
  const args = parseCliArgs(process.argv.slice(2));
  const config = resolveLocalDriverConfig({ args });

  const chrome = new ChromeSession({
    cdpPort: config.cdpPort,
    cdpEndpoint: config.cdpEndpoint ?? undefined,
    userDataDir: config.userDataDir,
    profileDirectory: config.profileDirectory,
    userProvidedProfile: config.userProvidedProfile,
    executablePath: config.executablePath ?? undefined,
    headless: config.headless,
    noSandbox: config.noSandbox,
    attachOnly: config.attachOnly,
    allowUnenforcedEgress: config.allowUnenforcedEgress,
  });
  let started: Promise<void> | undefined;

  const queue = createDriverRequestQueue({
    invoke: async (method, methodArgs, begin) => {
      started ??= chrome.start();
      await started;
      begin();
      return dispatchBrowserRequest(chrome, method, methodArgs);
    },
    reply: writeLine,
    isReadOnly: isReadOnlyBrowserMethod,
    onWedged: () => {
      process.stderr.write('browser request did not settle after its deadline; stopping the driver\n');
      void shutdown(1);
    },
  });

  process.stdin.setEncoding('utf8');
  let buf = '';

  process.stdin.on('data', (chunk) => {
    buf += chunk;
    while (true) {
      const idx = buf.indexOf('\n');
      if (idx < 0) break;
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line) continue;
      queue.submit(line);
    }
  });

  async function shutdown(code: number): Promise<void> {
    try {
      await chrome.stop();
    } finally {
      process.exit(code);
    }
  }
  process.on('SIGINT', () => void shutdown(0));
  process.on('SIGTERM', () => void shutdown(0));
}

function isMainModule(): boolean {
  const entry = process.argv[1];
  if (!entry) {
    return false;
  }
  return import.meta.url === pathToFileURL(entry).href;
}

if (isMainModule()) {
  main().catch((err) => {
    const msg = err instanceof Error ? err.stack || err.message : String(err);
    process.stderr.write(msg + '\n');
    process.exit(1);
  });
}
