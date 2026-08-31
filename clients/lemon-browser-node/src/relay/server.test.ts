import { describe, expect, it } from 'vitest';
import { WebSocket } from 'ws';

import { startRelayServer } from './server.js';

describe('browser relay server', () => {
  it('requires a token, binds loopback, and serves CDP discovery after extension hello', async () => {
    await expect(startRelayServer({ port: 0, token: '' })).rejects.toThrow(
      'browser relay token is required',
    );
    await expect(
      startRelayServer({ port: 0, token: 'secret', host: '0.0.0.0' }),
    ).rejects.toThrow('browser relay must bind to a loopback address');

    const relay = await startRelayServer({ port: 0, token: 'secret' });
    try {
      const root = `http://127.0.0.1:${relay.port}`;
      expect((await fetch(`${root}/health`)).status).toBe(401);
      expect((await fetch(`${root}/health?token=wrong`)).status).toBe(401);
      expect((await fetch(`${root}/health?token=secret`)).status).toBe(200);
      expect((await fetch(`${root}/json/version?token=secret`)).status).toBe(503);

      const extension = await openSocket(`ws://127.0.0.1:${relay.port}/ext?token=secret`, {
        Origin: 'chrome-extension://gjglijccjcaldhmkencnboofkfebhgog',
      });
      extension.send(
        JSON.stringify({
          t: 'hello',
          userAgent: 'Chrome test',
          browserVersion: 'Chrome/140',
          tabs: [],
          attachedTabIds: [],
        }),
      );
      await tick();

      const version = await fetch(`${root}/json/version?token=secret`);
      expect(version.status).toBe(200);
      const payload = (await version.json()) as { webSocketDebuggerUrl: string };
      expect(payload.webSocketDebuggerUrl).toBe(
        `ws://127.0.0.1:${relay.port}/cdp?token=secret`,
      );

      const cdp = await openSocket(`ws://127.0.0.1:${relay.port}/cdp?token=secret`);
      cdp.close();
      extension.close();
    } finally {
      await relay.stop();
    }
  });

  it('rejects browser-originated CDP websocket connections', async () => {
    const relay = await startRelayServer({ port: 0, token: 'secret' });
    try {
      await expect(
        openSocket(`ws://127.0.0.1:${relay.port}/cdp?token=secret`, {
          Origin: 'https://evil.example',
        }),
      ).rejects.toThrow();
    } finally {
      await relay.stop();
    }
  });

  it('accepts only the bundled extension origin on the extension socket', async () => {
    const relay = await startRelayServer({ port: 0, token: 'secret' });
    try {
      const url = `ws://127.0.0.1:${relay.port}/ext?token=secret`;
      await expect(openSocket(url)).rejects.toThrow();
      await expect(openSocket(url, { Origin: 'chrome-extension://different' })).rejects.toThrow();
    } finally {
      await relay.stop();
    }
  });
});

function openSocket(url: string, headers?: Record<string, string>): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers });
    socket.once('open', () => resolve(socket));
    socket.once('error', reject);
  });
}

function tick(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 10));
}
