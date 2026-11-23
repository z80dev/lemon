import { describe, expect, it, vi } from 'vitest';

import { parseCliArgs } from './cli-args.js';
import { OutcomeUnknownError } from './chrome.js';
import { isReadOnlyBrowserMethod } from './driver-dispatch.js';
import {
  createDriverRequestQueue,
  resolveLocalDriverConfig,
  type LocalDriverResponse,
} from './local-driver.js';

describe('resolveLocalDriverConfig', () => {
  it('uses env defaults when args are absent', () => {
    const config = resolveLocalDriverConfig({
      args: parseCliArgs([]),
      env: {
        LEMON_BROWSER_CDP_PORT: '19900',
        LEMON_BROWSER_CDP_ENDPOINT: 'http://remote.example.test:9222',
        LEMON_BROWSER_HEADLESS: 'true',
        LEMON_BROWSER_NO_SANDBOX: 'yes',
        LEMON_BROWSER_EXECUTABLE: '/env/chrome',
        LEMON_BROWSER_USER_DATA_DIR: '/env/profile',
      } as NodeJS.ProcessEnv,
    });

    expect(config.cdpPort).toBe(19900);
    expect(config.cdpEndpoint).toBe('http://remote.example.test:9222');
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
        '--cdp-endpoint', 'http://arg.example.test:9333',
        '--headless',
        '--no-sandbox',
        '--executable-path', '/arg/chrome',
        '--user-data-dir', '/arg/profile',
      ]),
      env: {
        LEMON_BROWSER_CDP_PORT: '19900',
        LEMON_BROWSER_CDP_ENDPOINT: 'http://env.example.test:9222',
        LEMON_BROWSER_EXECUTABLE: '/env/chrome',
        LEMON_BROWSER_USER_DATA_DIR: '/env/profile',
      } as NodeJS.ProcessEnv,
    });

    expect(config.cdpPort).toBe(20001);
    expect(config.cdpEndpoint).toBe('http://arg.example.test:9333');
    expect(config.headless).toBe(true);
    expect(config.noSandbox).toBe(true);
    expect(config.attachOnly).toBe(true);
    expect(config.executablePath).toBe('/arg/chrome');
    expect(config.userDataDir).toBe('/arg/profile');
  });
});

