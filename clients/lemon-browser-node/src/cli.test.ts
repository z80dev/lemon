import { describe, expect, it } from 'vitest';

import { parseCliArgs } from './cli-args.js';
import { resolveCliConfig } from './cli.js';

describe('resolveCliConfig', () => {
  it('does not invent credentials when no credential source is configured', () => {
    const config = resolveCliConfig({
      args: parseCliArgs([]),
      hostname: 'my-host',
      storedToken: null,
      env: {},
    });

    expect(config.token).toBeNull();
    expect(config.operatorToken).toBeNull();
  });

  it('prefers explicit args over env and stored token', () => {
    const env = {
      LEMON_CHROME_EXECUTABLE: '/env/chrome',
      LEMON_OPERATOR_TOKEN: 'env-operator',
    } as NodeJS.ProcessEnv;

    const config = resolveCliConfig({
      args: parseCliArgs([
        '--ws-url', 'wss://example/ws',
        '--cdp-port', '19999',
        '--headless',
        '--no-sandbox',
        '--attach-only',
        '--node-name', 'Custom Node',
        '--operator-token', 'arg-operator',
        '--token', 'arg-token',
        '--executable-path', '/arg/chrome',
      ]),
      hostname: 'ignored-hostname',
      storedToken: 'stored-token',
      env,
    });

    expect(config.wsUrl).toBe('wss://example/ws');
    expect(config.cdpPort).toBe(19999);
    expect(config.headless).toBe(true);
    expect(config.noSandbox).toBe(true);
    expect(config.attachOnly).toBe(true);
    expect(config.nodeName).toBe('Custom Node');
    expect(config.operatorToken).toBe('arg-operator');
    expect(config.token).toBe('arg-token');
    expect(config.executablePath).toBe('/arg/chrome');
  });

  it('falls back to stored token and env operator token', () => {
    const config = resolveCliConfig({
      args: parseCliArgs([]),
      hostname: 'host',
      storedToken: 'stored-token',
      env: {
        LEMON_OPERATOR_TOKEN: 'env-operator',
      } as NodeJS.ProcessEnv,
    });

    expect(config.token).toBe('stored-token');
    expect(config.operatorToken).toBe('env-operator');
  });
});
