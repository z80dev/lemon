#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lemon-launcher-reuse.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ "$SERVER_PID" =~ ^[0-9]+$ ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  if [[ "$TEST_DIR" == "${TMPDIR:-/tmp}"/lemon-launcher-reuse.* ]]; then
    rm -rf -- "$TEST_DIR"
  fi
}

trap cleanup EXIT

read -r CONTROL_PORT WEB_PORT < <(
  python3 - <<'PY'
import socket

holders = []
ports = []
for _ in range(2):
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    holders.append(sock)
    ports.append(sock.getsockname()[1])
print(*ports)
for sock in holders:
    sock.close()
PY
)

python3 - "$CONTROL_PORT" "$WEB_PORT" <<'PY' &
import http.server
import signal
import sys
import threading

control_port, web_port = map(int, sys.argv[1:])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/healthz":
            self.send_response(404)
            self.end_headers()
            return

        body = b'{"ok": true}\n' if self.server.server_port == control_port else b'ok\n'
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass

servers = [
    http.server.ThreadingHTTPServer(("127.0.0.1", control_port), Handler),
    http.server.ThreadingHTTPServer(("127.0.0.1", web_port), Handler),
]

for server in servers:
    threading.Thread(target=server.serve_forever, daemon=True).start()

signal.pause()
PY
SERVER_PID=$!

for _attempt in {1..50}; do
  if curl -fsS --max-time 1 "http://127.0.0.1:$CONTROL_PORT/healthz" >/dev/null 2>&1 &&
     curl -fsS --max-time 1 "http://127.0.0.1:$WEB_PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

launcher_output="$TEST_DIR/launcher-output"
web_output="$TEST_DIR/web-output"

LEMON_CONTROL_PLANE_PORT="$CONTROL_PORT" \
LEMON_WEB_PORT="$WEB_PORT" \
  "$ROOT/bin/lemon" --daemon --no-distribution >"$launcher_output" 2>&1

grep -Fq "A healthy Lemon runtime is already running; reusing it." "$launcher_output"
grep -Fq "Control plane: ws://localhost:$CONTROL_PORT/ws" "$launcher_output"
grep -Fq "Web UI:        http://localhost:$WEB_PORT/" "$launcher_output"

if grep -Fq "Starting unified Lemon runtime" "$launcher_output"; then
  echo "launcher attempted to start a duplicate runtime" >&2
  exit 1
fi

LEMON_CONTROL_PLANE_PORT="$CONTROL_PORT" \
LEMON_WEB_PORT="$WEB_PORT" \
  "$ROOT/bin/lemon" web --no-open >"$web_output" 2>&1

grep -Fq "Lemon Web: http://127.0.0.1:$WEB_PORT/" "$web_output"
echo "Source launcher existing-runtime reuse verified"
