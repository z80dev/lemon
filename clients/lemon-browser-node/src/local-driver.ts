#!/usr/bin/env node
import { pathToFileURL } from 'node:url';

import { handleBrowserMethod } from './browser-methods.js';
import { asBool, asInt, asString, parseCliArgs, type CliArgs } from './cli-args.js';
import { ChromeSession } from './chrome.js';
import { resolveOpenClawUserDataDir } from './openclaw-profile.js';

export type RequestMsg = {
  id: string;
  method: string;
  args?: unknown;
  timeoutMs?: number;
};

export type LocalDriverConfig = {
  cdpPort: number;
  headless: boolean;
  noSandbox: boolean;
  attachOnly: boolean;
  executablePath: string | null;
  openclawProfile: string;
  userDataDir: string;
};

export type LocalDriverResponse = {
  id: string;
  ok: boolean;
  result?: unknown;
  error?: string;
};

export function resolveLocalDriverConfig(params: {
  args: CliArgs;
  env?: NodeJS.ProcessEnv;
}): LocalDriverConfig {
  const env = params.env ?? process.env;

  const cdpPort =
    asInt(params.args['cdp-port'], asInt(env.LEMON_BROWSER_CDP_PORT, 18800));
  const headless = asBool(params.args['headless']) || asBool(env.LEMON_BROWSER_HEADLESS);
  const noSandbox = asBool(params.args['no-sandbox']) || asBool(env.LEMON_BROWSER_NO_SANDBOX);
  const attachOnly = asBool(params.args['attach-only']) || asBool(env.LEMON_BROWSER_ATTACH_ONLY);
  const executablePath =
    asString(params.args['executable-path']) ?? asString(env.LEMON_BROWSER_EXECUTABLE);

  const openclawProfile = asString(params.args['openclaw-profile']) ?? 'openclaw';
  const userDataDir =
    asString(params.args['user-data-dir']) ??
    asString(env.LEMON_BROWSER_USER_DATA_DIR) ??
    resolveOpenClawUserDataDir(openclawProfile);

  return {
    cdpPort,
    headless,
    noSandbox,
    attachOnly,
    executablePath,
    openclawProfile,
    userDataDir,
  };
}

export async function executeLocalDriverRequest(params: {
  line: string;
  invoke: (method: string, args: unknown) => Promise<unknown>;
  defaultTimeoutMs?: number;
}): Promise<LocalDriverResponse> {
  const defaultTimeoutMs = params.defaultTimeoutMs ?? 30_000;

  let msg: RequestMsg;
  try {
    msg = JSON.parse(params.line) as RequestMsg;
  } catch (err) {
    return {
      id: 'unknown',
      ok: false,
      error: `invalid json: ${String(err)}`,
    };
  }

  const id = asString(msg.id) ?? 'unknown';
  const method = asString(msg.method) ?? '';
  const args = msg.args ?? {};
  const timeoutMs =
    typeof msg.timeoutMs === 'number' && msg.timeoutMs > 0
      ? msg.timeoutMs
      : defaultTimeoutMs;

  try {
    const result = await withTimeout(() => params.invoke(method, args), timeoutMs);
    return { id, ok: true, result };
  } catch (err) {
    return {
      id,
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

async function withTimeout<T>(fn: () => Promise<T>, timeoutMs: number): Promise<T> {
  let t: NodeJS.Timeout | null = null;
  try {
    return await Promise.race([
      fn(),
      new Promise<T>((_, reject) => {
        t = setTimeout(() => reject(new Error(`timeout after ${timeoutMs}ms`)), timeoutMs);
      }),
    ]);
  } finally {
    if (t) clearTimeout(t);
  }
}

function writeLine(obj: unknown) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

async function main() {
  const args = parseCliArgs(process.argv.slice(2));
  const config = resolveLocalDriverConfig({ args });

  const chrome = new ChromeSession({
    cdpPort: config.cdpPort,
    userDataDir: config.userDataDir,
    executablePath: config.executablePath ?? undefined,
    headless: config.headless,
    noSandbox: config.noSandbox,
    attachOnly: config.attachOnly,
  });
  await chrome.start();
  const page = chrome.getPage();

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

      void executeLocalDriverRequest({
        line,
        invoke: (method, methodArgs) => handleBrowserMethod(page, method, methodArgs),
      }).then((response) => {
        writeLine(response);
      });
    }
  });

  const shutdown = async () => {
    try {
      await chrome.stop();
    } finally {
      process.exit(0);
    }
  };
  process.on('SIGINT', () => void shutdown());
  process.on('SIGTERM', () => void shutdown());
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
