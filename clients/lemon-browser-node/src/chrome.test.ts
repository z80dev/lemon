import { describe, expect, it, vi } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

import { ChromeSession, defaultChromeExecutable } from './chrome.js';

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
