import { spawn, type ChildProcess } from 'node:child_process';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket } from 'ws';
import {
  JsonLineDecoder,
  encodeJsonLine,
  type ClientCommand,
  type WireServerMessage,
  type BridgeErrorMessage,
  type BridgeStatusMessage,
  type BridgeStderrMessage,
} from '@lemon-web/shared';
import { loadDotenvFromDir } from './dotenv.js';

interface BridgeOptions {
  cwd?: string;
  model?: string;
  baseUrl?: string;
  systemPrompt?: string;
  sessionFile?: string;
  debug?: boolean;
  ui?: boolean;
  lemonPath?: string;
  port?: number;
  staticDir?: string;
}

const DEFAULT_PORT = 3939;

class RpcBridge {
  private proc: ChildProcess | null = null;
  private decoder: JsonLineDecoder | null = null;
  private stopping = false;
  private restartCount = 0;

  constructor(private readonly opts: BridgeOptions) {}

  start(onMessage: (message: WireServerMessage) => void): void {
    if (this.proc) {
      return;
    }

    this.stopping = false;

    const lemonPath =
      this.opts.lemonPath || process.env.LEMON_PATH || findLemonPath();

    if (!lemonPath) {
      const error: BridgeErrorMessage = {
        type: 'bridge_error',
        message: 'Could not find lemon project root. Set LEMON_PATH or --lemon-path.',
      };
      onMessage(withServerTime(error));
      return;
    }

    const args = buildRpcArgs(this.opts);
    const status: BridgeStatusMessage = {
      type: 'bridge_status',
      state: 'starting',
      message: 'Starting debug_agent_rpc...',
      pid: null,
    };
    onMessage(withServerTime(status));

    this.proc = spawn('mix', args, {
      cwd: lemonPath,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: {
        ...process.env,
        MIX_ENV: 'dev',
      },
    });

    this.decoder = new JsonLineDecoder({
      onMessage: (value) => {
        if ((value as WireServerMessage).type === 'ready') {
          this.restartCount = 0;
        }
        onMessage(withServerTime(value as WireServerMessage));
      },
      onError: (error, rawLine) => {
        const message: BridgeErrorMessage = {
          type: 'bridge_error',
          message: `Invalid JSON from RPC: ${error.message}`,
          detail: rawLine,
        };
        onMessage(withServerTime(message));
      },
    });

    this.proc.stdout?.on('data', (chunk) => {
      this.decoder?.write(chunk);
    });

    this.proc.stdout?.on('close', () => {
      this.decoder?.flush();
    });

    this.proc.stderr?.on('data', (chunk) => {
      if (!this.opts.debug) {
        return;
      }
      const message: BridgeStderrMessage = {
        type: 'bridge_stderr',
        message: chunk.toString(),
      };
      onMessage(withServerTime(message));
    });

    this.proc.on('error', (err) => {
      const message: BridgeErrorMessage = {
        type: 'bridge_error',
        message: `RPC process error: ${err.message}`,
        detail: err,
      };
      onMessage(withServerTime(message));
    });

    this.proc.on('close', (code, signal) => {
      const statusMessage: BridgeStatusMessage = {
        type: 'bridge_status',
        state: 'stopped',
        message: `RPC exited (code=${code ?? 'null'}, signal=${signal ?? 'null'})`,
        pid: this.proc?.pid ?? null,
      };
      onMessage(withServerTime(statusMessage));
      this.proc = null;
      this.decoder = null;
      if (!this.stopping) {
        const delay = Math.min(10000, 500 * Math.pow(2, this.restartCount));
        this.restartCount += 1;
        setTimeout(() => {
          this.start(onMessage);
        }, delay);
      }
    });

    const running: BridgeStatusMessage = {
      type: 'bridge_status',
      state: 'running',
      message: 'RPC running',
      pid: this.proc.pid ?? null,
    };
    onMessage(withServerTime(running));
  }

  send(command: ClientCommand): void {
    if (!this.proc?.stdin?.writable) {
      return;
    }
    this.proc.stdin.write(encodeJsonLine(command));
  }

  stop(): void {
    if (!this.proc) {
      return;
    }
    this.stopping = true;
    try {
      this.send({ type: 'quit' });
    } catch {
      // ignore
    }
    setTimeout(() => {
      if (this.proc && !this.proc.killed) {
        this.proc.kill('SIGTERM');
      }
    }, 1000);
  }
}

function buildRpcArgs(opts: BridgeOptions): string[] {
  const args = ['run', 'scripts/debug_agent_rpc.exs', '--'];

  if (opts.cwd) {
    args.push('--cwd', opts.cwd);
  }
  if (opts.model) {
    args.push('--model', opts.model);
  }
  if (opts.baseUrl) {
    args.push('--base_url', opts.baseUrl);
  }
  if (opts.systemPrompt) {
    args.push('--system_prompt', opts.systemPrompt);
  }
  if (opts.sessionFile) {
    args.push('--session-file', opts.sessionFile);
  }
  if (opts.debug) {
    args.push('--debug');
  }
  if (opts.ui === false) {
    args.push('--no-ui');
  }

  return args;
}

