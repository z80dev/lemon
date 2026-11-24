import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { EventEmitter } from 'node:events';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

import { ChromeSession } from './chrome.js';
import { bindDriverLifecycle, createDriverRequestQueue, startOnceRetryingFailures, type LocalDriverResponse } from './local-driver.js';

// Stands in for Chrome: serves /json/version on a free port, publishes it
// through DevToolsActivePort and records how it was launched. It does not
// speak the CDP WebSocket protocol, so Playwright's attach fails afterwards.
const FAKE_CHROME = `#!/usr/bin/env node
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
const dir = process.argv.find((a) => a.startsWith('--user-data-dir=')).slice('--user-data-dir='.length);
fs.writeFileSync(path.join(dir, 'launch.json'), JSON.stringify({ pid: process.pid, args: process.argv.slice(2) }));
const server = http.createServer((_req, res) => {
  res.setHeader('content-type', 'application/json');
  res.end(JSON.stringify({ Browser: 'Fake/1', webSocketDebuggerUrl: 'ws://127.0.0.1:' + server.address().port + '/devtools/browser/fake' }));
});
server.listen(0, '127.0.0.1', () => {
  fs.writeFileSync(path.join(dir, 'DevToolsActivePort'), server.address().port + '\\n/devtools/browser/fake');
});
`;

let tmp: string;
let fakeChrome: string;
let userDataDir: string;

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-managed-chrome-'));
  fakeChrome = path.join(tmp, 'fake-chrome.mjs');
  fs.writeFileSync(fakeChrome, FAKE_CHROME);
  fs.chmodSync(fakeChrome, 0o755);
  userDataDir = path.join(tmp, 'user-data');
});

afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

function managed(cdpPort = 18800, executablePath = fakeChrome) {
  return new ChromeSession({ cdpPort, userDataDir, executablePath, headless: true, noSandbox: false, attachOnly: false });
}

function launch(): { pid: number; args: string[] } {
  return JSON.parse(fs.readFileSync(path.join(userDataDir, 'launch.json'), 'utf8'));
}

function alive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

type ManagedSeam = { launchManaged(): Promise<string>; proc: unknown };

// Test seam: launches without the CDP attach the fake cannot complete.
function seam(session: ChromeSession): ManagedSeam {
  return session as unknown as ManagedSeam;
}

// Real Chrome stand-ins are separate OS processes, so their exit is observed
// by polling; fake timers cannot drive another process.
async function until(check: () => boolean, timeoutMs = 5_000): Promise<void> {
  const started = Date.now();
  while (!check()) {
    if (Date.now() - started > timeoutMs) throw new Error('condition not reached');
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

describe('managed Chrome lifetime', () => {
  it('launches its own Chrome on a free port and never attaches to a foreign listener on the CDP port', async () => {
    let foreignHits = 0;
    const foreign = http.createServer((_req, res) => {
      foreignHits += 1;
      res.end(JSON.stringify({ Browser: 'Foreign/1', webSocketDebuggerUrl: 'ws://127.0.0.1:1/x' }));
    });
    await new Promise<void>((resolve) => foreign.listen(0, '127.0.0.1', resolve));
    const address = foreign.address();
    if (!address || typeof address === 'string') throw new Error('no listener address');
    const foreignPort = address.port;

    try {
      const session = managed(foreignPort);
      // The fake publishes a DevTools port but cannot complete the CDP attach.
      await expect(session.start()).rejects.toThrow(/CDP attach failed at http:\/\/127\.0\.0\.1:\d+/);

      const { pid, args } = launch();
      expect(args).toContain('--remote-debugging-port=0');
      expect(args).not.toContain(`--remote-debugging-port=${foreignPort}`);
      expect(foreignHits).toBe(0);
      // A failed start releases the Chrome it launched.
      await until(() => !alive(pid));
    } finally {
      foreign.close();
    }
  });

  it('an invalid executable is an error reply, not a driver exit', async () => {
    const session = managed(18800, path.join(tmp, 'no-such-chrome'));
    const ensureStarted = startOnceRetryingFailures(() => session.start());
    const replies: LocalDriverResponse[] = [];
    const queue = createDriverRequestQueue({
      invoke: async (_method, _args, begin) => {
        await ensureStarted();
        begin();
        return {};
      },
      reply: (reply) => replies.push(reply),
      isReadOnly: () => true,
      onWedged: () => undefined,
    });

    queue.submit(JSON.stringify({ id: 'r1', method: 'browser.tabs', timeoutMs: 10_000 }));
    await queue.drained();

    expect(replies).toEqual([{ id: 'r1', ok: false, error: 'Chrome could not be started (ENOENT)' }]);
  });

  it('stdin EOF stops the launched Chrome and exits the driver once', async () => {
    const session = managed();
    await seam(session).launchManaged();
    const { pid } = launch();
    expect(alive(pid)).toBe(true);

    const stdin = new EventEmitter();
    const stdout = new EventEmitter();
    const proc = new EventEmitter();
    const exit = vi.fn();
    bindDriverLifecycle({ stdin, stdout, process: proc, chrome: session, exit });

    stdin.emit('end');
    stdout.emit('error', Object.assign(new Error('write EPIPE'), { code: 'EPIPE' }));
    await until(() => exit.mock.calls.length > 0);

    expect(exit).toHaveBeenCalledExactlyOnceWith(0);
    await until(() => !alive(pid));
  });

  it('an EPIPE on stdout and process exit both stop the launched Chrome', async () => {
    const session = managed();
    await seam(session).launchManaged();
    const { pid } = launch();
    const proc = new EventEmitter();
    const exit = vi.fn();
    const stdout = new EventEmitter();
    bindDriverLifecycle({ stdin: new EventEmitter(), stdout, process: proc, chrome: session, exit });

    stdout.emit('error', Object.assign(new Error('write EPIPE'), { code: 'EPIPE' }));
    await until(() => exit.mock.calls.length > 0);
    await until(() => !alive(pid));

    const second = managed();
    await seam(second).launchManaged();
    const secondPid = launch().pid;
    bindDriverLifecycle({ stdin: new EventEmitter(), stdout: new EventEmitter(), process: proc, chrome: second, exit: vi.fn() });
    proc.emit('exit', 0);
    await until(() => !alive(secondPid));
  });

  it('forgets a launched Chrome that exited, so the next start launches a new one', async () => {
    const session = managed();
    await seam(session).launchManaged();
    const { pid } = launch();

    process.kill(pid, 'SIGKILL');
    await until(() => seam(session).proc === null);

    await session.stop();
  });
});
