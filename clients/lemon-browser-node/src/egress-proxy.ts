import { lookup } from 'node:dns/promises';
import http from 'node:http';
import net from 'node:net';
import type { AddressInfo } from 'node:net';
import type { Duplex } from 'node:stream';

import { isBlockedAddress } from './destination-guard.js';

/**
 * Egress policy for the managed Chrome proxy. `resolve` and `isBlocked` are
 * injection seams for tests; production uses the system resolver and the
 * shared metadata/link-local classifier.
 */
export type EgressPolicy = {
  resolve?: (hostname: string) => Promise<string[]>;
  isBlocked?: (address: string) => boolean;
};

export type EgressProxy = {
  port: number;
  close(): Promise<void>;
};

const HOP_BY_HOP = [
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'proxy-connection',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
];

/**
 * Starts a loopback forward proxy that every request of a Lemon-launched Chrome
 * goes through. Each destination is resolved here, every answer is classified,
 * and the upstream socket connects to the checked IP, so redirects,
 * subresources, workers, popups, WebSockets and DNS rebinding cannot reach a
 * blocked address. TLS is tunnelled via CONNECT without interception.
 */
export async function startEgressProxy(policy: EgressPolicy = {}): Promise<EgressProxy> {
  const resolve =
    policy.resolve ??
    (async (hostname: string) =>
      (await lookup(hostname, { all: true, verbatim: true })).map((entry) => entry.address));
  const isBlocked = policy.isBlocked ?? isBlockedAddress;

  // Returns a checked IP to connect to, or null when the destination is refused.
  const checkedAddress = async (hostname: string): Promise<string | null> => {
    const host = hostname.replace(/^\[|\]$/g, '');
    let addresses: string[];
    if (net.isIP(host)) {
      addresses = [host];
    } else {
      try {
        addresses = await resolve(host);
      } catch {
        return null;
      }
    }
    if (addresses.length === 0 || addresses.some((address) => !net.isIP(address) || isBlocked(address))) {
      return null;
    }
    return addresses[0];
  };

  // WHATWG parsing canonicalizes numeric/hex/octal IPv4 hosts and IPv6 brackets.
  const parseAuthority = (authority: string, defaultPort: number): { hostname: string; port: number } | null => {
    try {
      const url = new URL(`http://${authority}`);
      return { hostname: url.hostname, port: url.port ? Number(url.port) : defaultPort };
    } catch {
      return null;
    }
  };

  const refuseSocket = (socket: Duplex) => {
    socket.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
  };

  const tunnel = async (authority: string, defaultPort: number, socket: Duplex, head: Buffer, preamble: string) => {
    socket.on('error', () => socket.destroy());
    const target = parseAuthority(authority, defaultPort);
    const address = target && (await checkedAddress(target.hostname));
    if (!target || !address) return refuseSocket(socket);

    const upstream = net.connect({ host: address, port: target.port });
    let connected = false;
    upstream.on('error', () => (connected ? socket.destroy() : refuseSocket(socket)));
    socket.on('close', () => upstream.destroy());
    upstream.on('connect', () => {
      connected = true;
      if (preamble === '') {
        socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      } else {
        upstream.write(preamble);
      }
      if (head.length > 0) upstream.write(head);
      upstream.pipe(socket);
      socket.pipe(upstream);
    });
  };

  const server = http.createServer(async (req, res) => {
    let url: URL;
    try {
      url = new URL(req.url ?? '');
    } catch {
      res.writeHead(400).end();
      return;
    }
    if (url.protocol !== 'http:') {
      res.writeHead(400).end();
      return;
    }
    const address = await checkedAddress(url.hostname);
    if (!address) {
      res.writeHead(403, { 'content-type': 'text/plain' }).end('blocked by lemon browser egress policy');
      return;
    }

    const headers = { ...req.headers };
    for (const name of HOP_BY_HOP) delete headers[name];
    const upstream = http.request(
      {
        host: address,
        port: url.port ? Number(url.port) : 80,
        method: req.method,
        path: `${url.pathname}${url.search}`,
        headers: { ...headers, host: url.host },
        setHost: false,
      },
      (upstreamRes) => {
        const responseHeaders = { ...upstreamRes.headers };
        for (const name of HOP_BY_HOP) delete responseHeaders[name];
        res.writeHead(upstreamRes.statusCode ?? 502, responseHeaders);
        upstreamRes.pipe(res);
      },
    );
    upstream.on('error', () => {
      if (!res.headersSent) res.writeHead(502);
      res.end();
    });
    req.pipe(upstream);
  });

  server.on('connect', (req, socket, head) => {
    void tunnel(req.url ?? '', 443, socket, head, '');
  });

  // Plain ws:// upgrades sent as absolute-form requests: replay the request line
  // and headers to the checked upstream, then splice the sockets.
  server.on('upgrade', (req, socket, head) => {
    let url: URL;
    try {
      url = new URL(req.url ?? '');
    } catch {
      refuseSocket(socket);
      return;
    }
    const lines = [`${req.method} ${url.pathname}${url.search} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      if (!req.rawHeaders[i].toLowerCase().startsWith('proxy-')) {
        lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
      }
    }
    void tunnel(url.host, 80, socket, head, `${lines.join('\r\n')}\r\n\r\n`);
  });

  server.on('clientError', (_err, socket) => socket.destroy());

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve());
  });

  return {
    port: (server.address() as AddressInfo).port,
    async close() {
      const closed = new Promise<void>((resolve) => server.close(() => resolve()));
      server.closeAllConnections();
      await closed;
    },
  };
}
