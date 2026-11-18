import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';
import http from 'node:http';
import net, { type AddressInfo } from 'node:net';

import { startEgressProxy, type EgressProxy } from './egress-proxy.js';

// Every upstream connection the proxy opens to a non-loopback address is
// recorded and redirected to a local "forbidden" fixture, so a destination the
// proxy wrongly accepts shows up as a recorded target and a fixture hit rather
// than as an unreachable-network error indistinguishable from a refusal.
const LOOPBACK = '127.0.0.1';
const METADATA_TARGETS = [
  '[2002:a9fe:a9fe::]',
  '[::ffff:169.254.169.254]',
  '2852039166',
  '0xA9FEA9FE',
  '[64:ff9b::a9fe:a9fe]',
];

describe('egress proxy destination policy', () => {
  let proxy: EgressProxy;
  let origin: http.Server;
  let originPort = 0;
  let forbidden: net.Server;
  let forbiddenPort = 0;
  let forbiddenHits = 0;
  let upstreamTargets: string[] = [];

  beforeAll(async () => {
    forbidden = net.createServer((socket) => {
      forbiddenHits++;
      socket.on('error', () => undefined);
      socket.end('HTTP/1.1 200 OK\r\nContent-Length: 20\r\nConnection: close\r\n\r\nINSTANCE-CREDENTIALS');
    });
    await new Promise<void>((resolve) => forbidden.listen(0, LOOPBACK, resolve));
    forbiddenPort = (forbidden.address() as AddressInfo).port;

    origin = http.createServer((req, res) => {
      if (req.url === '/redirect') {
        res.writeHead(302, { location: 'http://[2002:a9fe:a9fe::]/latest/meta-data' }).end();
      } else if (req.url === '/page') {
        res.writeHead(200, { 'content-type': 'text/html' });
        res.end('<img src="http://[2002:a9fe:a9fe::]/latest/meta-data/iam">');
      } else {
        res.writeHead(200).end('ok');
      }
    });
    await new Promise<void>((resolve) => origin.listen(0, LOOPBACK, resolve));
    originPort = (origin.address() as AddressInfo).port;

    proxy = await startEgressProxy({
      resolve: async (host) => {
        if (host === 'sixtofour.test') return ['93.184.215.14', '2002:a9fe:a9fe::'];
        throw new Error(`ENOTFOUND ${host}`);
      },
    });
  });

  afterAll(async () => {
    await proxy?.close();
    await new Promise((resolve) => origin?.close(resolve));
    await new Promise((resolve) => forbidden?.close(resolve));
  });

  beforeEach(() => {
    forbiddenHits = 0;
    upstreamTargets = [];
    const connect = net.connect.bind(net) as (options: net.NetConnectOpts) => net.Socket;
    const request = http.request.bind(http) as (
      options: http.RequestOptions,
      callback?: (res: http.IncomingMessage) => void,
    ) => http.ClientRequest;
    vi.spyOn(net, 'connect').mockImplementation(((options: net.TcpNetConnectOpts) => {
      if (options.host === LOOPBACK) return connect(options);
      upstreamTargets.push(String(options.host));
      return connect({ host: LOOPBACK, port: forbiddenPort });
    }) as typeof net.connect);
    vi.spyOn(http, 'request').mockImplementation(((
      options: http.RequestOptions,
      callback?: (res: http.IncomingMessage) => void,
    ) => {
      if (options.host === LOOPBACK) return request(options, callback);
      upstreamTargets.push(String(options.host));
      return request({ ...options, host: LOOPBACK, port: forbiddenPort }, callback);
    }) as typeof http.request);
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // Absolute-URI request through the proxy, as a browser sends plain http://.
  const proxiedGet = (url: string) =>
    new Promise<{ status: number; headers: http.IncomingHttpHeaders; body: string }>((resolve, reject) => {
      const req = http.request(
        { host: LOOPBACK, port: proxy.port, method: 'GET', path: url, headers: { host: new URL(url).host } },
        (res) => {
          let body = '';
          res.setEncoding('utf8');
          res.on('data', (chunk: string) => (body += chunk));
          res.on('end', () => resolve({ status: res.statusCode ?? 0, headers: res.headers, body }));
        },
      );
      req.on('error', reject);
      req.end();
    });

  // CONNECT tunnel request; resolves with the proxy's status line.
  const proxiedConnect = (authority: string) =>
    new Promise<string>((resolve, reject) => {
      const socket = net.connect({ host: LOOPBACK, port: proxy.port });
      let received = '';
      socket.on('error', reject);
      socket.on('connect', () => socket.write(`CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n\r\n`));
      socket.on('data', (chunk) => {
        received += chunk.toString('latin1');
        const end = received.indexOf('\r\n');
        if (end >= 0) {
          socket.destroy();
          resolve(received.slice(0, end));
        }
      });
      socket.on('close', () => resolve(received.split('\r\n')[0]));
    });

  it.each(METADATA_TARGETS)('refuses CONNECT to %s', async (host) => {
    expect(await proxiedConnect(`${host}:443`)).toBe('HTTP/1.1 403 Forbidden');
    expect(upstreamTargets).toEqual([]);
    expect(forbiddenHits).toBe(0);
  });

  it.each(METADATA_TARGETS)('refuses absolute-URI requests to %s', async (host) => {
    const response = await proxiedGet(`http://${host}/latest/meta-data`);
    expect(response.status).toBe(403);
    expect(response.body).not.toContain('INSTANCE-CREDENTIALS');
    expect(upstreamTargets).toEqual([]);
    expect(forbiddenHits).toBe(0);
  });

  it('refuses ws:// upgrades to a 6to4 metadata host', async () => {
    const status = await new Promise<number>((resolve, reject) => {
      const req = http.request({
        host: LOOPBACK,
        port: proxy.port,
        path: 'http://[2002:a9fe:a9fe::]/',
        headers: { host: '[2002:a9fe:a9fe::]', connection: 'Upgrade', upgrade: 'websocket' },
      });
      req.on('response', (res) => resolve(res.statusCode ?? 0));
      req.on('upgrade', (res) => resolve(res.statusCode ?? 0));
      req.on('error', reject);
      req.end();
    });
    expect(status).toBe(403);
    expect(upstreamTargets).toEqual([]);
    expect(forbiddenHits).toBe(0);
  });

  it('refuses the redirect hop from an allowed origin to a 6to4 metadata host', async () => {
    const first = await proxiedGet(`http://${LOOPBACK}:${originPort}/redirect`);
    expect(first.status).toBe(302);
    const location = String(first.headers.location);
    expect(location).toBe('http://[2002:a9fe:a9fe::]/latest/meta-data');

    const hop = await proxiedGet(location);
    expect(hop.status).toBe(403);
    expect(upstreamTargets).toEqual([]);
    expect(forbiddenHits).toBe(0);
  });

  it('refuses a page subresource on a 6to4 metadata host', async () => {
    const page = await proxiedGet(`http://${LOOPBACK}:${originPort}/page`);
    expect(page.status).toBe(200);
    const src = /src="([^"]+)"/.exec(page.body)?.[1] ?? '';
    expect(src).toBe('http://[2002:a9fe:a9fe::]/latest/meta-data/iam');

    const subresource = await proxiedGet(src);
    expect(subresource.status).toBe(403);
    expect(upstreamTargets).toEqual([]);
    expect(forbiddenHits).toBe(0);
  });

  it('refuses a hostname when any DNS answer is a 6to4 metadata address', async () => {
    expect((await proxiedGet('http://sixtofour.test/')).status).toBe(403);
    expect(await proxiedConnect('sixtofour.test:443')).toBe('HTTP/1.1 403 Forbidden');
    expect(upstreamTargets).toEqual([]);
    expect(forbiddenHits).toBe(0);
  });

  it('fails closed when DNS resolution fails', async () => {
    expect((await proxiedGet('http://nowhere.test/')).status).toBe(403);
    expect(await proxiedConnect('nowhere.test:443')).toBe('HTTP/1.1 403 Forbidden');
    expect(upstreamTargets).toEqual([]);
  });

  it('keeps private and localhost destinations reachable', async () => {
    expect((await proxiedGet(`http://${LOOPBACK}:${originPort}/`)).body).toBe('ok');
    expect((await proxiedGet(`http://localhost:${originPort}/`)).body).toBe('ok');
    expect(await proxiedConnect(`${LOOPBACK}:${originPort}`)).toBe('HTTP/1.1 200 Connection Established');
    expect(upstreamTargets).toEqual([]);
  });
});
