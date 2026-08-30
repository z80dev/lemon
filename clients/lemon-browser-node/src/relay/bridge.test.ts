import { describe, expect, it } from 'vitest';

import { RelayBridge, type RelaySocket } from './bridge.js';

class FakeSocket implements RelaySocket {
  messages: any[] = [];
  closed = false;
  send(text: string): void {
    this.messages.push(JSON.parse(text));
  }
  close(): void {
    this.closed = true;
  }
}

describe('RelayBridge', () => {
  it('synthesizes targets, forwards page commands, and ignores Browser.close', async () => {
    const bridge = new RelayBridge();
    const extension = new FakeSocket();
    const cdp = new FakeSocket();
    bridge.extensionConnected(extension);
    bridge.extensionMessage(
      extension,
      JSON.stringify({
        t: 'hello',
        userAgent: 'Chrome test',
        browserVersion: 'Chrome/140',
        tabs: [tab(7, 'https://example.com'), tab(8, 'chrome://settings')],
        attachedTabIds: [],
      }),
    );

    expect(bridge.ready).toBe(true);
    expect(bridge.listTargets()).toEqual([
      { id: 'target-7', type: 'page', title: 'Tab 7', url: 'https://example.com' },
    ]);

    const connectionId = bridge.cdpConnected(cdp);
    bridge.cdpMessage(
      connectionId,
      JSON.stringify({ id: 1, method: 'Target.setDiscoverTargets', params: { discover: true } }),
    );
    await tick();
    expect(cdp.messages).toContainEqual(
      expect.objectContaining({
        method: 'Target.targetCreated',
        params: { targetInfo: expect.objectContaining({ targetId: 'target-7' }) },
      }),
    );

    bridge.cdpMessage(
      connectionId,
      JSON.stringify({ id: 2, method: 'Target.attachToTarget', params: { targetId: 'target-7' } }),
    );
    await tick();
    const attach = extension.messages.find((message) => message.op === 'attach');
    expect(attach).toEqual(expect.objectContaining({ t: 'rpc', tabId: 7 }));
    bridge.extensionMessage(
      extension,
      JSON.stringify({ t: 'rpcResult', id: attach.id, ok: true, result: {} }),
    );
    await tick();
    const attached = cdp.messages.find((message) => message.method === 'Target.attachedToTarget');
    const sessionId = attached.params.sessionId;
    expect(sessionId).toMatch(/^LEMON\.7\./);

    bridge.cdpMessage(
      connectionId,
      JSON.stringify({
        id: 3,
        sessionId,
        method: 'Runtime.evaluate',
        params: { expression: 'document.title' },
      }),
    );
    await tick();
    const evaluate = extension.messages.find((message) => message.method === 'Runtime.evaluate');
    expect(evaluate).toEqual(expect.objectContaining({ op: 'send', tabId: 7 }));
    bridge.extensionMessage(
      extension,
      JSON.stringify({
        t: 'rpcResult',
        id: evaluate.id,
        ok: true,
        result: { result: { value: 'Example' } },
      }),
    );
    await tick();
    expect(cdp.messages).toContainEqual(
      expect.objectContaining({ id: 3, sessionId, result: { result: { value: 'Example' } } }),
    );

    const extensionMessageCount = extension.messages.length;
    bridge.cdpMessage(connectionId, JSON.stringify({ id: 4, method: 'Browser.close' }));
    await tick();
    expect(extension.messages).toHaveLength(extensionMessageCount);
    expect(cdp.messages).toContainEqual(expect.objectContaining({ id: 4, result: {} }));
  });

  it('rejects unsupported browser-level methods', async () => {
    const bridge = new RelayBridge();
    const cdp = new FakeSocket();
    const connectionId = bridge.cdpConnected(cdp);
    bridge.cdpMessage(connectionId, JSON.stringify({ id: 9, method: 'Browser.deleteEverything' }));
    await tick();
    expect(cdp.messages[0]).toEqual({
      id: 9,
      error: { code: -32601, message: "'Browser.deleteEverything' wasn't found" },
    });
  });
});

function tab(tabId: number, url: string) {
  return { tabId, targetId: `target-${tabId}`, url, title: `Tab ${tabId}`, active: tabId === 7, windowId: 1, pinned: false };
}

function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}