describe('createDriverRequestQueue', () => {
  function harness(overrides: Partial<Parameters<typeof createDriverRequestQueue>[0]> = {}) {
    const replies: LocalDriverResponse[] = [];
    const invoked: string[] = [];
    const onWedged = vi.fn();
    const queue = createDriverRequestQueue({
      invoke: async (method, args, begin) => {
        begin();
        invoked.push(method);
        return { method, args };
      },
      reply: (response) => replies.push(response),
      isReadOnly: isReadOnlyBrowserMethod,
      onWedged,
      ...overrides,
    });
    return { queue, replies, invoked, onWedged };
  }

  function deferred() {
    let resolve!: (value?: unknown) => void;
    const promise = new Promise((r) => {
      resolve = r;
    });
    return { promise, resolve };
  }

  function line(id: string, method: string, extra: Record<string, unknown> = {}) {
    return JSON.stringify({ id, method, args: {}, timeoutMs: 1_000, ...extra });
  }

  it('returns invalid json error', async () => {
    const { queue, replies } = harness();
    queue.submit('{not-json');
    await queue.drained();

    expect(replies).toHaveLength(1);
    expect(replies[0]!.ok).toBe(false);
    expect(replies[0]!.id).toBe('unknown');
    expect(replies[0]!.error).toContain('invalid json');
  });

  it('invokes method and returns result', async () => {
    const { queue, replies } = harness();
    queue.submit(
      JSON.stringify({
        id: 'req-1',
        method: 'browser.navigate',
        args: { url: 'https://example.com' },
        timeoutMs: 1000,
      }),
    );
    await queue.drained();

    expect(replies).toEqual([
      {
        id: 'req-1',
        ok: true,
        result: { method: 'browser.navigate', args: { url: 'https://example.com' } },
      },
    ]);
  });

  it('never invokes a request whose caller deadline already passed', async () => {
    const { queue, replies, invoked } = harness();
    queue.submit(line('late', 'browser.click', { deadlineAtMs: Date.now() - 1 }));
    await queue.drained();

    expect(invoked).toEqual([]);
    expect(replies).toEqual([expect.objectContaining({ id: 'late', ok: false, code: 'not_started' })]);
  });

  it('answers a queued request not_started at its deadline and never runs it', async () => {
    const gate = deferred();
    const invoked: string[] = [];
    const { queue, replies } = harness({
      invoke: async (method, _args, begin) => {
        begin();
        invoked.push(method);
        if (method === 'browser.navigate') await gate.promise;
        return {};
      },
    });

    queue.submit(line('first', 'browser.navigate', { timeoutMs: 5_000 }));
    queue.submit(line('second', 'browser.click', { timeoutMs: 20 }));
    await new Promise((resolve) => setTimeout(resolve, 60));

    // Answered while still queued, before the first request settled.
    expect(replies).toEqual([expect.objectContaining({ id: 'second', code: 'not_started' })]);

    gate.resolve();
    await queue.drained();
    expect(invoked).toEqual(['browser.navigate']);
    expect(replies.map((reply) => reply.id)).toEqual(['second', 'first']);
  });

  it('reports a timed-out click as outcome_unknown, runs it once and holds the queue until it settles', async () => {
    const gate = deferred();
    const invoked: string[] = [];
    const { queue, replies } = harness({
      invoke: async (method, _args, begin) => {
        begin();
        invoked.push(method);
        if (method === 'browser.click') await gate.promise;
        return { method };
      },
    });

    queue.submit(line('click', 'browser.click', { timeoutMs: 20 }));
    queue.submit(line('next', 'browser.tabs', { timeoutMs: 5_000 }));
    await new Promise((resolve) => setTimeout(resolve, 60));

    expect(replies).toEqual([
      {
        id: 'click',
        ok: false,
        code: 'outcome_unknown',
        error: 'browser.click did not finish before its deadline; it may have taken effect',
      },
    ]);
    // The next request does not overlap the abandoned click.
    expect(invoked).toEqual(['browser.click']);

    gate.resolve();
    await queue.drained();
    expect(invoked).toEqual(['browser.click', 'browser.tabs']);
    expect(replies.filter((reply) => reply.id === 'click')).toHaveLength(1);
  });

  it('reports a timed-out read-only request as a plain timeout', async () => {
    const gate = deferred();
    const { queue, replies } = harness({
      invoke: async (_method, _args, begin) => {
        begin();
        await gate.promise;
        return {};
      },
    });

    queue.submit(line('read', 'browser.snapshot', { timeoutMs: 5 }));
    await new Promise((resolve) => setTimeout(resolve, 30));
    gate.resolve();
    await queue.drained();

    expect(replies).toEqual([{ id: 'read', ok: false, code: 'timeout', error: 'timeout after 5ms' }]);
  });

  it('answers not_started when the deadline passes before the side effect begins', async () => {
    const startup = deferred();
    const effects: string[] = [];
    const { queue, replies } = harness({
      invoke: async (method, _args, begin) => {
        await startup.promise;
        begin();
        effects.push(method);
        return {};
      },
    });

    queue.submit(line('slow-start', 'browser.click', { timeoutMs: 10 }));
    await new Promise((resolve) => setTimeout(resolve, 30));
    startup.resolve();
    await queue.drained();

    expect(effects).toEqual([]);
    expect(replies).toEqual([expect.objectContaining({ id: 'slow-start', code: 'not_started' })]);
  });

  it('surfaces an unknown-outcome error from the browser with its code', async () => {
    const { queue, replies } = harness({
      invoke: async (_method, _args, begin) => {
        begin();
        throw new OutcomeUnknownError('the browser target closed while the action ran; it may have taken effect');
      },
    });

    queue.submit(line('closed', 'browser.type'));
    await queue.drained();

    expect(replies).toEqual([expect.objectContaining({ id: 'closed', ok: false, code: 'outcome_unknown' })]);
  });

  it('reports a wedged invocation that never settles after its deadline', async () => {
    const gate = deferred();
    const { queue, onWedged } = harness({
      settleGraceMs: 10,
      invoke: async (_method, _args, begin) => {
        begin();
        await gate.promise;
        return {};
      },
    });

    queue.submit(line('stuck', 'browser.click', { timeoutMs: 5 }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(onWedged).toHaveBeenCalledTimes(1);

    gate.resolve();
    await queue.drained();
  });
});