function parseArgs(argv: string[]): BridgeOptions {
  const opts: BridgeOptions = {};
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    switch (arg) {
      case '--cwd':
        opts.cwd = next;
        i += 1;
        break;
      case '--model':
        opts.model = next;
        i += 1;
        break;
      case '--base_url':
      case '--base-url':
        opts.baseUrl = next;
        i += 1;
        break;
      case '--system-prompt':
      case '--system_prompt':
        opts.systemPrompt = next;
        i += 1;
        break;
      case '--session-file':
      case '--session_file':
        opts.sessionFile = next;
        i += 1;
        break;
      case '--debug':
        opts.debug = true;
        break;
      case '--no-ui':
        opts.ui = false;
        break;
      case '--lemon-path':
        opts.lemonPath = next;
        i += 1;
        break;
      case '--port':
        opts.port = Number(next);
        i += 1;
        break;
      case '--static-dir':
        opts.staticDir = next;
        i += 1;
        break;
      default:
        break;
    }
  }
  return opts;
}

function withServerTime<T extends object>(message: T): T & { server_time: number } {
  return { ...message, server_time: Date.now() };
}

function findLemonPath(): string | null {
  const cwd = process.cwd();
  if (cwd.includes('lemon')) {
    let current = cwd;
    while (current !== '/') {
      if (fs.existsSync(path.join(current, 'mix.exs')) && fs.existsSync(path.join(current, 'apps'))) {
        return current;
      }
      current = path.dirname(current);
    }
  }

  const home = process.env.HOME || '';
  const commonPaths = [
    '/home/z80/dev/lemon',
    path.join(home, 'dev', 'lemon'),
    path.join(home, 'projects', 'lemon'),
  ];

  for (const candidate of commonPaths) {
    if (fs.existsSync(path.join(candidate, 'mix.exs'))) {
      return candidate;
    }
  }

  return null;
}

function resolveStaticDir(custom?: string): string | null {
  if (custom) {
    return custom;
  }
  const currentDir = path.dirname(fileURLToPath(import.meta.url));
  const distPath = path.resolve(currentDir, '..', '..', 'web', 'dist');
  if (fs.existsSync(distPath)) {
    return distPath;
  }
  return null;
}

function serveStatic(distDir: string, req: http.IncomingMessage, res: http.ServerResponse): void {
  const url = new URL(req.url || '/', 'http://localhost');
  let pathname = decodeURIComponent(url.pathname);
  if (pathname === '/') {
    pathname = '/index.html';
  }

  const filePath = path.join(distDir, pathname);
  if (!filePath.startsWith(distDir)) {
    res.writeHead(403);
    res.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (err, data) => {
    if (err) {
      const fallback = path.join(distDir, 'index.html');
      if (err.code === 'ENOENT' && !path.extname(filePath)) {
        fs.readFile(fallback, (fallbackErr, fallbackData) => {
          if (fallbackErr) {
            res.writeHead(404);
            res.end('Not Found');
            return;
          }
          res.setHeader('Content-Type', 'text/html');
          res.writeHead(200);
          res.end(fallbackData);
        });
        return;
      }
      res.writeHead(404);
      res.end('Not Found');
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = contentTypeFor(ext);
    if (contentType) {
      res.setHeader('Content-Type', contentType);
    }
    res.writeHead(200);
    res.end(data);
  });
}

function contentTypeFor(ext: string): string | null {
  switch (ext) {
    case '.html':
      return 'text/html';
    case '.js':
      return 'text/javascript';
    case '.css':
      return 'text/css';
    case '.svg':
      return 'image/svg+xml';
    case '.json':
      return 'application/json';
    case '.png':
      return 'image/png';
    case '.jpg':
    case '.jpeg':
      return 'image/jpeg';
    case '.woff':
      return 'font/woff';
    case '.woff2':
      return 'font/woff2';
    default:
      return null;
  }
}

const opts = parseArgs(process.argv);
loadDotenvFromDir(opts.cwd || process.cwd());
const port = Number.isFinite(opts.port) ? (opts.port as number) : DEFAULT_PORT;
const staticDir = resolveStaticDir(opts.staticDir);

const server = http.createServer((req, res) => {
  if (staticDir) {
    serveStatic(staticDir, req, res);
    return;
  }
  res.writeHead(200);
  res.end('Lemon Web bridge is running.');
});

const wss = new WebSocketServer({ server, path: '/ws' });
const clients = new Set<WebSocket>();
let lastBridgeStatus: WireServerMessage | null = null;

const bridge = new RpcBridge(opts);
bridge.start((message) => {
  if (message.type === 'bridge_status') {
    lastBridgeStatus = message;
  }
  broadcast(message);
});

wss.on('connection', (ws) => {
  clients.add(ws);

  if (lastBridgeStatus) {
    ws.send(JSON.stringify(lastBridgeStatus));
  }

  ws.on('message', (data) => {
    const text = data.toString();
    let parsed: ClientCommand;
    try {
      parsed = JSON.parse(text) as ClientCommand;
    } catch (err) {
      const error: BridgeErrorMessage = {
        type: 'bridge_error',
        message: 'Invalid JSON from client',
        detail: text,
      };
      ws.send(JSON.stringify(withServerTime(error)));
      return;
    }

    bridge.send(parsed);
  });

  ws.on('close', () => {
    clients.delete(ws);
  });
});

function broadcast(message: WireServerMessage): void {
  const payload = JSON.stringify(message);
  for (const client of clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(payload);
    }
  }
}

server.listen(port, () => {
  const status: BridgeStatusMessage = {
    type: 'bridge_status',
    state: 'running',
    message: `Bridge listening on http://localhost:${port}`,
    pid: process.pid,
  };
  const enriched = withServerTime(status);
  lastBridgeStatus = enriched;
  broadcast(enriched);
});

process.on('SIGINT', () => {
  bridge.stop();
  process.exit(0);
});

process.on('SIGTERM', () => {
  bridge.stop();
  process.exit(0);
});
