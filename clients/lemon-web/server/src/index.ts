import { spawn, type ChildProcess } from 'node:child_process';
import { timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { WebSocketServer, WebSocket, type RawData } from 'ws';
import {
  JsonLineDecoder,
  encodeJsonLine,
  type ClientCommand,
  type WireServerMessage,
  type BridgeErrorMessage,
  type BridgeStatusMessage,
  type BridgeStderrMessage,
  type RunningSessionInfo,
} from '@lemon-web/shared';
import { loadDotenvFromDir } from './dotenv.js';
import {
  type BridgeOptions,
  buildRpcArgs,
  parseArgs,
  parseGatewayProbeOutput,
  contentTypeFor,
} from './utils.js';

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

function withServerTime<T extends object>(message: T): T & { server_time: number } {
  return { ...message, server_time: Date.now() };
}

function inferGatewayNodeName(): string {
  const explicit = process.env.LEMON_GATEWAY_NODE;
  if (explicit && explicit.trim() !== '') {
    return explicit;
  }

  const shortHost = os.hostname().split('.')[0] || 'localhost';
  return `lemon_gateway@${shortHost}`;
}

function fetchGatewayRunningSessionsAsync(
  timeoutMs = 6000
): Promise<{ sessions: RunningSessionInfo[]; error: string | null }> {
  const gatewayNode = inferGatewayNodeName();
  const cookie =
    process.env.LEMON_GATEWAY_NODE_COOKIE ||
    process.env.LEMON_GATEWAY_COOKIE ||
    'lemon_gateway_dev_cookie';
  const probeNode = `lemon_web_probe_${process.pid}_${Math.floor(Math.random() * 100_000)}`;

  const script = `
    node_name = "${gatewayNode}"
    node_atom = String.to_atom(node_name)

    connect_ok =
      try do
        Node.connect(node_atom)
      rescue
        _ -> false
      end

    if connect_ok do
      selector = [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]
      entries = :rpc.call(node_atom, Registry, :select, [LemonGateway.ThreadRegistry, selector], 2000)

      list =
        case entries do
          value when is_list(value) -> value
          _ -> []
        end

      safe_get_state = fn pid ->
        try do
          :rpc.call(node_atom, :sys, :get_state, [pid], 1500)
        catch
          _, _ -> %{}
        end
      end

      safe_job_cwd = fn job ->
        case job do
          %{cwd: cwd} when is_binary(cwd) and byte_size(cwd) > 0 -> cwd
          _ -> nil
        end
      end

      line_for = fn session_key, worker_pid ->
        worker_state =
          case safe_get_state.(worker_pid) do
            state when is_map(state) -> state
            _ -> %{}
          end

        current_run = Map.get(worker_state, :current_run)
        is_streaming = is_pid(current_run)
        jobs = Map.get(worker_state, :jobs, :queue.new())

        cwd =
          cond do
            is_pid(current_run) ->
              run_state =
                case safe_get_state.(current_run) do
                  state when is_map(state) -> state
                  _ -> %{}
                end

              run_job = Map.get(run_state, :job)
              safe_job_cwd.(run_job) || ("gateway://" <> session_key)

            true ->
              queue_head =
                case :queue.out(jobs) do
                  {{:value, job}, _rest} -> job
                  _ -> nil
                end

              safe_job_cwd.(queue_head) || ("gateway://" <> session_key)
          end

        sid = Base.url_encode64(session_key, padding: false)
        cwd64 = Base.url_encode64(cwd, padding: false)
        flag = if is_streaming, do: "1", else: "0"
        sid <> "|" <> cwd64 <> "|" <> flag
      end

      list
      |> Enum.map(fn
        {{:session, session_key}, worker_pid} when is_binary(session_key) and is_pid(worker_pid) ->
          line_for.(session_key, worker_pid)

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.each(&IO.puts/1)
    else
      IO.puts("__ERROR__|connect_failed|" <> node_name)
    end
  `;

  return new Promise((resolve) => {
    const child = spawn('elixir', ['--sname', probeNode, '--cookie', cookie, '-e', script], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let settled = false;

    const finish = (
      payload: { sessions: RunningSessionInfo[]; error: string | null }
    ): void => {
      if (settled) {
        return;
      }
      settled = true;
      clearTimeout(timer);
      resolve(payload);
    };

    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        // ignore
      }
      finish({ sessions: [], error: `gateway probe timed out after ${timeoutMs}ms` });
    }, timeoutMs);

    child.stdout?.on('data', (chunk) => {
      stdout += chunk.toString('utf8');
    });

    child.stderr?.on('data', (chunk) => {
      stderr += chunk.toString('utf8');
    });

    child.on('error', (error) => {
      finish(parseGatewayProbeOutput(stdout, stderr, null, error));
    });

    child.on('close', (status) => {
      finish(parseGatewayProbeOutput(stdout, stderr, status));
    });
  });
}

