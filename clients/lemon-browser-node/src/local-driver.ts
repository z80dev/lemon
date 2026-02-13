#!/usr/bin/env node
import { ChromeSession } from './chrome.js';
import { handleBrowserMethod } from './browser-methods.js';
import { resolveOpenClawUserDataDir } from './openclaw-profile.js';

type RequestMsg = {
  id: string;
  method: string;
  args?: unknown;
  timeoutMs?: number;
};

function parseArgs(argv: string[]): Record<string, string | boolean> {
  const out: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i]!;
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i += 1;
    }
  }
  return out;
}

function asString(v: unknown): string | null {
  if (typeof v === 'string' && v.trim()) return v.trim();
  return null;
}

function asBool(v: unknown): boolean {
  if (v === true) return true;
  if (typeof v === 'string') return ['1', 'true', 'yes', 'on'].includes(v.toLowerCase());
  return false;
}

function asInt(v: unknown, def: number): number {
  if (typeof v === 'string') {
    const n = Number.parseInt(v, 10);
    if (Number.isFinite(n) && n > 0) return n;
  }
  return def;
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
  const args = parseArgs(process.argv.slice(2));

  const cdpPort =
    asInt(args['cdp-port'], asInt(process.env.LEMON_BROWSER_CDP_PORT, 18800));
  const headless = asBool(args['headless']) || asBool(process.env.LEMON_BROWSER_HEADLESS);
  const noSandbox = asBool(args['no-sandbox']) || asBool(process.env.LEMON_BROWSER_NO_SANDBOX);
  const attachOnly = asBool(args['attach-only']) || asBool(process.env.LEMON_BROWSER_ATTACH_ONLY);
  const executablePath =
    asString(args['executable-path']) ?? asString(process.env.LEMON_BROWSER_EXECUTABLE);

  const openclawProfile = asString(args['openclaw-profile']) ?? 'openclaw';
  const userDataDir =
    asString(args['user-data-dir']) ??
    asString(process.env.LEMON_BROWSER_USER_DATA_DIR) ??
    resolveOpenClawUserDataDir(openclawProfile);

  const chrome = new ChromeSession({
    cdpPort,
    userDataDir,
    executablePath: executablePath ?? undefined,
    headless,
    noSandbox,
    attachOnly,
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
      void handleLine(line);
    }
  });

  async function handleLine(line: string) {
    let msg: RequestMsg;
    try {
      msg = JSON.parse(line) as RequestMsg;
    } catch (err) {
      writeLine({ id: 'unknown', ok: false, error: `invalid json: ${String(err)}` });
      return;
    }

    const id = asString(msg.id) ?? 'unknown';
    const method = asString(msg.method) ?? '';
    const args = msg.args ?? {};
    const timeoutMs = typeof msg.timeoutMs === 'number' && msg.timeoutMs > 0 ? msg.timeoutMs : 30_000;

    try {
      const result = await withTimeout(() => handleBrowserMethod(page, method, args), timeoutMs);
      writeLine({ id, ok: true, result });
    } catch (err) {
      const error = err instanceof Error ? err.message : String(err);
      writeLine({ id, ok: false, error });
    }
  }

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

main().catch((err) => {
  const msg = err instanceof Error ? err.stack || err.message : String(err);
  process.stderr.write(msg + '\n');
  process.exit(1);
});

