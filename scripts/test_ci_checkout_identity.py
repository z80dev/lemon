#!/usr/bin/env python3
"""Hermetic CI producer/consumer contract tests; all GitHub metadata is FAKE.

Hosted CI uses the labelled consumer snapshot. For a read-only local cross-check:
FACTORY_IDENTITY_CONSUMER=/path/to/installed/integrator.py python3 scripts/test_ci_checkout_identity.py
Only the two consumer methods are loaded (no factory dependencies or state).
"""
import ast
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parent.parent
SNAPSHOT = ROOT / "scripts/fixtures/factory_checkout_consumer.py"


def consumer(path):
    tree = ast.parse(Path(path).read_text())
    klass = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "Integrator")
    methods = [n for n in klass.body if isinstance(n, ast.FunctionDef)
               and n.name in ("_checkout_identity", "_observe")]
    namespace = {"json": json, "Any": object, "CIWaiting": type("CIWaiting", (Exception,), {})}
    for node in methods:
        exec(compile(ast.Module(body=[node], type_ignores=[]), str(path), "exec"), namespace)
    return type("Consumer", (), {n.name: namespace[n.name] for n in methods}), namespace["CIWaiting"]


Consumer, CIWaiting = consumer(os.environ.get("FACTORY_IDENTITY_CONSUMER", SNAPSHOT))
WORKFLOW = (ROOT / ".github/workflows/ci.yml").read_text()
# This deliberately narrow extractor also detects additions/removals of jobs.
JOBS = dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:|\Z)",
                       WORKFLOW.split("\njobs:\n", 1)[1], re.M | re.S))
STEP = "Record tested checkout identity"
MARKER = "FACTORY_CI_IDENTITY="
FAKE_HEAD, FAKE_BASE = "b" * 40, "c" * 40


class IdentityTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="lemon-fake-ci-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.git("init", "-q")
        self.git("-c", "user.name=Fake CI", "-c", "user.email=fake@example.invalid",
                 "commit", "--allow-empty", "-qm", "fake tested checkout")
        self.sha = self.git("rev-parse", "HEAD")
        self.identity = dict(tested_sha=self.sha, pr_head_sha=FAKE_HEAD,
                             base_sha=FAKE_BASE, run_id=101, attempt=1)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], text=True).strip()

    def source(self, job):
        block = JOBS[job].split("      - name: " + STEP + "\n")
        self.assertEqual(len(block), 2, job)
        step = block[1].split("      - ", 1)[0]
        for key, expression in {"PR_HEAD_SHA": "github.event.pull_request.head.sha",
                                "PR_BASE_SHA": "github.event.pull_request.base.sha",
                                "GITHUB_RUN_ID": "github.run_id",
                                "GITHUB_RUN_ATTEMPT": "github.run_attempt"}.items():
            self.assertIn(key + ": ${{ " + expression + " }}", step)
        script = step.split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in script.splitlines() if line.startswith("          ")) + "\n"
        self.assertTrue(script.startswith("python3 -I - <<'PY'\n"))
        self.assertTrue(script.endswith("PY\n"))
        self.assertNotIn("${{", script)
        prefix = block[0].split("    steps:\n", 1)[1]
        self.assertEqual(prefix.count("      - "), 1, job)
        self.assertIn("      - uses: actions/checkout@v4", prefix)
        return script

    def produce(self, job="result", push=False, attempt=1):
        env = {**os.environ, "PR_HEAD_SHA": "" if push else FAKE_HEAD,
               "PR_BASE_SHA": "" if push else FAKE_BASE, "GITHUB_RUN_ID": "101",
               "GITHUB_RUN_ATTEMPT": str(attempt), "PYTHONPATH": str(self.root)}
        result = subprocess.run(["bash", "-e"], input=self.source(job), text=True,
                                cwd=self.root, env=env, capture_output=True, check=True)
        self.assertEqual(result.stderr, "")
        self.assertEqual(len(result.stdout.splitlines()), 1)
        return result.stdout.strip()

    def line(self, message, lane="CI result", step=STEP):
        return f"{lane}\t{step}\t2026-01-01T00:00:02.0000000Z {message}\n"

    def log(self, marker, lane="CI result", job="result", ansi="\x1b["):
        return (self.line("Runner setup", lane, "Set up job")
                + self.line("HEAD checked out", lane, "Run actions/checkout@v4")
                + self.line("##[group]Run python3 -I - <<'PY'", lane)
                + "".join(self.line(ansi + "36;1m" + line + ansi + "0m", lane)
                          for line in self.source(job).splitlines())
                + self.line("shell: /usr/bin/bash -e {0}", lane)
                + self.line("env:", lane) + self.line("  PR_HEAD_SHA: " + FAKE_HEAD, lane)
                + self.line("##[endgroup]", lane) + self.line(marker, lane)
                + self.line("Finished", lane, "Run tests"))

    def observe(self, logs, *, push=False, attempt=1, prior=None, required=None):
        checker = Consumer()
        checker.slug = "fake/lemon"
        checker.project = types.SimpleNamespace(repository="fake/lemon")
        run = dict(databaseId=101, attempt=attempt, headSha=self.sha,
                   event="push" if push else "pull_request")
        workflow = dict(id=7, path=".github/workflows/ci.yml")
        def gh_json(*args):
            if args[0] == "api":
                number = int(args[1].rsplit("/", 1)[1])
                return dict(id=101, run_attempt=number, head_sha=self.sha, workflow_id=7,
                            event=run["event"], path=workflow["path"],
                            repository=dict(full_name="fake/lemon"), status="completed", conclusion="success",
                            pull_requests=[dict(number=42, head=dict(sha=FAKE_HEAD), base=dict(sha=FAKE_BASE))])
            number = int(args[args.index("--attempt") + 1])
            selected = logs if number == attempt else prior
            return dict(jobs=[dict(databaseId=i, name=name, status="completed", conclusion="success")
                              for i, name in enumerate(selected)])
        def gh(*args):
            number = int(args[args.index("--attempt") + 1])
            selected = logs if number == attempt else prior
            return types.SimpleNamespace(stdout=list(selected.values())[int(args[args.index("--job") + 1])])
        checker._gh_json, checker._gh = gh_json, gh
        return checker._observe(dict(pr_number=42, head_sha=FAKE_HEAD, detail=dict(main_sha=FAKE_BASE)),
                                run, workflow, scope="main" if push else "pr",
                                required_checks=required or list(logs))

    def test_every_job_produces_trusted_actual_identity(self):
        self.assertEqual(set(JOBS), {"changes", "check", "test", "dialyzer", "sim-bench", "install",
                                    "clients", "wasm-runtime", "history", "result"})
        for job in JOBS:
            lanes = ["test (1/1)", *[f"test ({i}/4)" for i in range(1, 5)]] if job == "test" else [
                {"result": "CI result", "history": "Reject unrelated history"}.get(job, job)]
            for lane in lanes:
                with self.subTest(job=job, lane=lane):
                    marker = self.produce(job)
                    for ansi in ("\x1b[", "^[["):
                        log = self.log(marker, lane, job, ansi)
                        self.assertEqual(Consumer()._checkout_identity(log, lane=lane), self.identity)
                        self.assertEqual(self.observe({lane: log})["classification"], "green")

    def test_push_and_skipped_optional_lanes(self):
        marker = self.produce(push=True)
        self.assertEqual(self.observe({"CI result": self.log(marker)}, push=True)["classification"], "green")
        # Skipped optional jobs are not required lanes; the always-running summary attests.
        self.assertIn("if: always()", JOBS["result"])
        self.assertIn("success|skipped) ;;", JOBS["result"])

    def test_partial_rerun_uses_original_attempt_identity(self):
        prior = {"test (1/4)": self.log(self.produce("test"), "test (1/4)", "test")}
        current = {"CI result": self.log(self.produce(attempt=2))}
        result = self.observe(current, attempt=2, prior=prior, required=["CI result", "test (1/4)"])
        self.assertEqual(result["classification"], "green")
        self.assertEqual({lane["attempt"] for lane in result["lanes"]}, {1, 2})
        with self.assertRaises(CIWaiting):
            self.observe({"CI result": self.log(self.produce())}, attempt=2)

    def test_wrong_identity_fields_are_rejected(self):
        for key, wrong in dict(tested_sha="z" * 40, pr_head_sha="d" * 40,
                               base_sha="e" * 40, run_id=102, attempt=2).items():
            with self.subTest(key=key), self.assertRaises(CIWaiting):
                self.observe({"CI result": self.log(MARKER + json.dumps({**self.identity, key: wrong}))})
        with self.assertRaises(CIWaiting):
            self.observe({"CI result": self.log(MARKER + json.dumps({**self.identity, "tested_sha": "d" * 40}))}, push=True)
        with self.assertRaises(CIWaiting):
            self.observe({"CI result": self.log(self.produce()),
                          "check": self.log(MARKER + json.dumps({**self.identity, "tested_sha": "d" * 40}), "check", "check")})

    def test_untrusted_logs_are_rejected(self):
        marker = self.produce()
        log = self.log(marker)
        cases = [log + self.line(marker), log + self.line(marker, step="Run tests"),
                 self.line("untrusted", step="BEAM setup") + log,
                 log.replace("python3 -I -", "python3 -"),
                 log.replace("##[endgroup]", marker), marker,
                 log.replace("CI result\t", "other\t"),
                 log.replace("2026-01-01T00:00:02.0000000Z ", ""),
                 log + self.line(self.line(marker).strip(), step="Run tests"),
                 log.replace(STEP, "Run tests"),
                 log + self.line("FACTORY_CI_IDENTITY=not-json")]
        for index, case in enumerate(cases):
            with self.subTest(case=index), self.assertRaises(CIWaiting):
                Consumer()._checkout_identity(case, lane="CI result")

    def test_repository_and_pythonpath_imports_are_ignored(self):
        for module in ("json", "os", "subprocess", "sitecustomize", "usercustomize"):
            (self.root / (module + ".py")).write_text(
                'from pathlib import Path\nPath("untrusted-import").touch()\nraise RuntimeError("untrusted")\n')
        self.assertEqual(json.loads(self.produce()[len(MARKER):]), self.identity)
        self.assertFalse((self.root / "untrusted-import").exists())


if __name__ == "__main__":
    unittest.main()
