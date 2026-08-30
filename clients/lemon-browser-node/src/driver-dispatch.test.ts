import { describe, expect, it, vi } from 'vitest';

import { dispatchBrowserRequest } from './driver-dispatch.js';

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

    expect(chrome.withPage).toHaveBeenCalledWith(expect.any(Function), 'tab-2');
    expect(result).toEqual(expect.objectContaining({ url: 'https://example.com' }));
  });

  it('requires a target ID for activate and close', async () => {
    const chrome = {} as any;
    await expect(dispatchBrowserRequest(chrome, 'tabActivate', {})).rejects.toThrow(
      'targetId is required',
    );
  });
});
