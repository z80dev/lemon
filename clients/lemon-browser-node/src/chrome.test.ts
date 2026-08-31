import { describe, expect, it, vi } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import {
  ChromeSession,
  cdpDiscoveryUrl,
  defaultChromeExecutable,
  isCdpReachable,
  normalizeCdpEndpoint,
} from './chrome.js';

const TEST_CONFIG = {
  cdpPort: 18800,
  userDataDir: '/tmp/lemon-browser-test',
  headless: true,
  noSandbox: false,
  attachOnly: true,
};

describe('ChromeSession.withPage', () => {
  it('reconnects and retries once when playwright reports a closed target', async () => {
    const session = new ChromeSession(TEST_CONFIG);
    const firstPage = { id: 'first' } as any;
    const secondPage = { id: 'second' } as any;

    const getPage = vi
      .fn()
      .mockResolvedValueOnce(firstPage)
      .mockResolvedValueOnce(secondPage);
    const reconnect = vi.fn().mockResolvedValue(undefined);

    (session as any).getPage = getPage;
    (session as any).reconnect = reconnect;

    const operation = vi
      .fn()
      .mockRejectedValueOnce(new Error('Target page, context or browser has been closed'))
      .mockResolvedValueOnce({ ok: true });

    const result = await session.withPage(operation);

    expect(result).toEqual({ ok: true });
    expect(reconnect).toHaveBeenCalledTimes(1);
    expect(operation).toHaveBeenNthCalledWith(1, firstPage);
    expect(operation).toHaveBeenNthCalledWith(2, secondPage);
  });

  it('does not retry when the error is unrelated to browser lifecycle', async () => {
    const session = new ChromeSession(TEST_CONFIG);
    const page = { id: 'page' } as any;

    const getPage = vi.fn().mockResolvedValue(page);
    const reconnect = vi.fn().mockResolvedValue(undefined);

    (session as any).getPage = getPage;
    (session as any).reconnect = reconnect;

    const operation = vi.fn().mockRejectedValue(new Error('selector not found'));

    await expect(session.withPage(operation)).rejects.toThrow('selector not found');
    expect(reconnect).not.toHaveBeenCalled();
    expect(operation).toHaveBeenCalledTimes(1);
  });
});

describe('ChromeSession tab lifecycle', () => {
  it('lists tabs with stable target IDs and the active target', async () => {
    const session = new ChromeSession(TEST_CONFIG);
    const first = fakePage('target-1', 'https://one.test', 'One');
    const second = fakePage('target-2', 'https://two.test', 'Two');
    (session as any).browser = fakeBrowser([first, second]);
    (session as any).activeTargetId = 'target-2';

    await expect(session.listTabs()).resolves.toEqual({
      activeTargetId: 'target-2',
      tabs: [
        { targetId: 'target-1', active: false, url: 'https://one.test', title: 'One' },
        { targetId: 'target-2', active: true, url: 'https://two.test', title: 'Two' },
      ],
    });
  });

  it('resolves an explicit target instead of the active tab', async () => {
    const session = new ChromeSession(TEST_CONFIG);
    const first = fakePage('target-1', 'https://one.test', 'One');
    const second = fakePage('target-2', 'https://two.test', 'Two');
    (session as any).browser = fakeBrowser([first, second]);
    (session as any).activeTargetId = 'target-2';

    await expect(session.getPage('target-1')).resolves.toBe(first);
    await expect(session.getPage('missing')).rejects.toThrow('browser target not found: missing');
  });

  it('does not close a Chrome process that Lemon only attached to', async () => {
    const session = new ChromeSession(TEST_CONFIG);
    const close = vi.fn().mockResolvedValue(undefined);
    (session as any).browser = { close };
    (session as any).ownedBrowser = false;

    await session.stop();

    expect(close).not.toHaveBeenCalled();
  });

  it('closes a Chrome process that Lemon launched', async () => {
    const session = new ChromeSession(TEST_CONFIG);
    const close = vi.fn().mockResolvedValue(undefined);
    (session as any).browser = { close };
    (session as any).ownedBrowser = true;

    await session.stop();

    expect(close).toHaveBeenCalledTimes(1);
  });
});

describe('CDP endpoints', () => {
  it('accepts HTTP discovery and direct WebSocket endpoints', async () => {
    expect(normalizeCdpEndpoint('http://127.0.0.1:9222/')).toBe('http://127.0.0.1:9222');
    expect(cdpDiscoveryUrl('http://127.0.0.1:9224?token=secret')).toBe(
      'http://127.0.0.1:9224/json/version?token=secret',
    );
    expect(normalizeCdpEndpoint('ws://127.0.0.1:9222/devtools/browser/id')).toBe(
      'ws://127.0.0.1:9222/devtools/browser/id',
    );
    await expect(
      isCdpReachable('ws://127.0.0.1:9222/devtools/browser/id', 1),
    ).resolves.toBe(true);
    expect(() => normalizeCdpEndpoint('ftp://127.0.0.1/browser')).toThrow(
      'CDP endpoint must use http, https, ws, or wss',
    );
  });
});

describe('defaultChromeExecutable', () => {
  it('uses the first executable browser candidate found on PATH', () => {
    if (process.platform === 'darwin') {
      return;
    }

    const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-browser-path-'));
    const executable = path.join(tmpDir, process.platform === 'win32' ? 'msedge.exe' : 'chromium');
    const originalPath = process.env.PATH;
    const originalLemonChrome = process.env.LEMON_CHROME_EXECUTABLE;
    const originalChrome = process.env.CHROME_EXECUTABLE;

    fs.writeFileSync(executable, '#!/usr/bin/env sh\nexit 0\n');
    fs.chmodSync(executable, 0o755);

    try {
      delete process.env.LEMON_CHROME_EXECUTABLE;
      delete process.env.CHROME_EXECUTABLE;
      process.env.PATH = tmpDir;

      expect(defaultChromeExecutable()).toBe(executable);
    } finally {
      if (originalPath === undefined) {
        delete process.env.PATH;
      } else {
        process.env.PATH = originalPath;
      }

      if (originalLemonChrome === undefined) {
        delete process.env.LEMON_CHROME_EXECUTABLE;
      } else {
        process.env.LEMON_CHROME_EXECUTABLE = originalLemonChrome;
      }

      if (originalChrome === undefined) {
        delete process.env.CHROME_EXECUTABLE;
      } else {
        process.env.CHROME_EXECUTABLE = originalChrome;
      }

      fs.rmSync(tmpDir, { recursive: true, force: true });
    }
  });
});

function fakePage(targetId: string, url: string, title: string): any {
  return {
    __lemonTargetInfo: { targetId, url, title },
    isClosed: () => false,
    url: () => url,
    title: vi.fn().mockResolvedValue(title),
    bringToFront: vi.fn().mockResolvedValue(undefined),
  };
}

function fakeBrowser(pages: any[]): any {
  return {
    isConnected: () => true,
    contexts: () => [{ pages: () => pages }],
  };
}
