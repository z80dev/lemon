import { afterEach, describe, expect, it } from 'vitest';
import { WebSocketServer } from 'ws';
import { LemonSocket } from './lemon-socket.js';

const servers: WebSocketServer[] = [];

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          server.close(() => resolve());
        }),
    ),
  );
});

describe('LemonSocket', () => {
  it('times out unanswered calls', async () => {
    const server = new WebSocketServer({ port: 0 });
    servers.push(server);

    server.on('connection', (ws) => {
      ws.on('message', (raw) => {
        const msg = JSON.parse(String(raw));
        if (msg.method === 'connect') {
          ws.send(
            JSON.stringify({
              type: 'hello-ok',
              protocol: 1,
              server: {},
              features: {},
              snapshot: {},
              policy: {},
              auth: { role: 'node', scopes: [], clientId: 'node-1' },
            }),
          );
        }
      });
    });

    const address = server.address();
    if (!address || typeof address === 'string') throw new Error('expected local server address');

    const { socket } = await LemonSocket.connect(`ws://127.0.0.1:${address.port}/ws`);

    await expect(socket.call('node.invoke.result', { invokeId: 'missing' }, { timeoutMs: 5 })).rejects.toThrow(
      'request timeout after 5ms: node.invoke.result',
    );

    socket.close();
  });
});
