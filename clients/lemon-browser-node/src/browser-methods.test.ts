import { describe, expect, it } from 'vitest';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

import { handleBrowserMethod } from './browser-methods.js';

type Listener = (payload: unknown) => void;

describe('handleBrowserMethod extra controls', () => {
  it('buffers console and dialog events', async () => {
    const listeners = new Map<string, Listener[]>();
    const dismissed: string[] = [];
    const page = {
      on: (event: string, callback: Listener) => {
        listeners.set(event, [...(listeners.get(event) ?? []), callback]);
      },
    } as any;

    const emit = (event: string, payload: unknown) => {
      for (const callback of listeners.get(event) ?? []) {
        callback(payload);
      }
    };

    await handleBrowserMethod(page, 'browser.events', {});

    emit('console', {
      type: () => 'error',
      text: () => 'boom',
      location: () => ({ url: 'https://example.com/app.js', lineNumber: 12, columnNumber: 3 }),
    });

    emit('dialog', {
      type: () => 'alert',
      message: () => 'Confirm?',
      defaultValue: () => '',
      dismiss: async () => {
        dismissed.push('dialog');
      },
    });

    const result = await handleBrowserMethod(page, 'browser.events', { limit: 10 });

    expect(result).toEqual({
      count: 2,
      cleared: false,
      events: [
        {
          type: 'console',
          level: 'error',
          text: 'boom',
          location: { url: 'https://example.com/app.js', lineNumber: 12, columnNumber: 3 },
          timestamp: expect.any(String),
        },
        {
          type: 'dialog',
          dialogType: 'alert',
          message: 'Confirm?',
          defaultValue: '',
          timestamp: expect.any(String),
        },
      ],
    });

    expect(dismissed).toEqual(['dialog']);
  });

  it('clears buffered events after returning them', async () => {
    const listeners = new Map<string, Listener[]>();
    const page = {
      on: (event: string, callback: Listener) => {
        listeners.set(event, [...(listeners.get(event) ?? []), callback]);
      },
    } as any;

    await handleBrowserMethod(page, 'browser.events', {});

    for (const callback of listeners.get('pageerror') ?? []) {
      callback(new Error('render failed'));
    }

    const first = (await handleBrowserMethod(page, 'browser.events', { clear: true })) as any;
    const second = await handleBrowserMethod(page, 'browser.events', {});

    expect(first.count).toBe(1);
    expect(first.cleared).toBe(true);
    expect(first.events[0]).toMatchObject({
      type: 'pageerror',
      name: 'Error',
      message: 'render failed',
    });
    expect(second).toEqual({ events: [], count: 0, cleared: false });
  });

  it('presses a key through a selector when provided', async () => {
    const calls: unknown[] = [];
    const page = {
      press: async (selector: string, key: string, opts: unknown) => {
        calls.push({ selector, key, opts });
      },
      keyboard: {
        press: async (key: string) => {
          calls.push({ keyboard: key });
        },
      },
    } as any;

    const result = await handleBrowserMethod(page, 'browser.press', {
      selector: '#query',
      key: 'Enter',
      timeoutMs: 250,
    });

    expect(result).toEqual({ pressed: true, key: 'Enter' });
    expect(calls).toEqual([{ selector: '#query', key: 'Enter', opts: { timeout: 250 } }]);
  });

  it('presses a key through keyboard when no selector is provided', async () => {
    const calls: unknown[] = [];
    const page = {
      press: async () => {
        throw new Error('unexpected selector press');
      },
      keyboard: {
        press: async (key: string) => {
          calls.push(key);
        },
      },
    } as any;

    const result = await handleBrowserMethod(page, 'browser.press', { key: 'Escape' });

    expect(result).toEqual({ pressed: true, key: 'Escape' });
    expect(calls).toEqual(['Escape']);
  });

  it('waits for a selector', async () => {
    const calls: unknown[] = [];
    const page = {
      waitForSelector: async (selector: string, opts: unknown) => {
        calls.push({ selector, opts });
      },
    } as any;

    const result = await handleBrowserMethod(page, 'browser.waitForSelector', {
      selector: '#ready',
      timeoutMs: 250,
    });

    expect(result).toEqual({ found: true });
    expect(calls).toEqual([{ selector: '#ready', opts: { timeout: 250 } }]);
  });

  it('evaluates a page expression', async () => {
    const page = {
      evaluate: async (expression: string) => {
        return { expression, ready: true };
      },
    } as any;

    const result = await handleBrowserMethod(page, 'browser.evaluate', {
      expression: '(() => window.ready)()',
    });

    expect(result).toEqual({ result: { expression: '(() => window.ready)()', ready: true } });
  });

  it('hovers a selector', async () => {
    const calls: unknown[] = [];
    const page = {
      hover: async (selector: string, opts: unknown) => {
        calls.push({ selector, opts });
      },
    } as any;

    const result = await handleBrowserMethod(page, 'browser.hover', {
      selector: '#menu',
      timeoutMs: 250,
    });

    expect(result).toEqual({ hovered: true });
    expect(calls).toEqual([{ selector: '#menu', opts: { timeout: 250 } }]);
  });

  it('selects one or more options', async () => {
    const calls: unknown[] = [];
    const page = {
      selectOption: async (selector: string, values: unknown, opts: unknown) => {
        calls.push({ selector, values, opts });
        return Array.isArray(values) ? values : [values];
      },
    } as any;

    const single = await handleBrowserMethod(page, 'browser.selectOption', {
      selector: '#mode',
      value: 'beam',
      timeoutMs: 250,
    });

    const multi = await handleBrowserMethod(page, 'browser.selectOption', {
      selector: '#mode',
      values: ['beam', 'otp'],
      timeoutMs: 300,
    });

    expect(single).toEqual({ selected: ['beam'], count: 1 });
    expect(multi).toEqual({ selected: ['beam', 'otp'], count: 2 });
    expect(calls).toEqual([
      { selector: '#mode', values: 'beam', opts: { timeout: 250 } },
      { selector: '#mode', values: ['beam', 'otp'], opts: { timeout: 300 } },
    ]);
  });

  it('sets input files for upload controls', async () => {
    const calls: unknown[] = [];
    const page = {
      setInputFiles: async (selector: string, paths: unknown, opts: unknown) => {
        calls.push({ selector, paths, opts });
      },
    } as any;

    const single = await handleBrowserMethod(page, 'browser.setInputFiles', {
      selector: '#upload',
      path: '/tmp/proof.txt',
      timeoutMs: 250,
    });

    const multi = await handleBrowserMethod(page, 'browser.setInputFiles', {
      selector: '#upload',
      paths: ['/tmp/a.txt', '/tmp/b.txt'],
      timeoutMs: 300,
    });

    expect(single).toEqual({ uploaded: true, count: 1 });
    expect(multi).toEqual({ uploaded: true, count: 2 });
    expect(calls).toEqual([
      { selector: '#upload', paths: '/tmp/proof.txt', opts: { timeout: 250 } },
      { selector: '#upload', paths: ['/tmp/a.txt', '/tmp/b.txt'], opts: { timeout: 300 } },
    ]);
  });

  it('clicks and saves a browser download', async () => {
    const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'lemon-browser-download-'));
    const saved: unknown[] = [];
    const page = {
      waitForEvent: async (event: string, opts: unknown) => {
        expect(event).toBe('download');
        expect(opts).toEqual({ timeout: 250 });

        return {
          suggestedFilename: () => 'proof.txt',
          saveAs: async (targetPath: string) => {
            saved.push(targetPath);
            await fs.writeFile(targetPath, 'download proof');
          },
        };
      },
      click: async (selector: string, opts: unknown) => {
        saved.push({ selector, opts });
      },
    } as any;

    const result = await handleBrowserMethod(page, 'browser.download', {
      selector: '#download',
      dir: tmpDir,
      timeoutMs: 250,
    });

    expect(result).toMatchObject({
      downloaded: true,
      path: path.join(tmpDir, 'proof.txt'),
      suggestedFilename: 'proof.txt',
      bytes: 'download proof'.length,
    });

    expect(saved).toEqual([{ selector: '#download', opts: { timeout: 250 } }, path.join(tmpDir, 'proof.txt')]);
  });

  it('scrolls by delta and returns position', async () => {
    const evaluations: unknown[] = [];
    const page = {
      evaluate: async (fn: unknown, args?: unknown) => {
        evaluations.push(args ?? null);
        if (args) return undefined;
        return { x: 0, y: 600 };
      },
    } as any;

    const result = await handleBrowserMethod(page, 'browser.scroll', { deltaY: 600 });

    expect(result).toEqual({ scrolled: true, position: { x: 0, y: 600 } });
    expect(evaluations).toEqual([{ x: 0, y: 600 }, null]);
  });

  it('goes back and returns page metadata', async () => {
    const page = {
      goBack: async () => ({ status: () => 200 }),
      url: () => 'https://example.com/previous',
      title: async () => 'Previous',
    } as any;

    const result = await handleBrowserMethod(page, 'browser.back', {});

    expect(result).toEqual({
      url: 'https://example.com/previous',
      status: 200,
      title: 'Previous',
    });
  });

  it('gets and sets cookies through the browser context', async () => {
    const calls: unknown[] = [];
    const page = {
      context: () => ({
        cookies: async (urls?: string[]) => {
          calls.push({ cookies: urls });
          return [{ name: 'session', value: 'abc', domain: 'example.com', path: '/' }];
        },
        addCookies: async (cookies: unknown[]) => {
          calls.push({ addCookies: cookies });
        },
      }),
    } as any;

    const getResult = await handleBrowserMethod(page, 'browser.getCookies', {
      url: 'https://example.com',
    });
    const setResult = await handleBrowserMethod(page, 'browser.setCookies', {
      cookies: [{ name: 'session', value: 'abc', url: 'https://example.com' }],
    });

    expect(getResult).toEqual({
      cookies: [{ name: 'session', value: 'abc', domain: 'example.com', path: '/' }],
    });
    expect(setResult).toEqual({ set: 1 });
    expect(calls).toEqual([
      { cookies: ['https://example.com'] },
      { addCookies: [{ name: 'session', value: 'abc', url: 'https://example.com' }] },
    ]);
  });

  it('clears cookies, page storage, and buffered events', async () => {
    const listeners = new Map<string, Listener[]>();
    const calls: string[] = [];
    const page = {
      on: (event: string, callback: Listener) => {
        listeners.set(event, [...(listeners.get(event) ?? []), callback]);
      },
      url: () => 'https://example.com/app',
      context: () => ({
        clearCookies: async () => {
          calls.push('clearCookies');
        },
      }),
      evaluate: async () => {
        calls.push('clearStorage');
      },
    } as any;

    await handleBrowserMethod(page, 'browser.events', {});
    for (const callback of listeners.get('console') ?? []) {
      callback({
        type: () => 'log',
        text: () => 'before clear',
        location: () => null,
      });
    }

    const result = await handleBrowserMethod(page, 'browser.clearState', {});
    const events = await handleBrowserMethod(page, 'browser.events', {});

    expect(result).toEqual({
      cookiesCleared: true,
      storageCleared: true,
      eventsCleared: true,
      url: 'https://example.com/app',
    });
    expect(events).toEqual({ events: [], count: 0, cleared: false });
    expect(calls).toEqual(['clearCookies', 'clearStorage']);
  });
});
