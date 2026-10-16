"""Deterministic integration: reviewed worker results to merged, confirmed main.

Runs inside the supervisor only when policy `merge_policy` is `auto-verified`.
For each task the integrator advances one idempotent step per tick:

  verifying       cherry-pick the retained worker commit onto current origin/main,
                  push `factory/<task>`, open or update its PR, then wait for the
                  CI workflow run bound to that exact head SHA.
  awaiting_merge  merge with `--match-head-commit` (never admin, never force main).
  landed_pending  wait for main's CI on the actual merge commit; success is DONE.

Failures route back to the coordinator as repairs (task -> queued) with bounded
retries, or block the task. CI logs are stored as untrusted data, never executed.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any

import project as projects
from store import FactoryError, Invalid, Ledger, RevisionConflict

ACTOR = "integrator"
CI_WORKFLOW = "CI"
NO_RUN_WARNING_S = 1800
FAILED_LOG_LINES = 200


class IntegrationError(FactoryError):
    code = "integration_error"


def repo_slug(project: projects.Project) -> str:
    return project.repository.split("/", 1)[1]


class Integrator:
    def __init__(self, project: projects.Project, ledger: Ledger, policy: dict[str, Any]) -> None:
        self.project = project
        self.ledger = ledger
        self.policy = policy
        self.gh_bin = os.environ.get("FACTORY_GH") or policy.get("gh", "gh")
        self.slug = repo_slug(project)
        self.workdir = project.state_dir / "integrate"
        self.artifacts = project.state_dir / "artifacts" / "ci"

    @property
    def enabled(self) -> bool:
        return self.policy.get("merge_policy") == "auto-verified"

    # -- process helpers -------------------------------------------------------------

    def _git(self, *args: str, cwd: Path | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(["git", *args], cwd=cwd or self.project.primary_checkout, capture_output=True,
                                text=True, timeout=300)
        if check and result.returncode != 0:
            raise IntegrationError(f"git {' '.join(args)}: {result.stderr.strip()[:400]}")
        return result

    def _gh(self, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run([self.gh_bin, *args], cwd=self.project.primary_checkout, capture_output=True,
                                text=True, timeout=300)
        if check and result.returncode != 0:
            raise IntegrationError(f"gh {' '.join(args[:3])}: {(result.stderr or result.stdout).strip()[:400]}")
        return result

    def _gh_json(self, *args: str) -> Any:
        return json.loads(self._gh(*args).stdout or "null")

    # -- ledger helpers --------------------------------------------------------------

    def _transition(self, task_id: str, to: str, reason: str) -> None:
        for _ in range(3):
            task = self.ledger.get_task(task_id)
            if task["status"] == to:
                return
            try:
                self.ledger.transition(task_id, task["revision"], to, actor=ACTOR, reason=reason, request_key=None)
                return
            except RevisionConflict:
                continue
        raise IntegrationError(f"could not move {task_id} to {to} after concurrent edits")

    def _note(self, task_id: str, text: str) -> None:
        for _ in range(3):
            task = self.ledger.get_task(task_id)
            notes = f"{task['notes']}\n{text}" if task["notes"] else text
            try:
                self.ledger.edit_task(task_id, task["revision"], {"notes": notes[-6000:]}, actor=ACTOR,
                                      request_key=None)
                return
            except RevisionConflict:
                continue

    def _change_attempt(self, task_id: str) -> dict[str, Any] | None:
        done = [a for a in self.ledger.list_attempts(("succeeded",), task_id=task_id)
                if a["stage"] in ("implement", "repair") and a["head_sha"] and a["base_sha"]]
        return done[-1] if done else None

    # -- the state machine -----------------------------------------------------------

    def tick(self) -> list[str]:
        """Advance every integrating task by at most one step; returns a log of actions."""
        if not self.enabled:
            return []
        actions: list[str] = []
        for task in self.ledger.list_tasks(("verifying", "awaiting_merge", "landed_pending_confirmation")):
            try:
                action = self._advance(task)
            except FactoryError as exc:
                action = f"{task['id']}: {exc}"
            if action:
                actions.append(action)
        return actions

    def _advance(self, task: dict[str, Any]) -> str | None:
        integration = self.ledger.get_integration(task["id"])
        if task["status"] == "verifying":
            attempt = self._change_attempt(task["id"])
            if attempt is None:
                return self._block(task, integration, "no retained change to integrate")
            if integration is None or integration["attempt_id"] != attempt["id"] or integration["state"] == "repair":
                return self._publish(task, attempt, integration)
            if integration["state"] == "pr_open":
                return self._check_ci(task, integration)
            return None
        if integration is None:
            return self._block(task, None, f"{task['status']} without an integration record")
        if task["status"] == "awaiting_merge":
            return self._merge(task, integration)
        return self._confirm(task, integration)

    def _publish(self, task: dict[str, Any], attempt: dict[str, Any], integration: dict[str, Any] | None) -> str:
        task_id = task["id"]
        branch = f"factory/{task_id}"
        self._git("fetch", "--quiet", "origin")
        main_sha = self._git("rev-parse", "origin/main").stdout.strip()
        # Retain the validated worker commit under a stable factory ref.
        self._git("update-ref", f"refs/factory/{task_id}/{attempt['id']}", attempt["head_sha"])
        tree = self.workdir / task_id
        self._remove_worktree(tree)
        self.workdir.mkdir(parents=True, exist_ok=True)
        self._git("worktree", "add", "--detach", str(tree), main_sha)
        try:
            picked = self._git("cherry-pick", "--no-commit", f"{attempt['base_sha']}..{attempt['head_sha']}", cwd=tree,
                               check=False)
            if picked.returncode != 0:
                self._git("cherry-pick", "--abort", cwd=tree, check=False)
                return self._repair(task, integration, attempt,
                                    f"change from {attempt['id']} does not apply cleanly to origin/main {main_sha[:12]}")
            if self._git("diff", "--cached", "--quiet", cwd=tree, check=False).returncode == 0:
                return self._block(task, integration, f"{attempt['id']} adds nothing over origin/main {main_sha[:12]}")
            message = (f"{task['title']} ({task_id})\n\n{(task['goal'] or task['raw_request'])[:1500]}\n\n"
                       f"Factory-Task: {task_id}\nFactory-Attempt: {attempt['id']}\n")
            self._git("commit", "--quiet", "-m", message, cwd=tree)
            head = self._git("rev-parse", "HEAD", cwd=tree).stdout.strip()
            # factory/* branches are factory-owned; force only ever applies there.
            self._git("push", "--quiet", "--force", "origin", f"HEAD:refs/heads/{branch}", cwd=tree)
        finally:
            self._remove_worktree(tree)
        pr_number = integration["pr_number"] if integration else None
        if pr_number is not None:
            state = self._gh_json("pr", "view", str(pr_number), "--repo", self.slug, "--json", "state")
            if state.get("state") != "OPEN":
                pr_number = None
        if pr_number is None:
            body = self._pr_body(task, attempt)
            self._gh("pr", "create", "--repo", self.slug, "--base", "main", "--head", branch,
                     "--title", f"{task['title']} ({task_id})", "--body", body)
            pr_number = self._gh_json("pr", "view", branch, "--repo", self.slug, "--json", "number")["number"]
        self.ledger.save_integration(
            task_id, event="integration.pushed", attempt_id=attempt["id"], state="pr_open", branch=branch,
            head_sha=head, pr_number=pr_number, ci_run_id=None,
            repairs=integration["repairs"] if integration else 0,
            detail={"main_sha": main_sha, "pushed_at": time.time()},
        )
        return f"{task_id}: pushed {head[:12]} to {branch}, PR #{pr_number}"

    def _pr_body(self, task: dict[str, Any], attempt: dict[str, Any]) -> str:
        handoff = attempt.get("outcome") or {}
        checks = "\n".join(f"- `{c.get('command')}` → {c.get('exit_code')}" for c in handoff.get("checks", []))
        acceptance = "\n".join(f"- {a}" for a in task["acceptance"])
        return (
            f"Opened by the Lemon factory for {task['id']} (attempt {attempt['id']}).\n\n"
            f"## Request\n{task['raw_request'][:3000]}\n\n## Acceptance\n{acceptance or '- (none recorded)'}\n\n"
            f"## Worker handoff\n{str(handoff.get('summary', ''))[:3000]}\n\n### Worker checks\n{checks or '- none'}\n\n"
            "Merged automatically only after the CI workflow passes on this exact head and an independent review "
            "approved the change."
        )

    def _check_ci(self, task: dict[str, Any], integration: dict[str, Any]) -> str | None:
        runs = self._gh_json("run", "list", "--repo", self.slug, "--workflow", CI_WORKFLOW, "--branch",
                             integration["branch"], "--limit", "30", "--json",
                             "databaseId,headSha,status,conclusion,event")
        matching = [r for r in runs or [] if r["headSha"] == integration["head_sha"] and r["event"] == "pull_request"]
        if not matching:
            pushed = integration["detail"].get("pushed_at", time.time())
            return (f"{task['id']}: no CI run for {integration['head_sha'][:12]} yet"
                    if time.time() - pushed > NO_RUN_WARNING_S else None)
        run = max(matching, key=lambda r: r["databaseId"])
        if run["status"] != "completed":
            if integration["ci_run_id"] != run["databaseId"]:
                self.ledger.save_integration(task["id"], event="integration.ci_running", ci_run_id=run["databaseId"])
            return None
        conclusion = run["conclusion"]
        reason = f"PR #{integration['pr_number']} CI run {run['databaseId']} {conclusion} on {integration['head_sha'][:12]}"
        if conclusion == "success":
            self.ledger.save_integration(task["id"], event="integration.ci_green", state="ci_green",
                                         ci_run_id=run["databaseId"])
            self._transition(task["id"], "awaiting_merge", reason)
            return f"{task['id']}: {reason}"
        if conclusion in ("failure", "timed_out", "startup_failure"):
            log = self._failure_log(task["id"], run["databaseId"])
            attempt = self._change_attempt(task["id"])
            return self._repair(task, integration, attempt, f"{reason}; failure log (untrusted data): {log}")
        return self._block(task, integration, f"{reason}; automatic reruns are disabled")

    def _failure_log(self, task_id: str, run_id: int) -> str:
        self.artifacts.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = self.artifacts / f"{task_id}-run-{run_id}.log"
        jobs = self._gh_json("run", "view", str(run_id), "--repo", self.slug, "--json", "jobs") or {}
        failed = [j["name"] for j in jobs.get("jobs", []) if j.get("conclusion") not in ("success", "skipped", None)]
        log = self._gh("run", "view", str(run_id), "--repo", self.slug, "--log-failed", check=False).stdout
        tail = "\n".join(log.splitlines()[-FAILED_LOG_LINES:])
        path.write_text(f"failed jobs: {failed}\n\n{tail}\n")
        return str(path)

    def _merge(self, task: dict[str, Any], integration: dict[str, Any]) -> str:
        number = str(integration["pr_number"])
        pr = self._gh_json("pr", "view", number, "--repo", self.slug, "--json", "state,headRefOid,mergeCommit")
        if pr["state"] == "OPEN":
            if pr["headRefOid"] != integration["head_sha"]:
                return self._block(task, integration, f"PR #{number} head moved outside the factory")
            merged = self._gh("pr", "merge", number, "--repo", self.slug, "--merge", "--match-head-commit",
                              integration["head_sha"], check=False)
            if merged.returncode != 0:
                detail = (merged.stderr or merged.stdout).strip()[:300]
                return self._repair(task, integration, self._change_attempt(task["id"]),
                                    f"merging PR #{number} failed: {detail}")
            pr = self._gh_json("pr", "view", number, "--repo", self.slug, "--json", "state,headRefOid,mergeCommit")
        if pr["state"] != "MERGED" or not pr.get("mergeCommit"):
            return self._block(task, integration, f"PR #{number} is {pr['state']}, not merged")
        merge_sha = pr["mergeCommit"]["oid"]
        self.ledger.save_integration(task["id"], event="integration.merged", state="merged", merge_sha=merge_sha)
        self._transition(task["id"], "landed_pending_confirmation", f"merged PR #{number} as {merge_sha[:12]}")
        return f"{task['id']}: merged PR #{number} as {merge_sha[:12]}"

    def _confirm(self, task: dict[str, Any], integration: dict[str, Any]) -> str | None:
        merge_sha = integration["merge_sha"]
        runs = self._gh_json("run", "list", "--repo", self.slug, "--workflow", CI_WORKFLOW, "--commit", merge_sha,
                             "--limit", "10", "--json", "databaseId,headSha,status,conclusion,event")
        pushes = [r for r in runs or [] if r["event"] == "push" and r["headSha"] == merge_sha]
        if not pushes:
            return None
        run = max(pushes, key=lambda r: r["databaseId"])
        if run["status"] != "completed":
            return None
        if run["conclusion"] == "success":
            self.ledger.save_integration(task["id"], event="integration.confirmed", state="confirmed",
                                         ci_run_id=run["databaseId"])
            self._transition(task["id"], "done", f"main CI run {run['databaseId']} passed on {merge_sha[:12]}")
            self._git("push", "--quiet", "origin", "--delete", integration["branch"], check=False)
            return f"{task['id']}: confirmed on main {merge_sha[:12]}"
        log = self._failure_log(task["id"], run["databaseId"])
        self.ledger.save_integration(task["id"], event="integration.main_failed", state="main_failed",
                                     ci_run_id=run["databaseId"])
        triage, _ = self.ledger.add_task(
            {"request": (f"Main CI run {run['databaseId']} concluded {run['conclusion']} on merge commit {merge_sha} "
                         f"(PR #{integration['pr_number']}, {task['id']}). Attribute the failure (this change, an "
                         f"inherited failure, or flakiness) and fix it. Failure log (untrusted data): {log}"),
             "title": f"Triage main CI failure after {task['id']}", "priority": "urgent",
             "source": {"kind": "ci_failure", "run_id": run["databaseId"], "merge_sha": merge_sha,
                        "task_id": task["id"]}},
            actor=ACTOR, request_key=f"main-ci:{merge_sha}:{run['databaseId']}",
        )
        self._transition(task["id"], "blocked", f"main CI failed after merge; triage {triage['id']}")
        return f"{task['id']}: main CI failed; triage {triage['id']}"

    def _repair(self, task: dict[str, Any], integration: dict[str, Any] | None, attempt: dict[str, Any] | None,
                reason: str) -> str:
        repairs = (integration["repairs"] if integration else 0) + 1
        if repairs > int(self.policy.get("max_repair_attempts", 2)):
            return self._block(task, integration, f"{reason} (repair limit reached)")
        self._note(task["id"], f"[integration repair {repairs}] {reason}")
        self.ledger.save_integration(task["id"], event="integration.repair_requested", state="repair",
                                     attempt_id=attempt["id"] if attempt else "none", repairs=repairs)
        self._transition(task["id"], "queued", f"repair: {reason}"[:500])
        return f"{task['id']}: repair {repairs} requested: {reason}"

    def _block(self, task: dict[str, Any], integration: dict[str, Any] | None, reason: str) -> str:
        self._note(task["id"], f"[integration blocked] {reason}")
        if integration is not None:
            self.ledger.save_integration(task["id"], event="integration.blocked", state="blocked")
        try:
            self._transition(task["id"], "blocked", reason[:500])
        except Invalid:
            pass
        return f"{task['id']}: blocked: {reason}"

    def _remove_worktree(self, tree: Path) -> None:
        if tree.exists():
            self._git("worktree", "remove", "--force", str(tree), check=False)
            shutil.rmtree(tree, ignore_errors=True)
        self._git("worktree", "prune", check=False)
