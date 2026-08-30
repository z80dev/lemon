import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

import { describe, expect, it } from 'vitest';

type Listener = (...args: any[]) => void;

class FakeWebSocket {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;

  readonly url: string;
  readyState = FakeWebSocket.CONNECTING;
  sent: string[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;

  constructor(url: string) {
    this.url = url;
  }

  open(): void {
    this.readyState = FakeWebSocket.OPEN;
    this.onopen?.();
  }

  receive(value: unknown): void {
    this.onmessage?.({ data: JSON.stringify(value) });
  }

  send(value: string): void {
    this.sent.push(value);
  }

  close(): void {
    this.readyState = 3;
    this.onclose?.();
  }
}

describe('MV3 extension service worker', () => {
  it('shares only opted-in tabs, gates debugger RPC, auto-scopes created tabs, and detaches', async () => {
    const harness = await loadBackground({ allowedTabIds: [1] });
    const socket = harness.sockets[0];

    expect(socket.url).toBe('ws://127.0.0.1:9224/ext?token=relay-secret');
    socket.open();
    await settle();

    expect(messages(socket)[0]).toMatchObject({
      t: 'hello',
      tabs: [{ tabId: 1, targetId: 'target-1' }],
    });
    expect(messages(socket)[0].tabs).toHaveLength(1);

    socket.receive({ t: 'rpc', id: 'blocked', op: 'attach', tabId: 2 });
    await settle();
    expect(messages(socket).at(-1)).toEqual({
      t: 'rpcResult',
      id: 'blocked',
      ok: false,
      error: 'tab is not opted in to Lemon Browser Relay',
    });
    expect(harness.debuggerCalls.attach).toEqual([]);

    socket.receive({ t: 'rpc', id: 'attach', op: 'attach', tabId: 1 });
    await settle();
    expect(harness.debuggerCalls.attach).toEqual([{ target: { tabId: 1 }, version: '1.3' }]);
    expect(messages(socket).at(-1)).toEqual({ t: 'rpcResult', id: 'attach', ok: true, result: {} });

    socket.receive({ t: 'rpc', id: 'create', op: 'createTab', url: 'https://created.test/' });
    await settle();
    expect(harness.storage.allowedTabIds).toEqual([1, 3]);
    expect(messages(socket).at(-1)).toMatchObject({
      t: 'rpcResult',
      id: 'create',
      ok: true,
      result: { tab: { tabId: 3, targetId: 'target-3' } },
    });

    harness.listeners.actionClicked?.(harness.tabs.get(1));
    await settle();
    expect(harness.storage.allowedTabIds).toEqual([3]);
    expect(harness.debuggerCalls.detach).toContainEqual({ tabId: 1 });
    expect(messages(socket)).toContainEqual({ t: 'tabRemoved', tabId: 1 });
    expect(harness.badges).toContainEqual({ tabId: 1, text: '' });
  });

  it('requires a user click for existing tabs and sends no debugger event for hidden tabs', async () => {
    const harness = await loadBackground({ allowedTabIds: [] });
    const socket = harness.sockets[0];
    socket.open();
    await settle();

    expect(messages(socket)[0]).toMatchObject({ t: 'hello', tabs: [], attachedTabIds: [] });

    harness.listeners.debuggerEvent?.({ tabId: 2 }, 'Runtime.consoleAPICalled', { value: 'private' });
    expect(messages(socket)).toHaveLength(1);

    harness.listeners.actionClicked?.(harness.tabs.get(2));
    await settle();
    expect(harness.storage.allowedTabIds).toEqual([2]);
    expect(messages(socket).at(-1)).toMatchObject({
      t: 'tabCreated',
      tab: { tabId: 2, targetId: 'target-2' },
    });

    harness.listeners.debuggerEvent?.({ tabId: 2 }, 'Runtime.consoleAPICalled', { value: 'visible' });
    expect(messages(socket).at(-1)).toEqual({
      t: 'cdpEvent',
      tabId: 2,
      method: 'Runtime.consoleAPICalled',
      params: { value: 'visible' },
    });
  });
});

async function loadBackground(initial: { allowedTabIds: number[] }) {
  const source = await readFile(new URL('../extension/background.js', import.meta.url), 'utf8');
  const listeners: Record<string, Listener | undefined> = {};
  const sockets: FakeWebSocket[] = [];
  const badges: Array<Record<string, unknown>> = [];
  const storage: Record<string, unknown> = {
    port: 9224,
    token: 'relay-secret',
    allowedTabIds: [...initial.allowedTabIds],
  };
  const tabs = new Map([
    [1, tab(1, 'https://one.test/', 'One')],
    [2, tab(2, 'https://two.test/', 'Two')],
  ]);
  const debuggerCalls = { attach: [] as unknown[], detach: [] as unknown[], send: [] as unknown[] };
  const event = (name: string) => ({ addListener: (listener: Listener) => (listeners[name] = listener) });

  const chrome = {
    action: {
      setBadgeText: async (value: Record<string, unknown>) => void badges.push(value),
      setBadgeBackgroundColor: async () => undefined,
      onClicked: event('actionClicked'),
    },
    alarms: {
      create: () => undefined,
      onAlarm: event('alarm'),
    },
    debugger: {
      getTargets: async () =>
        [...tabs.keys()].map((tabId) => ({ id: `target-${tabId}`, tabId, attached: tabId === 1 })),
      attach: async (target: unknown, version: string) => {
        debuggerCalls.attach.push({ target, version });
      },
      detach: async (target: unknown) => {
        debuggerCalls.detach.push(target);
      },
      sendCommand: async (...args: unknown[]) => {
        debuggerCalls.send.push(args);
        return { ok: true };
      },
      onEvent: event('debuggerEvent'),
      onDetach: event('debuggerDetach'),
    },
    runtime: {
      openOptionsPage: async () => undefined,
      onInstalled: event('installed'),
      onStartup: event('startup'),
    },
    storage: {
      local: {
        get: async (defaults: Record<string, unknown>) => ({ ...defaults, ...storage }),
        set: async (values: Record<string, unknown>) => Object.assign(storage, values),
      },
      onChanged: event('storageChanged'),
    },
    tabs: {
      query: async () => [...tabs.values()],
      create: async ({ url }: { url: string }) => {
        const value = tab(3, url, 'Created');
        tabs.set(3, value);
        return value;
      },
      remove: async (tabId: number) => void tabs.delete(tabId),
      get: async (tabId: number) => tabs.get(tabId),
      update: async () => undefined,
      onCreated: event('tabCreated'),
      onUpdated: event('tabUpdated'),
      onRemoved: event('tabRemoved'),
    },
    windows: { update: async () => undefined },
  };

  class CapturedWebSocket extends FakeWebSocket {
    constructor(url: string) {
      super(url);
      sockets.push(this);
    }
  }

  vm.runInNewContext(source, {
    chrome,
    navigator: { userAgent: 'Chrome/140 test' },
    WebSocket: CapturedWebSocket,
    URL,
    JSON,
    Number,
    Map,
    Set,
    Promise,
    Error,
    String,
    RegExp,
    encodeURIComponent,
    setTimeout: () => 1,
    setInterval: () => 2,
    clearInterval: () => undefined,
  });
  await settle();

  return { badges, chrome, debuggerCalls, listeners, sockets, storage, tabs };
}

function tab(id: number, url: string, title: string) {
  return { id, url, title, active: id === 1, windowId: 10, pinned: false };
}

function messages(socket: FakeWebSocket): any[] {
  return socket.sent.map((value) => JSON.parse(value));
}

async function settle(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
  await new Promise((resolve) => setImmediate(resolve));
}
