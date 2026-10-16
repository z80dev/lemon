"""Integrator: exact-head CI gating, merge, main confirmation and repair routing.

GitHub is replaced by tests/fake_gh.py acting on a local bare origin; git is real.
"""

from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path

from .helpers import FACTORY_DIR, FactoryHome, git

sys.path.insert(0, str(FACTORY_DIR))

import project as projects  # noqa: E402
from integrator import Integrator  # noqa: E402
from store import Ledger  # noqa: E402

FAKE_GH = Path(__file__).with_name("fake_gh.py")
POLICY = {"merge_policy": "auto-verified", "max_repair_attempts": 2}


class IntegratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.home = FactoryHome()
        self.home.cli("register")
        git(self.home.repo, "remote", "set-url", "origin", str(self.home.origin))
        self.state = self.home.root / "gh.json"
        self.state.write_text("{}")
        self.saved_env = {k: os.environ.get(k) for k in ("FACTORY_GH", "FAKE_GH_STATE", "FAKE_GH_ORIGIN",
                                                          "FACTORY_CONFIG_HOME", "FACTORY_STATE_HOME")}
        os.environ.update(FACTORY_GH=str(FAKE_GH), FAKE_GH_STATE=str(self.state), FAKE_GH_ORIGIN=str(self.home.origin),
                          FACTORY_CONFIG_HOME=self.home.env["FACTORY_CONFIG_HOME"],
                          FACTORY_STATE_HOME=self.home.env["FACTORY_STATE_HOME"])
        self.project = projects.resolve(project_id="widget")
        self.ledger = Ledger(self.project.db_path, "widget")
        self.integrator = Integrator(self.project, self.ledger, POLICY)

    def tearDown(self) -> None:
        for key, value in self.saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.home.cleanup()

    # -- helpers ----------------------------------------------------------------------

    def worker_commit(self, name: str, path: str, content: str) -> tuple[str, str]:
        """A retained worker branch on top of the current origin/main, like omp/task/<attempt>."""
        repo = self.home.repo
        git(repo, "fetch", "-q", "origin")
        base = git(repo, "rev-parse", "origin/main")
        git(repo, "checkout", "-q", "-B", f"omp/task/{name}", base)
        (repo / path).write_text(content)
        git(repo, "add", path)
        git(repo, "commit", "-q", "-m", name)
        head = git(repo, "rev-parse", "HEAD")
        git(repo, "checkout", "-q", "main")
        return base, head

    def verifying_task(self, path: str = "feature.txt", content: str = "feature\n") -> str:
        task, _ = self.ledger.add_task({"request": f"change {path}"}, actor="test", request_key=None)
        task_id = task["id"]
        epoch = self.ledger.begin_epoch(1)
        self.ledger.request_mode("running", actor="test")
        self.ledger.update_runtime(mode="running")
        self.ledger.transition(task_id, 1, "queued", actor="test", reason="triaged", request_key=None)
        attempt = self.ledger.reserve_attempt(task_id, 2, "implement", epoch=epoch, actor="test", request_key=None,
                                              base_sha=None)
        base, head = self.worker_commit(attempt["id"], path, content)
        with self.ledger.write() as conn:
            conn.execute("UPDATE attempts SET base_sha = ? WHERE id = ?", (base, attempt["id"]))
        self.ledger.update_attempt(attempt["id"], status="succeeded", actor="test", epoch=epoch, head_sha=head,
                                   branch=f"omp/task/{attempt['id']}", outcome={"summary": "done", "checks": []})
        for to in ("ready", "verifying"):
            rev = self.ledger.get_task(task_id)["revision"]
            self.ledger.transition(task_id, rev, to, actor="test", reason="test", request_key=None)
        return task_id

    def add_run(self, **run: object) -> None:
        state = json.loads(self.state.read_text())
        runs = state.setdefault("runs", [])
        runs.append({"databaseId": len(runs) + 100, "status": "completed", **run})
        self.state.write_text(json.dumps(state))

    def status(self, task_id: str) -> str:
        return self.ledger.get_task(task_id)["status"]

    # -- scenarios --------------------------------------------------------------------

    def test_disabled_without_auto_verified_policy(self) -> None:
        self.verifying_task()
        self.assertEqual(Integrator(self.project, self.ledger, {"merge_policy": "manual"}).tick(), [])

    def test_green_exact_head_merges_and_main_confirmation_completes(self) -> None:
        task_id = self.verifying_task()
        self.integrator.tick()
        integration = self.ledger.get_integration(task_id)
        self.assertEqual((integration["state"], integration["pr_number"]), ("pr_open", 1))
        pushed = git(self.home.origin, "rev-parse", f"refs/heads/factory/{task_id}")
        self.assertEqual(pushed, integration["head_sha"])
        self.assertEqual(git(self.home.origin, "rev-parse", f"{pushed}^"), git(self.home.origin, "rev-parse", "main"))
        self.assertIn(f"Factory-Task: {task_id}", git(self.home.origin, "log", "-1", "--format=%B", pushed))
        # No run yet, then a run for a different head, then a pending run: nothing advances.
        self.integrator.tick()
        self.add_run(branch=f"factory/{task_id}", headSha="0" * 40, event="pull_request", conclusion="success")
        self.add_run(branch=f"factory/{task_id}", headSha=pushed, event="pull_request", status="in_progress",
                     conclusion=None)
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "verifying")
        self.add_run(branch=f"factory/{task_id}", headSha=pushed, event="pull_request", conclusion="success")
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "awaiting_merge")
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "landed_pending_confirmation")
        merge_sha = self.ledger.get_integration(task_id)["merge_sha"]
        self.assertEqual(git(self.home.origin, "rev-parse", "main"), merge_sha)
        self.add_run(headSha=merge_sha, event="push", conclusion="success")
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "done")
        self.assertEqual(git(self.home.origin, "branch", "--list", f"factory/{task_id}"), "")

    def test_ci_failure_routes_a_bounded_repair_with_the_log(self) -> None:
        task_id = self.verifying_task()
        self.integrator.tick()
        head = self.ledger.get_integration(task_id)["head_sha"]
        self.add_run(branch=f"factory/{task_id}", headSha=head, event="pull_request", conclusion="failure")
        self.integrator.tick()
        task = self.ledger.get_task(task_id)
        self.assertEqual(task["status"], "queued")
        self.assertIn("[integration repair 1]", task["notes"])
        log = Path(task["notes"].split("failure log (untrusted data): ")[1].split()[0])
        self.assertIn("1 failure", log.read_text())
        self.assertEqual(self.ledger.get_integration(task_id)["repairs"], 1)

    def test_conflict_with_main_requests_repair_and_limit_blocks(self) -> None:
        task_id = self.verifying_task(path="README.md", content="worker version\n")
        git(self.home.repo, "checkout", "-q", "main")
        (self.home.repo / "README.md").write_text("someone else's version\n")
        git(self.home.repo, "commit", "-q", "-am", "concurrent main change")
        git(self.home.repo, "push", "-q", "origin", "HEAD:main")
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "queued")
        self.assertIn("does not apply cleanly", self.ledger.get_task(task_id)["notes"])
        with self.ledger.write() as conn:  # pretend two repairs already failed the same way
            conn.execute("UPDATE integrations SET repairs = 2 WHERE task_id = ?", (task_id,))
            conn.execute("UPDATE tasks SET status = 'verifying' WHERE id = ?", (task_id,))
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "blocked")

    def test_main_failure_after_merge_blocks_and_opens_one_triage_task(self) -> None:
        task_id = self.verifying_task()
        self.integrator.tick()
        head = self.ledger.get_integration(task_id)["head_sha"]
        self.add_run(branch=f"factory/{task_id}", headSha=head, event="pull_request", conclusion="success")
        self.integrator.tick()
        self.integrator.tick()
        merge_sha = self.ledger.get_integration(task_id)["merge_sha"]
        self.add_run(headSha=merge_sha, event="push", conclusion="failure")
        self.integrator.tick()
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "blocked")
        triage = [t for t in self.ledger.list_tasks() if t["source"].get("kind") == "ci_failure"]
        self.assertEqual(len(triage), 1)
        self.assertEqual((triage[0]["priority"], triage[0]["status"]), ("urgent", "inbox"))

    def test_superseded_main_run_is_confirmed_by_the_next_descendant_run(self) -> None:
        task_id = self.verifying_task()
        self.integrator.tick()
        head = self.ledger.get_integration(task_id)["head_sha"]
        self.add_run(branch=f"factory/{task_id}", headSha=head, event="pull_request", conclusion="success")
        self.integrator.tick()
        self.integrator.tick()
        merge_sha = self.ledger.get_integration(task_id)["merge_sha"]
        self.add_run(branch="main", headSha=merge_sha, event="push", conclusion="cancelled")
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "landed_pending_confirmation")  # waits; no false triage
        git(self.home.repo, "fetch", "-q", "origin")
        git(self.home.repo, "checkout", "-q", "-B", "next", "origin/main")
        (self.home.repo / "later.txt").write_text("later\n")
        git(self.home.repo, "add", "later.txt")
        git(self.home.repo, "commit", "-q", "-m", "later merge")
        git(self.home.repo, "push", "-q", "origin", "HEAD:main")
        later = git(self.home.repo, "rev-parse", "HEAD")
        git(self.home.repo, "checkout", "-q", "main")
        self.add_run(branch="main", headSha="f" * 40, event="push", conclusion="failure")  # unrelated commit
        self.add_run(branch="main", headSha=later, event="push", status="in_progress", conclusion=None)
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "landed_pending_confirmation")
        state = json.loads(self.state.read_text())
        state["runs"][-1].update(status="completed", conclusion="success")
        self.state.write_text(json.dumps(state))
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "done")
        self.assertFalse([t for t in self.ledger.list_tasks() if t["source"].get("kind") == "ci_failure"])

    def test_merge_refuses_a_head_moved_outside_the_factory(self) -> None:
        task_id = self.verifying_task()
        self.integrator.tick()
        head = self.ledger.get_integration(task_id)["head_sha"]
        self.add_run(branch=f"factory/{task_id}", headSha=head, event="pull_request", conclusion="success")
        self.integrator.tick()
        git(self.home.origin, "update-ref", f"refs/heads/factory/{task_id}", f"{head}^")
        self.integrator.tick()
        self.assertEqual(self.status(task_id), "blocked")
        self.assertNotEqual(git(self.home.origin, "rev-parse", "main"), head)


if __name__ == "__main__":
    unittest.main()
