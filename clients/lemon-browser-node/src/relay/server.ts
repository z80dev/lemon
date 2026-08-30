import http, { type IncomingMessage, type ServerResponse } from 'node:http';
import crypto from 'node:crypto';

import { WebSocketServer, type WebSocket } from 'ws';

import { RelayBridge, type RelaySocket } from './bridge.js';

export type RelayServerOptions = {
  port: number;
  token: string;
  host?: string;
  log?: (message: string, data?: Record<string, unknown>) => void;
};

export type RelayServer = {
  bridge: RelayBridge;
  port: number;
  stop(): Promise<void>;
};

type SocketRole = 'extension' | 'cdp';
type TrackedSocket = WebSocket & { lemonRole?: SocketRole; lemonConnectionId?: number };

const MAX_PAYLOAD_BYTES = 64 * 1024 * 1024;
const EXTENSION_ORIGIN = 'chrome-extension://gjglijccjcaldhmkencnboofkfebhgog';

export async function startRelayServer(options: RelayServerOptions): Promise<RelayServer> {
  if (!options.token) throw new Error('browser relay token is required');
  const host = options.host ?? '127.0.0.1';
  if (!isLoopback(host)) throw new Error('browser relay must bind to a loopback address');

  const bridge = new RelayBridge(options.log);
  let boundPort = options.port;
  const server = http.createServer((request, response) =>
    handleHttp(request, response, bridge, options, boundPort),
  );
  const websocketServer = new WebSocketServer({ noServer: true, maxPayload: MAX_PAYLOAD_BYTES });

  server.on('upgrade', (request, socket, head) => {
    const url = requestUrl(request, host, options.port);
    const role = roleForPath(url.pathname);
    if (!role || !authorized(request, url, role, options.token)) {
      options.log?.('relay websocket rejected', {
        path: url.pathname,
        role: role ?? 'unknown',
        hasToken: url.searchParams.has('token') || Boolean(request.headers.authorization),
        origin: request.headers.origin ?? null,
      });
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    websocketServer.handleUpgrade(request, socket, head, (websocket) => {
      const tracked = websocket as TrackedSocket;
      tracked.lemonRole = role;
      websocketServer.emit('connection', tracked, request);
    });
  });

  websocketServer.on('connection', (socket: TrackedSocket) => {
    const relaySocket = socketAdapter(socket);
    if (socket.lemonRole === 'extension') {
      options.log?.('extension websocket connected');
      bridge.extensionConnected(relaySocket);
    } else {
      options.log?.('cdp websocket connected');
      socket.lemonConnectionId = bridge.cdpConnected(relaySocket);
    }

    socket.on('message', (data) => {
      const text = data.toString();
      if (socket.lemonRole === 'extension') bridge.extensionMessage(relaySocket, text);
      else if (socket.lemonConnectionId) bridge.cdpMessage(socket.lemonConnectionId, text);
    });

    socket.on('close', () => {
      if (socket.lemonRole === 'extension') bridge.extensionClosed(relaySocket);
      else if (socket.lemonConnectionId) bridge.cdpClosed(socket.lemonConnectionId);
    });
  });

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(options.port, host, () => {
      server.off('error', reject);
      resolve();
    });
  });

  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : options.port;
  boundPort = port;
  options.log?.('relay listening', { host, port });

  return {
    bridge,
    port,
    async stop() {
      for (const socket of websocketServer.clients) socket.close();
      websocketServer.close();
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      });
    },
  };
}

function handleHttp(
  request: IncomingMessage,
  response: ServerResponse,
  bridge: RelayBridge,
  options: RelayServerOptions,
  boundPort: number,
): void {
  const url = requestUrl(request, options.host ?? '127.0.0.1', boundPort);
  if (request.method !== 'GET') return sendJson(response, 405, { error: 'method not allowed' });
  if (!tokenMatches(request, url, options.token)) {
    return sendJson(response, 401, { error: 'unauthorized' });
  }

  if (url.pathname === '/json/version') {
    if (!bridge.ready) return sendJson(response, 503, { error: 'relay extension is not connected' });
    const wsUrl = `ws://${options.host ?? '127.0.0.1'}:${boundPort}/cdp?token=${encodeURIComponent(options.token)}`;
    return sendJson(response, 200, bridge.versionInfo(wsUrl));
  }
  if (url.pathname === '/json' || url.pathname === '/json/list') {
    return sendJson(response, 200, bridge.listTargets());
  }
  if (url.pathname === '/health') {
    return sendJson(response, 200, { ok: true, extensionConnected: bridge.ready });
  }
  return sendJson(response, 404, { error: 'not found' });
}

function authorized(
  request: IncomingMessage,
  url: URL,
  role: SocketRole,
  token: string,
): boolean {
  const origin = request.headers.origin;
  if (role === 'extension' && origin !== EXTENSION_ORIGIN) return false;
  if (role === 'cdp' && origin) return false;
  return tokenMatches(request, url, token);
}

function tokenMatches(request: IncomingMessage, url: URL, token: string): boolean {
  const supplied = url.searchParams.get('token') ?? bearerToken(request.headers.authorization);
  return supplied ? timingSafeEqual(supplied, token) : false;
}

function timingSafeEqual(left: string, right: string): boolean {
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  if (leftBytes.length !== rightBytes.length) return false;
  return crypto.timingSafeEqual(leftBytes, rightBytes);
}

function bearerToken(value: string | undefined): string | null {
  const match = value?.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}

function requestUrl(request: IncomingMessage, host: string, port: number): URL {
  return new URL(request.url ?? '/', `http://${host}:${port}`);
}

function roleForPath(pathname: string): SocketRole | null {
  if (pathname === '/ext') return 'extension';
  if (pathname === '/cdp') return 'cdp';
  return null;
}

function socketAdapter(socket: WebSocket): RelaySocket {
  return {
    send: (text) => socket.send(text),
    close: () => socket.close(),
  };
}

function sendJson(response: ServerResponse, status: number, body: unknown): void {
  const encoded = JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json',
    'content-length': Buffer.byteLength(encoded),
    'cache-control': 'no-store',
  });
  response.end(encoded);
}

function isLoopback(host: string): boolean {
  return host === '127.0.0.1' || host === '::1' || host === 'localhost';
}
