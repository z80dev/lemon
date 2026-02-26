import { describe, expect, it } from 'vitest';

import { parseCliArgs } from './cli-args.js';
import { executeLocalDriverRequest, resolveLocalDriverConfig } from './local-driver.js';

describe('resolveLocalDriverConfig', () => {
  it('uses env defaults when args are absent', () => {
    const config = resolveLocalDriverConfig({
      args: parseCliArgs([]),
      env: {
        LEMON_BROWSER_CDP_PORT: '19900',
        LEMON_BROWSER_HEADLESS: 'true',
        LEMON_BROWSER_NO_SANDBOX: 'yes',
        LEMON_BROWSER_ATTACH_ONLY: 'on',
        LEMON_BROWSER_EXECUTABLE: '/env/chrome',
        LEMON_BROWSER_USER_DATA_DIR: '/env/profile',
      } as NodeJS.ProcessEnv,
    });

    expect(config.cdpPort).toBe(19900);
    expect(config.headless).toBe(true);
    expect(config.noSandbox).toBe(true);
    expect(config.attachOnly).toBe(true);
    expect(config.executablePath).toBe('/env/chrome');
    expect(config.userDataDir).toBe('/env/profile');
  });

  it('prefers args over env', () => {
    const config = resolveLocalDriverConfig({
      args: parseCliArgs([
        '--cdp-port', '20001',
        '--headless',
        '--no-sandbox',
        '--attach-only',
        '--executable-path', '/arg/chrome',
        '--user-data-dir', '/arg/profile',
      ]),
      env: {
        LEMON_BROWSER_CDP_PORT: '19900',
        LEMON_BROWSER_EXECUTABLE: '/env/chrome',
        LEMON_BROWSER_USER_DATA_DIR: '/env/profile',
      } as NodeJS.ProcessEnv,
    });

    expect(config.cdpPort).toBe(20001);
    expect(config.headless).toBe(true);
    expect(config.noSandbox).toBe(true);
    expect(config.attachOnly).toBe(true);
    expect(config.executablePath).toBe('/arg/chrome');
    expect(config.userDataDir).toBe('/arg/profile');
  });
});

describe('executeLocalDriverRequest', () => {
  it('returns invalid json error', async () => {
    const response = await executeLocalDriverRequest({
      line: '{not-json',
      invoke: async () => 'unused',
    });

    expect(response.ok).toBe(false);
    expect(response.id).toBe('unknown');
    expect(response.error).toContain('invalid json');
  });

  it('invokes method and returns result', async () => {
    const response = await executeLocalDriverRequest({
      line: JSON.stringify({
        id: 'req-1',
        method: 'browser.navigate',
        args: { url: 'https://example.com' },
        timeoutMs: 1000,
      }),
      invoke: async (method, args) => ({ method, args }),
    });

    expect(response).toEqual({
      id: 'req-1',
      ok: true,
      result: {
        method: 'browser.navigate',
        args: { url: 'https://example.com' },
      },
    });
  });

  it('returns timeout error', async () => {
    const response = await executeLocalDriverRequest({
      line: JSON.stringify({
        id: 'req-timeout',
        method: 'browser.slow',
        timeoutMs: 5,
      }),
      invoke: () => new Promise(() => {
        // Intentionally unresolved
      }),
    });

    expect(response.id).toBe('req-timeout');
    expect(response.ok).toBe(false);
    expect(response.error).toBe('timeout after 5ms');
  });
});
