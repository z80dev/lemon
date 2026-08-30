import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';

import { WebSocket } from 'ws';
import { ChromeSession, startRelayServer } from '../dist/index.js';

const clientDir = path.resolve(import.meta.dirname, '..');
const extensionDir = path.join(clientDir, 'extension');
const extensionId = extensionIdFromManifest(path.join(extensionDir, 'manifest.json'));
const chromePath = findChrome();
const token = crypto.randomBytes(24).toString('hex');
const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), 'lemon-extension-smoke-'));
const relay = await startRelayServer({
  port: 0,
  token,
  log: process.env.LEMON_BROWSER_SMOKE_DEBUG === 'true'
    ? (message, data) => process.stderr.write(`[relay] ${message} ${JSON.stringify(data ?? {})}\n`)
    : undefined,
});
const proofServer = await startProofServer();
let chrome;
let relaySession;
let chromeLog = '';

try {
  const chromeArgs = [
      `--user-data-dir=${profileDir}`,
      '--remote-debugging-port=0',
      '--remote-debugging-address=127.0.0.1',
      `--disable-extensions-except=${extensionDir}`,
      `--load-extension=${extensionDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--window-size=1000,760',
      '--enable-logging=stderr',
      `chrome-extension://${extensionId}/options.html`,
      `${proofServer.url}/existing`,
    ];
  if (process.env.LEMON_BROWSER_SMOKE_HEADLESS === 'true') chromeArgs.push('--headless=new');

  chrome = spawn(
    chromePath,
    chromeArgs,
    { stdio: ['ignore', 'ignore', 'pipe'] },
  );
  chrome.stderr.on('data', (chunk) => {
    chromeLog = `${chromeLog}${chunk.toString()}`.slice(-12_000);
  });

  const bootstrapEndpoint = await waitForDevTools(profileDir);
  await waitForExtension(bootstrapEndpoint, extensionId);
  const existingTarget = await waitForTargetUrl(bootstrapEndpoint, `${proofServer.url}/existing`);
  const optionsTarget = await waitForTargetUrl(
    bootstrapEndpoint,
    `chrome-extension://${extensionId}/options.html`,
  );
  await setExtensionSettings(
    optionsTarget.webSocketDebuggerUrl,
    relay.port,
    token,
    [existingTarget.url],
  );
  await waitForRelay(relay.port, token);

  relaySession = new ChromeSession({
    cdpPort: relay.port,
    cdpEndpoint: `ws://127.0.0.1:${relay.port}/cdp?token=${token}`,
    userDataDir: profileDir,
    headless: true,
    noSandbox: false,
    attachOnly: true,
  });
  await smokeStep('connect relay session', relaySession.start());
  const before = await smokeStep('list tabs', relaySession.listTabs());
  const opened = await smokeStep('open tab', relaySession.openTab(
    `${proofServer.url}/proof`,
  ));
  const title = await smokeStep(
    'read title',
    relaySession.withPage((page) => page.title(), opened.targetId),
  );
  const button = await smokeStep('read button', relaySession.withPage(
    (page) => page.locator('#proof').textContent(),
    opened.targetId,
  ));
  await smokeStep('detach relay session', relaySession.stop());

  const bootstrapStillAlive = chrome.exitCode === null && await fetch(`${bootstrapEndpoint}/json/version`)
    .then((response) => response.ok)
    .catch(() => false);
  if (title !== 'Lemon Relay Proof' || button !== 'ready' || !bootstrapStillAlive) {
    throw new Error('extension relay smoke assertions failed');
  }

  process.stdout.write(
    `${JSON.stringify({
      ok: true,
      extensionId,
      relayPort: relay.port,
      tabsBefore: before.tabs.length,
      openedTargetId: opened.targetId,
      title,
      button,
      attachedBrowserPreserved: bootstrapStillAlive,
    })}\n`,
  );
} finally {
  await relaySession?.stop().catch(() => undefined);
  chrome?.kill('SIGTERM');
  await relay.stop().catch(() => undefined);
  await proofServer.stop().catch(() => undefined);
  try {
    fs.rmSync(profileDir, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  } catch {
    // The disposable Chrome process can hold profile files briefly on macOS;
    // cleanup failure must not hide the smoke assertion that triggered it.
  }
}

function findChrome() {
  const playwrightCache = path.join(os.homedir(), 'Library', 'Caches', 'ms-playwright');
  const testingChromes = fs.existsSync(playwrightCache)
    ? fs
        .readdirSync(playwrightCache)
        .filter((name) => name.startsWith('chromium-'))
        .sort()
        .reverse()
        .map((name) =>
          path.join(
            playwrightCache,
            name,
            'chrome-mac-arm64',
            'Google Chrome for Testing.app',
            'Contents',
            'MacOS',
            'Google Chrome for Testing',
          ),
        )
    : [];
  const candidates = [
    process.env.LEMON_BROWSER_EXECUTABLE,
    ...testingChromes,
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/usr/bin/google-chrome',
    '/usr/bin/chromium',
  ].filter(Boolean);
  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) throw new Error('Chrome executable not found');
  return found;
}

