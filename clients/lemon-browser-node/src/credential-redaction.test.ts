import { afterEach, describe, expect, it, vi } from 'vitest';
import { once } from 'node:events';
import fs from 'node:fs';
import { createServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { chromium } from 'playwright-core';

import {
  ChromeSession,
  browserChildEnv,
  cdpAttachError,
  describeEndpoint,
  redactUrlCredentials,
} from './chrome.js';
import { executeLocalDriverRequest } from './local-driver.js';

const ENDPOINT =
  'wss://alice:userinfo-secret@cdp.test:9222/session/path-secret?apiKey=query-secret&other=second-secret#frag-secret';
const SECRETS = ['alice', 'userinfo-secret', 'path-secret', 'query-secret', 'second-secret', 'frag-secret'];

function expectNoSecrets(text: string) {
  for (const secret of SECRETS) expect(text).not.toContain(secret);
}

afterEach(() => vi.restoreAllMocks());

describe('CDP credential redaction', () => {
  it('describes an endpoint by scheme and host only', () => {
    expect(describeEndpoint(ENDPOINT)).toBe('wss://cdp.test:9222');
    expect(describeEndpoint('not a url ?token=x')).toBe('[unparseable CDP endpoint]');
  });

  it('strips userinfo, fragments and arbitrary query values from URLs in text', () => {
    const text = redactUrlCredentials(`failed at ${ENDPOINT} and http://h.test/x?sessionToken=log-secret`);
    // Generic redaction keeps paths (page URLs need them); endpoint-specific
    // errors use describeEndpoint/cdpAttachError, which drop paths too.
    for (const secret of SECRETS.filter((s) => s !== 'path-secret')) expect(text).not.toContain(secret);
    expect(text).not.toContain('log-secret');
    expect(text).toContain('apiKey=redacted');
  });

  it('wraps connection-library failures without any endpoint part', () => {
    const err = cdpAttachError(
      ENDPOINT,
      new Error(
        `browserType.connectOverCDP: WebSocket error: ${ENDPOINT} 401\nCall log:\n  - <ws connecting> ${ENDPOINT}\n  - token query-secret rejected for /session/path-secret`,
      ),
    );
    expectNoSecrets(err.message);
    expect(err.message).toContain('CDP attach failed at wss://cdp.test:9222');
    expect(err.message).toContain('401');
  });

  it('never reports an unreachable attach endpoint with its credentials', async () => {
    const session = new ChromeSession({
      cdpPort: 1,
      cdpEndpoint: 'http://alice:userinfo-secret@127.0.0.1:1/session/path-secret?apiKey=query-secret',
      userDataDir: path.join(os.tmpdir(), 'lemon-redaction-unused'),
      headless: true,
      noSandbox: false,
      attachOnly: true,
    });
    const error = await session.start().then(
      () => null,
      (err: Error) => err,
    );
    expect(error?.message).toContain('CDP not reachable at http://127.0.0.1:1');
    expectNoSecrets(error?.message ?? '');
  });

  it('sanitizes connectOverCDP exceptions raised during start', async () => {
    const server = createServer((_req, res) => {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ webSocketDebuggerUrl: 'ws://127.0.0.1:1/devtools/browser/x' }));
    });
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('no TCP address');
    const port = address.port;
    // No userinfo: the discovery probe must succeed so connectOverCDP runs.
    const endpoint = `http://127.0.0.1:${port}/session/path-secret?apiKey=query-secret`;
    vi.spyOn(chromium, 'connectOverCDP').mockRejectedValue(
      new Error(`connect ECONNREFUSED ${endpoint} (apiKey=query-secret)`),
    );

    try {
      const session = new ChromeSession({
        cdpPort: port,
        cdpEndpoint: endpoint,
        userDataDir: path.join(os.tmpdir(), 'lemon-redaction-unused'),
        headless: true,
        noSandbox: false,
        attachOnly: true,
        allowUnenforcedEgress: true,
      });
      const error = await session.start().then(
        () => null,
        (err: Error) => err,
      );
      expect(error?.message).toContain('ECONNREFUSED');
      expectNoSecrets(error?.message ?? '');
    } finally {
      server.close();
    }
  });

  it('serializes driver errors without URL credentials', async () => {
    const response = await executeLocalDriverRequest({
      line: JSON.stringify({ id: 'r1', method: 'browser.tabs' }),
      invoke: async () => {
        throw new Error(`navigation failed at ${ENDPOINT}`);
      },
    });
    expect(response.ok).toBe(false);
    expect(response.error).toContain('wss://cdp.test:9222/session/path-secret?apiKey=redacted');
    for (const secret of ['alice', 'userinfo-secret', 'query-secret', 'second-secret', 'frag-secret']) {
      expect(response.error).not.toContain(secret);
    }
  });
});

describe('locally launched Chrome environment', () => {
  const inherited = {
    PATH: '/usr/bin:/bin',
    DISPLAY: ':0',
    XAUTHORITY: '/home/u/.Xauthority',
    LEMON_BROWSER_RELAY_TOKEN: 'relay-env-secret',
    LEMON_OPERATOR_TOKEN: 'operator-env-secret',
    LEMON_BROWSER_CDP_ENDPOINT: 'ws://127.0.0.1:9224/cdp?token=endpoint-env-secret',
    BROWSERBASE_API_KEY: 'browserbase-env-secret',
    BROWSER_USE_API_KEY: 'browser-use-env-secret',
    FIRECRAWL_API_KEY: 'firecrawl-env-secret',
    CAMOFOX_URL: 'http://camofox.test',
    OPENAI_API_KEY: 'openai-env-secret',
    GITHUB_TOKEN: 'github-env-secret',
  };

  it('keeps display/session variables and drops Lemon, relay and provider credentials', () => {
    const env = browserChildEnv(inherited);
    expect(env).toEqual({ PATH: '/usr/bin:/bin', DISPLAY: ':0', XAUTHORITY: '/home/u/.Xauthority' });
  });

  it('spawns a managed Chrome without inherited credentials', async () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-chrome-env-'));
    const out = path.join(tmp, 'env.txt');
    const exe = path.join(tmp, 'fake-chrome.sh');
    fs.writeFileSync(exe, `#!/bin/sh\nenv > '${out}'\n`);
    fs.chmodSync(exe, 0o755);

    const original = { ...process.env };
    Object.assign(process.env, inherited, { PATH: original.PATH });
    try {
      const session = new ChromeSession({
        cdpPort: 1,
        userDataDir: path.join(tmp, 'profile'),
        executablePath: exe,
        headless: true,
        noSandbox: false,
        attachOnly: false,
      });
      // launchChrome is private; bracket access keeps the call type-checked.
      await session['launchChrome']();
      const proc = session['proc'];
      if (!proc) throw new Error('Chrome was not spawned');
      if (proc.exitCode === null) await once(proc, 'exit');
      const env = fs.readFileSync(out, 'utf8');
      for (const [name, value] of Object.entries(inherited)) {
        if (['PATH', 'DISPLAY', 'XAUTHORITY', 'CAMOFOX_URL'].includes(name)) continue;
        expect(env).not.toContain(`${name}=`);
        expect(env).not.toContain(value);
      }
      expect(env).not.toContain('CAMOFOX_URL=');
      expect(env).toContain('DISPLAY=:0');
    } finally {
      for (const name of Object.keys(inherited)) {
        if (original[name] === undefined) delete process.env[name];
        else process.env[name] = original[name];
      }
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  });
});
