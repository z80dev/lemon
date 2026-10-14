// Worker-local passive inspection. Never start Chrome, create tabs, send CDP
// commands, or echo endpoints/credentials. Reuse the installed driver's own
// executable/discovery policy rather than a second Chrome path convention.
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import tls from 'node:tls';
import { createHash, randomBytes } from 'node:crypto';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

function webSocketReachable(endpoint) {
  return new Promise((resolve) => {
    let url;
    try { url = new URL(endpoint); } catch { resolve(false); return; }
    if (url.username || url.password) { resolve(false); return; }
    const nonce = randomBytes(16).toString('base64');
    const expected = createHash('sha1').update(nonce + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
    const secure = url.protocol === 'wss:';
    const hostname = url.hostname.replace(/^\[|\]$/g, '');
    let socket;
    let done = false;
    let chunks = [];
    let bytes = 0;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      socket?.destroy();
      resolve(value);
    };
    const timer = setTimeout(() => finish(false), 600);
    try {
      const options = { host: hostname, port: Number(url.port || (secure ? 443 : 80)) };
      socket = secure ? tls.connect({ ...options, servername: net.isIP(hostname) ? undefined : hostname }) : net.connect(options);
      socket.once(secure ? 'secureConnect' : 'connect', () => {
        socket.write(`GET ${url.pathname || '/'}${url.search} HTTP/1.1\r\nHost: ${url.host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${nonce}\r\nSec-WebSocket-Version: 13\r\n\r\n`);
      });
      socket.on('data', (chunk) => {
        bytes += chunk.length;
        if (bytes > 16384) { finish(false); return; }
        chunks.push(chunk);
        const response = Buffer.concat(chunks).toString('latin1');
        if (!response.includes('\r\n\r\n')) return;
        const accept = response.match(/^sec-websocket-accept:\s*(\S+)\s*$/im)?.[1];
        finish(/^HTTP\/1\.[01] 101\b/.test(response) && accept === expected);
      });
      socket.once('error', () => finish(false));
      socket.once('close', () => finish(false));
    } catch { finish(false); }
  });
}

async function httpReachable(endpoint, discoveryUrl) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 600);
  try {
    const response = await fetch(discoveryUrl(endpoint), { signal: controller.signal, redirect: 'error' });
    if (!response.ok || !response.body) return false;
    const reader = response.body.getReader();
    const chunks = [];
    let bytes = 0;
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        bytes += value.length;
        if (bytes > 65536) return false;
        chunks.push(value);
      }
    } finally { await reader.cancel(); }
    const result = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    return typeof result.Browser === 'string' && result.Browser.length > 0 &&
      typeof result.webSocketDebuggerUrl === 'string' && /^wss?:\/\//.test(result.webSocketDebuggerUrl);
  } catch { return false; }
  finally { clearTimeout(timer); }
}

async function inspect(config) {
  const modulePath = path.join(path.dirname(config.driverPath), 'chrome.js');
  const { defaultChromeExecutable, cdpDiscoveryUrl } = await import(pathToFileURL(modulePath).href);
  const executable = process.env.LEMON_BROWSER_EXECUTABLE?.trim() || defaultChromeExecutable();
  let installed = false;
  if (executable) {
    try { fs.accessSync(executable, fs.constants.X_OK); installed = fs.statSync(executable).isFile(); } catch { /* absent */ }
  }
  const endpoint = config.endpoint || `http://127.0.0.1:${config.port}`;
  const protocol = new URL(endpoint).protocol;
  const reachable = protocol === 'ws:' || protocol === 'wss:'
    ? await webSocketReachable(endpoint)
    : await httpReachable(endpoint, cdpDiscoveryUrl);
  const available = reachable || (config.launchesBrowser === true && installed);
  return { supported: reachable || installed || Boolean(config.endpoint), available, configured: available,
    running: reachable, reason: reachable ? 'browser_cdp_measured' : installed && config.launchesBrowser
      ? 'browser_executable_measured' : config.endpoint ? 'browser_cdp_unavailable' : 'browser_executable_not_installed' };
}

const input = createInterface({ input: process.stdin, terminal: false });
input.once('line', async (line) => {
  input.close();
  let result;
  try {
    if (Buffer.byteLength(line) > 65536) throw new Error();
    result = await inspect(JSON.parse(line));
  } catch {
    result = { error: 'inspection_unavailable' };
  }
  process.stdout.write(JSON.stringify(result) + '\n', () => process.exit(0));
});
