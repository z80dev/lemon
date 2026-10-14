"""Run with python3 -m unittest discover -s apps/coding_agent/test/coding_agent/execution_node -p node_process_helper_test.py."""
import base64
import json
import os
from pathlib import Path
import select
import struct
import subprocess
import sys
import tempfile
import time
import unittest

APP = Path(__file__).resolve().parents[3]
HELPER = APP / "priv" / "node_process.py"
FIXTURE = APP / "test" / "support" / "node_process_fixture.py"


class NodeProcessHelperTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = self.directory.name
        self.helpers = []

    def tearDown(self):
        for helper in self.helpers:
            if helper.stdin and not helper.stdin.closed:
                helper.stdin.close()
            try:
                helper.wait(timeout=3)
            except subprocess.TimeoutExpired:
                helper.kill()
                helper.wait(timeout=3)
            helper.stdout.close()
            helper.stderr.close()
        self.directory.cleanup()

    def launch(self, extra, **overrides):
        args = {"nodeId": "helper-node", "processId": "helper-process", "cwd": self.root,
                "argv": [sys.executable, str(FIXTURE), *extra], "stdinBase64": "",
                "timeoutMs": 10000, "maxOutputBytes": 1048576}
        args.update(overrides)
        helper = subprocess.Popen([sys.executable, str(HELPER)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.helpers.append(helper)
        self.send(helper, {"op": "run", "args": args, "policy": {"cwd": self.root, "roots": [self.root]}})
        return helper

    @staticmethod
    def send(helper, request):
        body = json.dumps(request).encode()
        helper.stdin.write(struct.pack(">I", len(body)) + body)
        helper.stdin.flush()

    def receive(self, helper):
        deadline = time.monotonic() + 10

        def exact(count):
            result = bytearray()
            while len(result) < count:
                remaining = deadline - time.monotonic()
                self.assertGreater(remaining, 0, "helper receipt deadline")
                self.assertTrue(select.select([helper.stdout], [], [], remaining)[0])
                data = os.read(helper.stdout.fileno(), count - len(result))
                self.assertTrue(data, "helper closed without a receipt")
                result.extend(data)
            return result

        length = struct.unpack(">I", exact(4))[0]
        self.assertLessEqual(length, 4 * 1024 * 1024)
        response = json.loads(exact(length))
        helper.wait(timeout=3)
        self.assertEqual(helper.stderr.read(), b"", "helper must never emit credential diagnostics")
        return response

    def await_file(self, path):
        deadline = time.monotonic() + 3
        while not os.path.exists(path):
            self.assertLess(time.monotonic(), deadline, "fixture readiness deadline")
            time.sleep(0.01)

    def test_literal_long_unicode_argv_raw_stdin_eof_and_separate_non_tty_pipes(self):
        literal = ["雪 'single' \"double\" space", "", "λ quote ' " * 2100]
        raw = b"\x00\xff\x01exact stdin\n"
        helper = self.launch(["report", *literal], stdinBase64=base64.b64encode(raw).decode())
        receipt = self.receive(helper)["ok"]
        report = json.loads(base64.b64decode(receipt["stdoutBase64"]))
        self.assertEqual(report["argv"], literal)
        self.assertEqual(report["stdin"], base64.b64encode(raw).decode())
        self.assertEqual(report["isatty"], [False, False, False])
        self.assertEqual(report["cwd"], os.path.realpath(self.root))
        self.assertEqual(base64.b64decode(receipt["stderrBase64"]), b"independent-stderr\0\xff")
        self.assertEqual(receipt["exitCode"], 17)
        self.assertEqual(receipt["state"], "completed")
        self.assertFalse(receipt["outputTruncated"])

    def test_control_eof_and_packet_cancel_kill_actual_descendants(self):
        for action in ("eof", "cancel"):
            with self.subTest(action=action):
                ready = os.path.join(self.root, action + "-ready")
                marker = os.path.join(self.root, action + "-survived")
                helper = self.launch(["tree", ready, marker])
                self.await_file(ready)
                if action == "eof":
                    helper.stdin.close()
                else:
                    self.send(helper, {"op": "cancel"})
                receipt = self.receive(helper)["ok"]
                self.assertEqual(receipt["state"], "cancelled")
                self.assertIsInstance(receipt["exitCode"], int)
                time.sleep(2.1)
                self.assertFalse(os.path.exists(marker))

    def test_timeout_and_overflow_have_real_exit_and_bounded_bytes(self):
        ready = os.path.join(self.root, "timeout-ready")
        marker = os.path.join(self.root, "timeout-survived")
        helper = self.launch(["tree", ready, marker], timeoutMs=1000)
        receipt = self.receive(helper)["ok"]
        self.assertEqual(receipt["state"], "cancelled")
        self.assertIsInstance(receipt["exitCode"], int)
        time.sleep(2.1)
        self.assertFalse(os.path.exists(marker))
        response = self.receive(self.launch(["overflow"], maxOutputBytes=257))
        self.assertIn("ok", response, "valid admitted overflow must return its actual bounded receipt: " + repr(response))
        receipt = response["ok"]
        self.assertEqual(receipt["state"], "cancelled")
        self.assertTrue(receipt["outputTruncated"])
        self.assertEqual(sum(len(base64.b64decode(receipt[key])) for key in ("stdoutBase64", "stderrBase64")), 257)

    def test_symlink_escape_and_traversal_do_not_execute(self):
        outside = os.path.dirname(self.root)
        os.symlink(outside, os.path.join(self.root, "escape"))
        for cwd in ("escape", "../outside"):
            with self.subTest(cwd=cwd):
                self.assertEqual(self.receive(self.launch(["report"], cwd=cwd)), {"error": "path_not_allowed"})

    def test_launch_failure_is_an_error_not_fabricated_exit(self):
        helper = self.launch([], argv=["lemon-native-executable-that-does-not-exist"])
        self.assertEqual(self.receive(helper), {"error": "executable_not_found"})


if __name__ == "__main__":
    unittest.main()
