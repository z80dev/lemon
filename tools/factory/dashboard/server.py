"""Loopback-only GET server. Bind refusal, Host check and the absence of mutating routes live here."""

from __future__ import annotations

import json
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import project as projects
from store import Invalid

from . import data, render

LOOPBACK_HOST = "127.0.0.1"
DEFAULT_PORT = 8765
ALLOWED_HOSTNAMES = {"127.0.0.1", "localhost", "[::1]"}


def _handler(project: projects.Project) -> type[BaseHTTPRequestHandler]:
    ledger = project.ledger()

    class Handler(BaseHTTPRequestHandler):
        server_version = "FactoryDashboard"
        sys_version = ""

        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 - stdlib signature
            return

        def _send(self, status: int, body: str, content_type: str, nonce: str | None = None,
                  head_only: bool = False) -> None:
            payload = body.encode("utf-8")
            script = f"'nonce-{nonce}'" if nonce else "'none'"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Content-Security-Policy",
                             f"default-src 'none'; style-src 'unsafe-inline'; script-src {script}; "
                             "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
            self.end_headers()
            if not head_only:
                self.wfile.write(payload)

        def _host_ok(self) -> bool:
            """Reject DNS-rebinding: the Host header must name this loopback listener."""
            host = self.headers.get("Host", "")
            name, _, port = host.rpartition(":")
            return name in ALLOWED_HOSTNAMES and port == str(self.server.server_address[1])

        def _route(self, head_only: bool) -> None:
            if not self._host_ok():
                return self._send(403, "forbidden host\n", "text/plain; charset=utf-8", head_only=head_only)
            path = self.path.split("?", 1)[0].split("#", 1)[0]
            if path not in ("/", "/fragment", "/api/state"):
                return self._send(404, "not found\n", "text/plain; charset=utf-8", head_only=head_only)
            try:
                state = data.collect(project, ledger)
            except Exception as exc:  # noqa: BLE001 - surface any ledger read failure in the UI, never crash a thread
                message = f"{type(exc).__name__}: {exc}"
                if path == "/api/state":
                    return self._send(500, json.dumps({"ok": False, "error": message}), "application/json",
                                      head_only=head_only)
                fragment = render.error_fragment(message)
                state = None
            else:
                fragment = render.fragment(state)
            if path == "/api/state":
                return self._send(200, json.dumps({"ok": True, **state}, default=str), "application/json",
                                  head_only=head_only)
            if path == "/fragment":
                return self._send(200, fragment, "text/html; charset=utf-8", head_only=head_only)
            nonce = secrets.token_urlsafe(16)
            self._send(200, render.page(fragment, nonce), "text/html; charset=utf-8", nonce, head_only)

        def do_GET(self) -> None:  # noqa: N802 - stdlib naming
            self._route(head_only=False)

        def do_HEAD(self) -> None:  # noqa: N802
            self._route(head_only=True)

        def _refuse(self) -> None:
            self.send_response(405)
            self.send_header("Allow", "GET, HEAD")
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = _refuse  # noqa: N815

    return Handler


def make_server(project: projects.Project, host: str = LOOPBACK_HOST, port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    if host not in (LOOPBACK_HOST, "localhost"):
        raise Invalid(f"the dashboard binds {LOOPBACK_HOST} only; refusing {host!r}", host=host)
    server = ThreadingHTTPServer((LOOPBACK_HOST, port), _handler(project))
    server.daemon_threads = True
    return server


def serve(project: projects.Project, *, host: str = LOOPBACK_HOST, port: int = DEFAULT_PORT) -> dict[str, Any]:
    server = make_server(project, host, port)
    url = f"http://{LOOPBACK_HOST}:{server.server_address[1]}/"
    print(json.dumps({"ok": True, "dashboard": url, "read_only": True}), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return {"ok": True, "stopped": url}
