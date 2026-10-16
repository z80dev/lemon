"""Dashboard: loopback-only binding, read-only routes, and escaped untrusted text.

Uses a temp factory home; the installed factory state is never read.
"""

from __future__ import annotations

import http.client
import json
import os
import sys
import threading
import unittest
from http.server import ThreadingHTTPServer

from .helpers import FACTORY_DIR, FactoryHome

sys.path.insert(0, str(FACTORY_DIR))

import dashboard  # noqa: E402
import project as projects  # noqa: E402
from store import FactoryError, Ledger  # noqa: E402

XSS_TITLE = "<script>alert('title')</script>"
XSS_LOG = "<img src=x onerror=alert('ci')>\x1b[31mred\x1b[0m"
XSS_SUPERVISOR = "</pre><script>alert('supervisor')</script>"
STRIPPED = ("FACTORY_PROJECT", "FACTORY_ROLE", "FACTORY_EPOCH")


class DashboardTest(unittest.TestCase):
    def setUp(self) -> None:
        self.home = FactoryHome()
        self.home.cli("register")
        keys = ("FACTORY_CONFIG_HOME", "FACTORY_STATE_HOME", "FACTORY_DATA_HOME", *STRIPPED)
        self.saved_env = {k: os.environ.get(k) for k in keys}
        for key in STRIPPED:
            os.environ.pop(key, None)
        for key in ("FACTORY_CONFIG_HOME", "FACTORY_STATE_HOME", "FACTORY_DATA_HOME"):
            os.environ[key] = self.home.env[key]
        self.project = projects.resolve(project_id="widget")
        self.ledger = Ledger(self.project.db_path, "widget")
        self.seed()
        self.server: ThreadingHTTPServer = dashboard.make_server(self.project, port=0)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.home.cleanup()

    def seed(self) -> None:
        ledger = self.ledger
        running, _ = ledger.add_task({"request": "running work", "title": XSS_TITLE}, actor="t", request_key=None)
        running = ledger.transition(running["id"], running["revision"], "queued", actor="t", reason="go",
                                    request_key=None)
        ledger.update_runtime(mode="running", desired_mode="running", epoch=1)
        ledger.reserve_attempt(running["id"], running["revision"], "implement", epoch=1, actor="t", request_key=None)
        landing, _ = ledger.add_task({"request": "in integration", "title": "landing"}, actor="t", request_key=None)
        for status in ("queued", "active", "ready", "verifying"):
            landing = ledger.transition(landing["id"], landing["revision"], status, actor="t", reason="x",
                                        request_key=None)
        ledger.save_integration(landing["id"], event="integration.pr_opened", attempt_id="A-1", state="ci_running",
                                branch="factory/F-0002", head_sha="a" * 40, pr_number=77, ci_run_id=555)
        ci = self.project.state_dir / "artifacts" / "ci"
        ci.mkdir(parents=True)
        (ci / f"{landing['id']}-run-555.log").write_text(f"failed jobs: ['x']\n\n{XSS_LOG}\n")
        self.project.logs_dir.mkdir(parents=True, exist_ok=True)
        (self.project.logs_dir / "supervisor.log").write_text(f"supervisor started\n{XSS_SUPERVISOR}\n")
        self.running_id, self.landing_id = running["id"], landing["id"]

    def request(self, method: str, path: str, host: str | None = None) -> tuple[int, dict[str, str], str]:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.putrequest(method, path, skip_host=True)
            conn.putheader("Host", host or f"127.0.0.1:{self.port}")
            conn.putheader("Content-Length", "0")
            conn.endheaders()
            response = conn.getresponse()
            return response.status, {k.lower(): v for k, v in response.getheaders()}, response.read().decode()
        finally:
            conn.close()

    # loopback binding -----------------------------------------------------------------

    def test_binds_loopback_only(self) -> None:
        self.assertEqual(self.server.server_address[0], "127.0.0.1")

    def test_non_loopback_bind_is_refused(self) -> None:
        for host in ("0.0.0.0", "::", "192.168.1.10", "example.com", ""):
            with self.subTest(host=host), self.assertRaises(FactoryError):
                dashboard.make_server(self.project, host=host, port=0)

    def test_cli_refuses_non_loopback_host(self) -> None:
        code, payload = self.home.cli("dashboard", "--host", "0.0.0.0", "--port", "0", check=False)
        self.assertEqual(code, 2)
        self.assertFalse(payload["ok"])

    def test_foreign_host_header_is_rejected(self) -> None:
        for host in ("evil.example", f"evil.example:{self.port}", "127.0.0.1:1", ""):
            with self.subTest(host=host):
                status, _, body = self.request("GET", "/", host=host or "x")
                self.assertEqual(status, 403)
                self.assertNotIn(self.project.id, body)

    # read-only ------------------------------------------------------------------------

    def snapshot(self) -> tuple[int, list[dict], list[dict]]:
        return (self.ledger.last_event_seq(), self.ledger.list_tasks(), self.ledger.list_attempts())

    def test_only_get_and_head_are_served(self) -> None:
        handler = self.server.RequestHandlerClass
        allowed = {"do_GET", "do_HEAD"}
        refusing = {"do_POST", "do_PUT", "do_PATCH", "do_DELETE", "do_OPTIONS"}
        self.assertEqual({m for m in dir(handler) if m.startswith("do_")} - refusing, allowed)
        before = self.snapshot()
        for method in sorted(refusing):
            for path in ("/", "/fragment", "/api/state", "/api/tasks/F-0001/cancel", "/pause"):
                with self.subTest(method=method, path=path):
                    status, headers, _ = self.request(method.removeprefix("do_"), path)
                    self.assertEqual(status, 405)
                    self.assertEqual(headers["allow"], "GET, HEAD")
        self.assertEqual(self.snapshot(), before)

    def test_get_routes_do_not_change_the_ledger(self) -> None:
        before = self.snapshot()
        for path in ("/", "/fragment", "/api/state", "/pause?x=1", "/api/state?stop=1"):
            self.request("GET", path)
        self.request("HEAD", "/")
        self.assertEqual(self.snapshot(), before)

    def test_unknown_routes_are_404(self) -> None:
        for path in ("/pause", "/start", "/api/tasks", "/../etc/passwd"):
            with self.subTest(path=path):
                self.assertEqual(self.request("GET", path)[0], 404)

    def test_page_has_no_forms_or_mutating_controls(self) -> None:
        _, _, body = self.request("GET", "/")
        for needle in ("<form", "<button", "<input", 'method="post"'):
            self.assertNotIn(needle, body.lower())

    # content --------------------------------------------------------------------------

    def test_shows_health_tasks_attempts_integration_events_and_logs(self) -> None:
        status, headers, body = self.request("GET", "/fragment")
        self.assertEqual(status, 200)
        self.assertIn("text/html", headers["content-type"])
        for expected in ("Runtime health", "Tasks by status", "Live attempts", "Integration PR / CI", "Event feed",
                         "Supervisor log tail", self.running_id, self.landing_id, f"{self.running_id}-implement-1",
                         "#77", "555", "attempt.reserved", "supervisor started"):
            self.assertIn(expected, body)

    def test_state_json_reads_ledger_through_store(self) -> None:
        status, headers, body = self.request("GET", "/api/state")
        self.assertEqual(status, 200)
        self.assertEqual(headers["content-type"], "application/json")
        state = json.loads(body)
        self.assertEqual(state["counts"]["active"], 1)
        self.assertEqual(state["counts"]["verifying"], 1)
        self.assertEqual([a["task_id"] for a in state["attempts"]], [self.running_id])
        self.assertEqual(state["integrations"][0]["integration"]["pr_number"], 77)
        self.assertEqual(state["last_event"], self.ledger.last_event_seq())
        self.assertEqual(state["runtime"]["state"], "stopped")  # no supervisor holds the kernel lock

    def test_updates_live_as_the_ledger_changes(self) -> None:
        self.assertNotIn("brand-new-task", self.request("GET", "/fragment")[2])
        self.ledger.add_task({"request": "brand-new-task"}, actor="t", request_key=None)
        self.assertIn("brand-new-task", self.request("GET", "/fragment")[2])

    # untrusted text --------------------------------------------------------------------

    def test_tool_output_is_html_escaped(self) -> None:
        for path in ("/", "/fragment"):
            _, _, body = self.request("GET", path)
            with self.subTest(path=path):
                for raw in ("<script>alert('title')", "<img src=x", "</pre><script>", "\x1b"):
                    self.assertNotIn(raw, body)
                self.assertIn("&lt;script&gt;alert(&#x27;title&#x27;)&lt;/script&gt;", body)  # task title + event
                self.assertIn("&lt;img src=x onerror=alert(&#x27;ci&#x27;)&gt;", body)  # CI log tail
                self.assertIn("&lt;/pre&gt;&lt;script&gt;alert(&#x27;supervisor&#x27;)", body)  # supervisor log

    def test_page_script_is_nonce_bound_and_policy_locks_down_content(self) -> None:
        _, headers, body = self.request("GET", "/")
        policy = headers["content-security-policy"]
        nonce = policy.split("script-src 'nonce-", 1)[1].split("'", 1)[0]
        self.assertIn(f'<script nonce="{nonce}">', body)
        self.assertEqual(body.count("<script"), 1)
        self.assertIn("default-src 'none'", policy)
        self.assertEqual(headers["x-content-type-options"], "nosniff")
        _, fragment_headers, _ = self.request("GET", "/fragment")
        self.assertIn("script-src 'none'", fragment_headers["content-security-policy"])


if __name__ == "__main__":
    unittest.main()