function resolveWsBridgeToken(): string | null {
  const raw =
    process.env.LEMON_WEB_WS_TOKEN
    || process.env.LEMON_BRIDGE_WS_TOKEN
    || '';
  const token = raw.trim();
  return token.length > 0 ? token : null;
}

function extractClientToken(req: http.IncomingMessage): string | null {
  const headerToken = req.headers['x-lemon-ws-token'];
  if (typeof headerToken === 'string' && headerToken.trim().length > 0) {
    return headerToken.trim();
  }

  const authorization = req.headers.authorization;
  if (typeof authorization === 'string' && authorization.toLowerCase().startsWith('bearer ')) {
    return authorization.slice(7).trim();
  }

  try {
    const requestUrl = new URL(req.url || '/', 'http://localhost');
    const queryToken = requestUrl.searchParams.get('token');
    if (queryToken && queryToken.trim().length > 0) {
      return queryToken.trim();
    }
  } catch {
    // ignore
  }

  return null;
}

function secureTokenCompare(actual: string, expected: string): boolean {
  const left = Buffer.from(actual);
  const right = Buffer.from(expected);
  if (left.length !== right.length) {
    return false;
  }
  return timingSafeEqual(left, right);
}

function isWsAuthorized(req: http.IncomingMessage, expectedToken: string | null): boolean {
  if (!expectedToken) {
    return true;
  }
  const provided = extractClientToken(req);
  if (!provided) {
    return false;
  }
  return secureTokenCompare(provided, expectedToken);
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

const opts = parseArgs(process.argv);
loadDotenvFromDir(opts.cwd || process.cwd());
const port = Number.isFinite(opts.port) ? (opts.port as number) : DEFAULT_PORT;
const staticDir = resolveStaticDir(opts.staticDir);
const wsBridgeToken = resolveWsBridgeToken();

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

wss.on('connection', (ws: WebSocket, req: http.IncomingMessage) => {
  if (!isWsAuthorized(req, wsBridgeToken)) {
    const error: BridgeErrorMessage = {
      type: 'bridge_error',
      message: 'Unauthorized WebSocket client',
    };

    try {
      ws.send(JSON.stringify(withServerTime(error)));
    } catch {
      // ignore
    }

    ws.close(1008, 'unauthorized');
    return;
  }

  clients.add(ws);

  if (lastBridgeStatus) {
    ws.send(JSON.stringify(lastBridgeStatus));
  }

  ws.on('message', (data: RawData) => {
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

    if (parsed.type === 'list_running_sessions') {
      void fetchGatewayRunningSessionsAsync().then((gatewaySessions) => {
        if (ws.readyState !== WebSocket.OPEN) {
          return;
        }

        const runningSessionsMessage = withServerTime({
          type: 'running_sessions' as const,
          sessions: gatewaySessions.sessions,
          error: gatewaySessions.error,
        });
        ws.send(JSON.stringify(runningSessionsMessage));

        if (gatewaySessions.error !== null) {
          bridge.send(parsed);
        }
      });
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