async function waitForDevTools(profile) {
  const activePort = path.join(profile, 'DevToolsActivePort');
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (fs.existsSync(activePort)) {
      const [port, browserPath] = fs.readFileSync(activePort, 'utf8').trim().split('\n');
      return `http://127.0.0.1:${port}${browserPath ? '' : ''}`;
    }
    await delay(100);
  }
  throw new Error('timed out waiting for Chrome DevToolsActivePort');
}

async function waitForExtension(endpoint, expectedId) {
  for (let attempt = 0; attempt < 150; attempt += 1) {
    const expectedUrl = `chrome-extension://${expectedId}/background.js`;
    const targets = await fetch(`${endpoint}/json/list`).then((response) => response.json()).catch(() => []);
    const worker = targets.find((target) => String(target.url ?? '') === expectedUrl);
    if (worker?.webSocketDebuggerUrl) return worker;
    await delay(100);
  }
  throw new Error(
    `timed out waiting for Lemon Browser Relay extension service worker\n${chromeLog}`,
  );
}

async function setExtensionSettings(webSocketDebuggerUrl, port, relayToken, allowedUrls) {
  const socket = new WebSocket(webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.once('open', resolve);
    socket.once('error', reject);
  });
  try {
    const id = 1;
    const result = new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('timed out setting extension relay settings')), 5_000);
      socket.on('message', (raw) => {
        const message = JSON.parse(raw.toString());
        if (message.id !== id) return;
        clearTimeout(timeout);
        if (message.error) reject(new Error(message.error.message));
        else if (message.result?.exceptionDetails) {
          const detail = message.result.exceptionDetails.exception?.description
            ?? message.result.exceptionDetails.text
            ?? 'unknown evaluation error';
          reject(new Error(`extension settings evaluation failed: ${detail}`));
        }
        else resolve(message.result);
      });
      socket.once('close', () => {
        clearTimeout(timeout);
        reject(new Error('extension service worker closed while saving settings'));
      });
    });
    const expression = `(async () => {
      const tabs = await chrome.tabs.query({});
      const allowed = ${JSON.stringify(allowedUrls)};
      const allowedTabIds = tabs
        .filter((tab) => allowed.includes(tab.url))
        .map((tab) => tab.id);
      await chrome.storage.local.set(${JSON.stringify({ port, token: relayToken })});
      await chrome.storage.local.set({ allowedTabIds });
      return allowedTabIds.length;
    })()`;
    socket.send(JSON.stringify({
      id,
      method: 'Runtime.evaluate',
      params: { expression, awaitPromise: true, returnByValue: true },
    }));
    const response = await result;
    if (response?.result?.value !== allowedUrls.length) {
      throw new Error('failed to persist extension relay settings');
    }
    await delay(100);
  } finally {
    socket.close();
  }
}

async function createNativeTab(endpoint, url) {
  const response = await fetch(`${endpoint}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' });
  if (!response.ok) throw new Error(`failed to create native smoke tab (${response.status})`);
  return response.json();
}

async function waitForTargetUrl(endpoint, expectedUrl) {
  for (let attempt = 0; attempt < 150; attempt += 1) {
    const targets = await fetch(`${endpoint}/json/list`)
      .then((response) => response.json())
      .catch(() => []);
    const target = targets.find((candidate) => candidate.url === expectedUrl);
    if (target?.webSocketDebuggerUrl) return target;
    await delay(100);
  }
  throw new Error(`timed out waiting for disposable Chrome target: ${new URL(expectedUrl).protocol}`);
}

async function startProofServer() {
  const server = http.createServer((request, response) => {
    const proof = request.url === '/proof';
    const body = proof
      ? '<!doctype html><title>Lemon Relay Proof</title><button id="proof">ready</button>'
      : '<!doctype html><title>Lemon Existing Tab</title><p id="existing">attached</p>';
    response.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    response.end(body);
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject);
      resolve();
    });
  });
  const address = server.address();
  if (!address || typeof address === 'string') throw new Error('proof server did not bind');
  return {
    url: `http://127.0.0.1:${address.port}`,
    stop: () => new Promise((resolve, reject) =>
      server.close((error) => error ? reject(error) : resolve()),
    ),
  };
}

function extensionIdFromManifest(manifestPath) {
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const digest = crypto
    .createHash('sha256')
    .update(Buffer.from(manifest.key, 'base64'))
    .digest()
    .subarray(0, 16);
  return [...digest]
    .flatMap((byte) => [byte >> 4, byte & 15])
    .map((nibble) => String.fromCharCode('a'.charCodeAt(0) + nibble))
    .join('');
}

async function waitForRelay(port, relayToken) {
  for (let attempt = 0; attempt < 150; attempt += 1) {
    const response = await fetch(`http://127.0.0.1:${port}/health?token=${relayToken}`);
    const body = await response.json();
    if (body.extensionConnected) return;
    await delay(100);
  }
  throw new Error('timed out waiting for extension to connect to relay');
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function smokeStep(label, promise, timeoutMs = 15_000) {
  if (process.env.LEMON_BROWSER_SMOKE_DEBUG === 'true') {
    process.stderr.write(`[smoke] ${label}\n`);
  }
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error(`smoke step timed out: ${label}`)), timeoutMs);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
