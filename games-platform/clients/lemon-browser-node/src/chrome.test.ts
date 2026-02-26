import { describe, expect, it, vi } from 'vitest';

import { ChromeSession } from './chrome.js';

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
