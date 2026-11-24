import { describe, expect, it, vi } from 'vitest';

// Destination checks resolve hostnames; keep these unit tests off live DNS.
vi.mock('node:dns/promises', () => ({
  lookup: vi.fn().mockResolvedValue([{ address: '93.184.215.14', family: 4 }]),
}));

import { dispatchBrowserRequest, isReadOnlyBrowserMethod } from './driver-dispatch.js';

describe('isReadOnlyBrowserMethod', () => {
  it.each(['browser.tabs', 'screenshot', 'browser.snapshot', 'browser.getContent', 'browser.getCookies', 'browser.waitForSelector', 'browser.cdp', 'browser.events'])(
    'treats %s as read-only',
    (method) => expect(isReadOnlyBrowserMethod(method, {})).toBe(true),
  );

  it.each(['browser.click', 'type', 'browser.press', 'browser.navigate', 'browser.selectOption', 'browser.setInputFiles', 'browser.download', 'browser.hover', 'browser.scroll', 'browser.back', 'browser.evaluate', 'browser.setCookies', 'browser.clearState', 'browser.tabOpen', 'browser.tabActivate', 'browser.tabClose', 'browser.unknownFuture'])(
    'treats %s as side-effecting',
    (method) => expect(isReadOnlyBrowserMethod(method, {})).toBe(false),
  );

  it('treats an event read that clears the buffer as side-effecting', () => {
    expect(isReadOnlyBrowserMethod('browser.events', { clear: true })).toBe(false);
  });
});

describe('dispatchBrowserRequest', () => {
  it('routes tab lifecycle methods to the Chrome session', async () => {
    const chrome = {
      listTabs: vi.fn().mockResolvedValue({ tabs: [] }),
      openTab: vi.fn().mockResolvedValue({ targetId: 'new' }),
      activateTab: vi.fn().mockResolvedValue({ targetId: 'tab-1' }),
      closeTab: vi.fn().mockResolvedValue({ closed: true }),
    } as any;

    await dispatchBrowserRequest(chrome, 'browser.tabs', {});
    await dispatchBrowserRequest(chrome, 'tabOpen', { url: 'https://example.com' });
    await dispatchBrowserRequest(chrome, 'browser.tabActivate', { targetId: 'tab-1' });
    await dispatchBrowserRequest(chrome, 'tabClose', { targetId: 'tab-1' });

    expect(chrome.listTabs).toHaveBeenCalledTimes(1);
    expect(chrome.openTab).toHaveBeenCalledWith('https://example.com');
    expect(chrome.activateTab).toHaveBeenCalledWith('tab-1');
    expect(chrome.closeTab).toHaveBeenCalledWith('tab-1');
  });

  it('passes targetId to selection but not to the page method', async () => {
    const page = {
      goto: vi.fn().mockResolvedValue({ status: () => 200 }),
      url: vi.fn().mockReturnValue('https://example.com'),
      title: vi.fn().mockResolvedValue('Example'),
    };
    const chrome = {
      withPage: vi.fn(async (operation) => operation(page)),
    } as any;

    const result = await dispatchBrowserRequest(chrome, 'browser.navigate', {
      targetId: 'tab-2',
      url: 'https://example.com',
    });

    // Navigation is side-effecting: a closed target never re-runs it.
    expect(chrome.withPage).toHaveBeenCalledWith(expect.any(Function), 'tab-2', {
      retryOnClosedTarget: false,
    });
    expect(result).toEqual(expect.objectContaining({ url: 'https://example.com' }));
  });

  it('requires a target ID for activate and close', async () => {
    const chrome = {} as any;
    await expect(dispatchBrowserRequest(chrome, 'tabActivate', {})).rejects.toThrow(
      'targetId is required',
    );
  });

  it('routes raw CDP commands with params and an optional target', async () => {
    const chrome = {
      sendCdp: vi.fn().mockResolvedValue({ root: { nodeId: 1 } }),
    } as any;

    const result = await dispatchBrowserRequest(chrome, 'browser.cdp', {
      method: 'DOM.getDocument',
      params: { depth: 1 },
      targetId: 'tab-2',
    });

    expect(chrome.sendCdp).toHaveBeenCalledWith('DOM.getDocument', { depth: 1 }, 'tab-2');
    expect(result).toEqual({ root: { nodeId: 1 } });
  });

  it.each(['Page.navigate', 'Runtime.evaluate', 'Target.createTarget', 'Fetch.enable', 'Network.loadNetworkResource'])(
    'refuses network-capable raw CDP method %s',
    async (method) => {
      const chrome = { sendCdp: vi.fn() } as unknown as Parameters<typeof dispatchBrowserRequest>[0];
      await expect(
        dispatchBrowserRequest(chrome, 'browser.cdp', { method, params: { url: 'http://169.254.169.254/' } }),
      ).rejects.toThrow(`CDP method ${method} is not allowed`);
      expect(chrome.sendCdp).not.toHaveBeenCalled();
    },
  );

  it('refuses to open a tab on a metadata destination', async () => {
    const chrome = { openTab: vi.fn() } as unknown as Parameters<typeof dispatchBrowserRequest>[0];
    await expect(dispatchBrowserRequest(chrome, 'tabOpen', { url: 'http://2852039166/' })).rejects.toThrow(
      /blocked metadata endpoint/,
    );
    expect(chrome.openTab).not.toHaveBeenCalled();
  });
});
