// src/index.ts
import { spawn } from "child_process";
import http from "http";
import fs2 from "fs";
import path2 from "path";
import { fileURLToPath } from "url";
import { WebSocketServer, WebSocket } from "ws";
import {
  JsonLineDecoder,
  encodeJsonLine
} from "@lemon-web/shared";

// src/dotenv.ts
import fs from "fs";
import path from "path";
var KEY_PATTERN = /^[A-Za-z_][A-Za-z0-9_]*$/;
function loadDotenvFromDir(dir, opts2) {
  const targetDir = path.resolve(dir || process.cwd());
  const envPath = path.join(targetDir, ".env");
  const override = opts2?.override === true;
  let content;
  try {
    content = fs.readFileSync(envPath, "utf-8");
  } catch {
    return;
  }
  for (const line of content.split(/\r?\n/)) {
    const parsed = parseLine(line);
    if (!parsed) {
      continue;
    }
    const [key, value] = parsed;
    if (override || process.env[key] == null) {
      process.env[key] = value;
    }
  }
}
function parseLine(line) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) {
    return null;
  }
  const exportStripped = trimmed.startsWith("export ") ? trimmed.slice("export ".length).trimStart() : trimmed;
  const eqIndex = exportStripped.indexOf("=");
  if (eqIndex <= 0) {
    return null;
  }
  const key = exportStripped.slice(0, eqIndex).trim();
  if (!KEY_PATTERN.test(key)) {
    return null;
  }
  const rawValue = exportStripped.slice(eqIndex + 1).trimStart();
  return [key, parseValue(rawValue)];
}
function parseValue(rawValue) {
  if (!rawValue) {
    return "";
  }
  if (rawValue.startsWith('"')) {
    const match = rawValue.match(/^"((?:\\.|[^"])*)"(?:\s+#.*)?\s*$/);
    if (match) {
      return unescapeDoubleQuoted(match[1]);
    }
  }
  if (rawValue.startsWith("'")) {
    const match = rawValue.match(/^'([^']*)'(?:\s+#.*)?\s*$/);
    if (match) {
      return match[1];
    }
  }
  return stripInlineComment(rawValue).trim();
}
function stripInlineComment(value) {
  return value.replace(/\s+#.*$/, "");
}
function unescapeDoubleQuoted(value) {
  return value.replace(/\\n/g, "\n").replace(/\\r/g, "\r").replace(/\\t/g, "	").replace(/\\"/g, '"').replace(/\\\\/g, "\\");
}

// src/index.ts
var DEFAULT_PORT = 3939;
var RpcBridge = class {
  constructor(opts2) {
    this.opts = opts2;
  }
  proc = null;
  decoder = null;
  stopping = false;
  restartCount = 0;
  start(onMessage) {
    if (this.proc) {
      return;
    }
    this.stopping = false;
    const lemonPath = this.opts.lemonPath || process.env.LEMON_PATH || findLemonPath();
    if (!lemonPath) {
      const error = {
        type: "bridge_error",
        message: "Could not find lemon project root. Set LEMON_PATH or --lemon-path."
      };
      onMessage(withServerTime(error));
      return;
    }
    const args = buildRpcArgs(this.opts);
    const status = {
      type: "bridge_status",
      state: "starting",
      message: "Starting debug_agent_rpc...",
      pid: null
    };
    onMessage(withServerTime(status));
    this.proc = spawn("mix", args, {
      cwd: lemonPath,
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        MIX_ENV: "dev"
      }
    });
    this.decoder = new JsonLineDecoder({
      onMessage: (value) => {
        if (value.type === "ready") {
          this.restartCount = 0;
        }
        onMessage(withServerTime(value));
      },
      onError: (error, rawLine) => {
        const message = {
          type: "bridge_error",
          message: `Invalid JSON from RPC: ${error.message}`,
          detail: rawLine
        };
        onMessage(withServerTime(message));
      }
    });
    this.proc.stdout?.on("data", (chunk) => {
      this.decoder?.write(chunk);
    });
    this.proc.stdout?.on("close", () => {
      this.decoder?.flush();
    });
    this.proc.stderr?.on("data", (chunk) => {
      if (!this.opts.debug) {
        return;
      }
      const message = {
        type: "bridge_stderr",
        message: chunk.toString()
      };
      onMessage(withServerTime(message));
    });
    this.proc.on("error", (err) => {
      const message = {
        type: "bridge_error",
        message: `RPC process error: ${err.message}`,
        detail: err
      };
      onMessage(withServerTime(message));
    });
    this.proc.on("close", (code, signal) => {
      const statusMessage = {
        type: "bridge_status",
        state: "stopped",
        message: `RPC exited (code=${code ?? "null"}, signal=${signal ?? "null"})`,
        pid: this.proc?.pid ?? null
      };
      onMessage(withServerTime(statusMessage));
      this.proc = null;
      this.decoder = null;
      if (!this.stopping) {
        const delay = Math.min(1e4, 500 * Math.pow(2, this.restartCount));
        this.restartCount += 1;
        setTimeout(() => {
          this.start(onMessage);
        }, delay);
      }
    });
    const running = {
      type: "bridge_status",
      state: "running",
      message: "RPC running",
      pid: this.proc.pid ?? null
    };
    onMessage(withServerTime(running));
  }
  send(command) {
    if (!this.proc?.stdin?.writable) {
      return;
    }
    this.proc.stdin.write(encodeJsonLine(command));
  }
  stop() {
    if (!this.proc) {
      return;
    }
    this.stopping = true;
    try {
      this.send({ type: "quit" });
    } catch {
    }
    setTimeout(() => {
      if (this.proc && !this.proc.killed) {
        this.proc.kill("SIGTERM");
      }
    }, 1e3);
  }
};
function buildRpcArgs(opts2) {
  const args = ["run", "scripts/debug_agent_rpc.exs", "--"];
  if (opts2.cwd) {
    args.push("--cwd", opts2.cwd);
  }
  if (opts2.model) {
    args.push("--model", opts2.model);
  }
  if (opts2.baseUrl) {
    args.push("--base_url", opts2.baseUrl);
  }
  if (opts2.systemPrompt) {
    args.push("--system_prompt", opts2.systemPrompt);
  }
  if (opts2.sessionFile) {
    args.push("--session-file", opts2.sessionFile);
  }
  if (opts2.debug) {
    args.push("--debug");
  }
  if (opts2.ui === false) {
    args.push("--no-ui");
  }
  return args;
}
function parseArgs(argv) {
  const opts2 = {};
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    switch (arg) {
      case "--cwd":
        opts2.cwd = next;
        i += 1;
        break;
      case "--model":
        opts2.model = next;
        i += 1;
        break;
      case "--base_url":
      case "--base-url":
        opts2.baseUrl = next;
        i += 1;
        break;
      case "--system-prompt":
      case "--system_prompt":
        opts2.systemPrompt = next;
        i += 1;
        break;
      case "--session-file":
      case "--session_file":
        opts2.sessionFile = next;
        i += 1;
        break;
      case "--debug":
        opts2.debug = true;
        break;
      case "--no-ui":
        opts2.ui = false;
        break;
      case "--lemon-path":
        opts2.lemonPath = next;
        i += 1;
        break;
      case "--port":
        opts2.port = Number(next);
        i += 1;
        break;
      case "--static-dir":
        opts2.staticDir = next;
        i += 1;
        break;
      default:
        break;
    }
  }
  return opts2;
}
function withServerTime(message) {
  return { ...message, server_time: Date.now() };
}
function findLemonPath() {
  const cwd = process.cwd();
  if (cwd.includes("lemon")) {
    let current = cwd;
    while (current !== "/") {
      if (fs2.existsSync(path2.join(current, "mix.exs")) && fs2.existsSync(path2.join(current, "apps"))) {
        return current;
      }
      current = path2.dirname(current);
    }
  }
  const home = process.env.HOME || "";
  const commonPaths = [
    "/home/z80/dev/lemon",
    path2.join(home, "dev", "lemon"),
    path2.join(home, "projects", "lemon")
  ];
  for (const candidate of commonPaths) {
    if (fs2.existsSync(path2.join(candidate, "mix.exs"))) {
      return candidate;
    }
  }
  return null;
}
function resolveStaticDir(custom) {
  if (custom) {
    return custom;
  }
  const currentDir = path2.dirname(fileURLToPath(import.meta.url));
  const distPath = path2.resolve(currentDir, "..", "..", "web", "dist");
  if (fs2.existsSync(distPath)) {
    return distPath;
  }
  return null;
}
function serveStatic(distDir, req, res) {
  const url = new URL(req.url || "/", "http://localhost");
  let pathname = decodeURIComponent(url.pathname);
  if (pathname === "/") {
    pathname = "/index.html";
  }
  const filePath = path2.join(distDir, pathname);
  if (!filePath.startsWith(distDir)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }
  fs2.readFile(filePath, (err, data) => {
    if (err) {
      const fallback = path2.join(distDir, "index.html");
      if (err.code === "ENOENT" && !path2.extname(filePath)) {
        fs2.readFile(fallback, (fallbackErr, fallbackData) => {
          if (fallbackErr) {
            res.writeHead(404);
            res.end("Not Found");
            return;
          }
          res.setHeader("Content-Type", "text/html");
          res.writeHead(200);
          res.end(fallbackData);
        });
        return;
      }
      res.writeHead(404);
      res.end("Not Found");
      return;
    }
    const ext = path2.extname(filePath).toLowerCase();
    const contentType = contentTypeFor(ext);
    if (contentType) {
      res.setHeader("Content-Type", contentType);
    }
    res.writeHead(200);
    res.end(data);
  });
}
function contentTypeFor(ext) {
  switch (ext) {
    case ".html":
      return "text/html";
    case ".js":
      return "text/javascript";
    case ".css":
      return "text/css";
    case ".svg":
      return "image/svg+xml";
    case ".json":
      return "application/json";
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".woff":
      return "font/woff";
    case ".woff2":
      return "font/woff2";
    default:
      return null;
  }
}
var opts = parseArgs(process.argv);
loadDotenvFromDir(opts.cwd || process.cwd());
var port = Number.isFinite(opts.port) ? opts.port : DEFAULT_PORT;
var staticDir = resolveStaticDir(opts.staticDir);
var server = http.createServer((req, res) => {
  if (staticDir) {
    serveStatic(staticDir, req, res);
    return;
  }
  res.writeHead(200);
  res.end("Lemon Web bridge is running.");
});
var wss = new WebSocketServer({ server, path: "/ws" });
var clients = /* @__PURE__ */ new Set();
var lastBridgeStatus = null;
var bridge = new RpcBridge(opts);
bridge.start((message) => {
  if (message.type === "bridge_status") {
    lastBridgeStatus = message;
  }
  broadcast(message);
});
wss.on("connection", (ws) => {
  clients.add(ws);
  if (lastBridgeStatus) {
    ws.send(JSON.stringify(lastBridgeStatus));
  }
  ws.on("message", (data) => {
    const text = data.toString();
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      const error = {
        type: "bridge_error",
        message: "Invalid JSON from client",
        detail: text
      };
      ws.send(JSON.stringify(withServerTime(error)));
      return;
    }
    bridge.send(parsed);
  });
  ws.on("close", () => {
    clients.delete(ws);
  });
});
function broadcast(message) {
  const payload = JSON.stringify(message);
  for (const client of clients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(payload);
    }
  }
}
server.listen(port, () => {
  const status = {
    type: "bridge_status",
    state: "running",
    message: `Bridge listening on http://localhost:${port}`,
    pid: process.pid
  };
  const enriched = withServerTime(status);
  lastBridgeStatus = enriched;
  broadcast(enriched);
});
process.on("SIGINT", () => {
  bridge.stop();
  process.exit(0);
});
process.on("SIGTERM", () => {
  bridge.stop();
  process.exit(0);
});
