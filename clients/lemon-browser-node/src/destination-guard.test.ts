import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import net, { type AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import { WebSocketServer } from 'ws';

import { ChromeSession } from './chrome.js';
import { blockedDestination, isBlockedAddress } from './destination-guard.js';
import { dispatchBrowserRequest } from './driver-dispatch.js';

const publicResolver = async () => ['93.184.215.14'];

describe('blockedDestination', () => {
  it.each([
    'http://169.254.169.254/latest/meta-data',
    'http://2852039166/',
    'http://0xa9fea9fe/',
    'http://0251.0376.0251.0376/',
    'http://[::ffff:169.254.169.254]/',
    'http://169.254.169.254./',
    'http://metadata.google.internal./',
    'http://[fd00:ec2::254]/',
    'http://[fe80::1]/',
  ])('blocks %s', async (url) => {
    expect(await blockedDestination(url, publicResolver)).toMatch(/metadata endpoint/);
  });

  it('blocks hostnames whose DNS answers include a metadata address', async () => {
    const resolver = async () => ['93.184.215.14', '::ffff:169.254.169.254'];
    expect(await blockedDestination('http://rebind.example/', resolver)).toMatch(/metadata endpoint/);
  });

  it('fails closed when resolution fails', async () => {
    const resolver = async () => {
      throw new Error('ENOTFOUND');
    };
    expect(await blockedDestination('http://nowhere.example/', resolver)).toMatch(/could not resolve/);
  });

  it('allows public, private and local-document destinations', async () => {
    expect(await blockedDestination('https://example.com/', publicResolver)).toBeNull();
    expect(await blockedDestination('http://127.0.0.1:4000/', publicResolver)).toBeNull();
    expect(await blockedDestination('data:text/plain,hi', publicResolver)).toBeNull();
    expect(isBlockedAddress('10.0.0.1')).toBe(false);
  });
});

const chromePath = [
  process.env.LEMON_BROWSER_TEST_CHROME,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
].find((candidate): candidate is string => !!candidate && fs.existsSync(candidate));

// Real Chrome + real sockets: proving that no request arrives has no event to
// await, so give the browser a bounded window to (fail to) reach the fixture.
const settle = (ms = 1500) => new Promise((resolve) => setTimeout(resolve, ms));

async function freePort(): Promise<number> {
  const server = net.createServer();
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  await new Promise((resolve) => server.close(resolve));
  return port;
}

// The forbidden destination is a fixture on [::1]:PORT standing in for cloud
// metadata (the test egress policy classifies ::1 as blocked). The allowed
// fixture listens on 127.0.0.1 with the same port, so a DNS answer switch from
// 127.0.0.1 to ::1 is a real rebinding attack against the same URL.
describe.skipIf(!chromePath)('managed Chrome egress proxy', () => {
  let port = 0;
  let allowed: http.Server;
  let forbidden: http.Server;
  let forbiddenHits = 0;
  // Allowed TLS fixture on 127.0.0.1:TLSPORT with a throwaway self-signed cert.
  // Chrome rejects the cert; the assertion is that the CONNECT tunnel reached it.
  let tlsAllowed: tls.Server;
  let tlsPort = 0;
  let tlsConnections = 0;
  let allowedSockets: WebSocketServer;
  let allowedWebSockets = 0;
  const allowedHosts: string[] = [];
  let rebindLookups = 0;
  let session: ChromeSession;
  let userDataDir: string;

  const done = `.finally(() => document.title = 'done')`;
  const pages: Record<string, string> = {
    '/fetch': `<script>fetch('http://[::1]:PORT/secret', {mode: 'no-cors'})${done}</script>`,
    '/iframe': `<iframe src="http://[::1]:PORT/secret"></iframe>`,
    '/rebind': `<script>fetch('http://rebind.test:PORT/first', {mode: 'no-cors'})
      .then(() => fetch('http://rebind.test:PORT/second', {mode: 'no-cors'}))${done}</script>`,
    '/https': `<script>Promise.allSettled([
      fetch('https://127.0.0.1:TLSPORT/', {mode: 'no-cors'}),
      fetch('https://[::1]:PORT/secret', {mode: 'no-cors'}),
    ])${done}</script>`,
    '/ws': `<script>
      const open = (url) => new Promise((resolve) => {
        const socket = new WebSocket(url);
        socket.onopen = () => resolve('open');
        socket.onerror = () => resolve('error');
      });
      Promise.all([open('ws://127.0.0.1:PORT/'), open('ws://[::1]:PORT/'),
                   open('wss://127.0.0.1:TLSPORT/'), open('wss://[::1]:PORT/')])
        .then((states) => document.title = 'done:' + states.join(','));
    </script>`,
    '/sw': `<script>
      navigator.serviceWorker.register('/sw.js')
        .then(() => navigator.serviceWorker.ready)
        .then((registration) => new Promise((resolve) => {
          navigator.serviceWorker.onmessage = resolve;
          registration.active.postMessage('go');
        }))${done};
    </script>`,
    '/sw.js': `self.addEventListener('message', (event) => {
      Promise.allSettled([
        fetch('http://127.0.0.1:PORT/from-sw', {mode: 'no-cors'}),
        fetch('http://[::1]:PORT/secret', {mode: 'no-cors'}),
      ]).then(() => event.source.postMessage('done'));
    });`,
  };

  beforeAll(async () => {
    allowed = http.createServer((req, res) => {
      allowedHosts.push(`${req.headers.host}${req.url}`);
      if (req.url === '/redirect') {
        res.writeHead(302, { location: `http://[::1]:${port}/secret` }).end();
        return;
      }
      res.writeHead(200, { 'content-type': req.url === '/sw.js' ? 'text/javascript' : 'text/html' });
      res.end(
        (pages[req.url ?? ''] ?? '<title>ok</title>')
          .replaceAll('TLSPORT', String(tlsPort))
          .replaceAll('PORT', String(port)),
      );
    });
    await new Promise<void>((resolve) => allowed.listen(0, '127.0.0.1', resolve));
    port = (allowed.address() as AddressInfo).port;
    allowedSockets = new WebSocketServer({ server: allowed });
    allowedSockets.on('connection', () => allowedWebSockets++);

    const certDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-egress-tls-'));
    execFileSync('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=127.0.0.1',
      '-keyout', path.join(certDir, 'key.pem'), '-out', path.join(certDir, 'cert.pem'),
    ], { stdio: 'ignore' });
    tlsAllowed = tls.createServer({
      key: fs.readFileSync(path.join(certDir, 'key.pem')),
      cert: fs.readFileSync(path.join(certDir, 'cert.pem')),
    });
    fs.rmSync(certDir, { recursive: true, force: true });
    tlsAllowed.on('connection', () => tlsConnections++);
    tlsAllowed.on('tlsClientError', () => undefined);
    await new Promise<void>((resolve) => tlsAllowed.listen(0, '127.0.0.1', resolve));
    tlsPort = (tlsAllowed.address() as AddressInfo).port;

    // Count every request as well as every new socket: keep-alive sockets opened
    // by an earlier test would otherwise hide later requests.
    forbidden = http.createServer((_req, res) => {
      forbiddenHits++;
      res.end('INSTANCE-CREDENTIALS');
    });
    forbidden.on('connection', () => forbiddenHits++);
    await new Promise<void>((resolve) => forbidden.listen({ port, host: '::1', ipv6Only: true }, resolve));

    userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-egress-'));
    session = new ChromeSession({
      cdpPort: await freePort(),
      userDataDir,
      executablePath: chromePath,
      headless: true,
      noSandbox: false,
      attachOnly: false,
      egressPolicy: {
        resolve: async (host) => {
          if (host === 'allowed.test') return ['127.0.0.1'];
          if (host === 'rebind.test') return rebindLookups++ === 0 ? ['127.0.0.1'] : ['::1'];
          throw new Error(`ENOTFOUND ${host}`);
        },
        isBlocked: (address) => address === '::1' || isBlockedAddress(address),
      },
    });
    await session.start();
  }, 60_000);

  afterAll(async () => {
    await session?.stop();
    allowedSockets?.close();
    await new Promise((resolve) => allowed?.close(resolve));
    await new Promise((resolve) => forbidden?.close(resolve));
    await new Promise((resolve) => tlsAllowed?.close(resolve));
    // Chrome may still flush profile files right after SIGTERM.
    if (userDataDir) fs.rmSync(userDataDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
  });

  beforeEach(() => {
    forbiddenHits = 0;
    tlsConnections = 0;
    allowedWebSockets = 0;
  });

  const waitForDone = () =>
    session.withPage((page) => page.waitForFunction(`document.title.startsWith('done')`, null, { timeout: 15_000 }));

  it('tunnels allowed HTTPS via CONNECT and refuses the forbidden destination', async () => {
    await navigate('/https');
    await waitForDone();
    await settle(500);
    expect(tlsConnections).toBeGreaterThan(0);
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it('allows ws:// and wss:// to allowed hosts and refuses the forbidden destination', async () => {
    await navigate('/ws');
    await waitForDone();
    const title = await session.withPage((page) => page.title());
    // Order: ws allowed, ws forbidden, wss allowed (self-signed cert), wss forbidden.
    expect(title.split(':')[1].split(',').slice(0, 2)).toEqual(['open', 'error']);
    await settle(500);
    expect(allowedWebSockets).toBeGreaterThan(0);
    expect(tlsConnections).toBeGreaterThan(0);
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it('filters service-worker fetches', async () => {
    await navigate('/sw');
    await waitForDone();
    await settle(500);
    expect(allowedHosts).toContain(`127.0.0.1:${port}/from-sw`);
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  const navigate = (pathname: string) =>
    dispatchBrowserRequest(session, 'browser.navigate', { url: `http://127.0.0.1:${port}${pathname}` });

  it('routes browser traffic through the proxy resolver', async () => {
    // allowed.test exists only in the proxy's resolver, so loading it proves egress goes through the proxy.
    const status = await session.withPage(async (page) => (await page.goto(`http://allowed.test:${port}/`))?.status());
    expect(status).toBe(200);
    expect(allowedHosts).toContain(`allowed.test:${port}/`);
  }, 30_000);

  it('blocks a redirect hop to the forbidden destination before it is sent', async () => {
    await navigate('/redirect').catch(() => undefined);
    await settle();
    expect(allowedHosts).toContain(`127.0.0.1:${port}/redirect`);
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it('blocks fetch from page JavaScript', async () => {
    await navigate('/fetch');
    await settle();
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it('blocks iframes', async () => {
    await navigate('/iframe');
    await settle();
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it('blocks window.open popups', async () => {
    await navigate('/');
    const url = `http://[::1]:${port}/secret`;
    await session.withPage((page) => page.evaluate(`void window.open(${JSON.stringify(url)})`));
    await settle();
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it.each(['/secret-direct', '/redirect'])('blocks tabOpen to the forbidden destination (%s)', async (pathname) => {
    const url =
      pathname === '/redirect' ? `http://127.0.0.1:${port}/redirect` : `http://[::1]:${port}/secret`;
    await dispatchBrowserRequest(session, 'tabOpen', { url }).catch(() => undefined);
    await settle();
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it('binds the check to the connection when DNS rebinds', async () => {
    await navigate('/rebind');
    await settle();
    expect(rebindLookups).toBeGreaterThanOrEqual(2);
    expect(allowedHosts).toContain(`rebind.test:${port}/first`);
    expect(allowedHosts).not.toContain(`rebind.test:${port}/second`);
    expect(forbiddenHits).toBe(0);
  }, 30_000);

  it('refuses raw CDP Page.navigate', async () => {
    await expect(
      dispatchBrowserRequest(session, 'browser.cdp', { method: 'Page.navigate', params: { url: `http://[::1]:${port}/` } }),
    ).rejects.toThrow('CDP method Page.navigate is not allowed');
    await settle(500);
    expect(forbiddenHits).toBe(0);
  }, 30_000);
});
