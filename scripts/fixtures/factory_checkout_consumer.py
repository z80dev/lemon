"""Read-only consumer snapshot for hosted producer contract tests.

Verbatim methods from software-factory integrator.py, release/source SHA
 e49a5e879ddeede78033e1372e07b7dff41b5a6b (not Lemon runtime code).
Update only against the installed consumer; never relax its checks here.
"""
from __future__ import annotations
import json
from typing import Any

class CIWaiting(Exception):
    pass

class Integrator:
    def _checkout_identity(self, log: str, *, lane: str) -> dict[str, Any]:
        """Accept only the isolated, early identity step in a prefixed job log."""
        step = "Record tested checkout identity"
        marker = "FACTORY_CI_IDENTITY="
        preceding = {"Set up job", "Run actions/checkout@v4", "actions/checkout@v4"}
        entered = ended = command = group_closed = False
        identities: list[dict[str, Any]] = []
        for line in log.splitlines():
            fields = line.split("\t", 2)
            if len(fields) != 3 or fields[0] != lane:
                raise CIWaiting("CI checkout log lacks trusted job and step prefixes")
            name, stamped = fields[1:]
            timestamp, separator, message = stamped.partition(" ")
            # gh preserves the runner's UTC timestamp before each log message.
            if (not separator or not timestamp.endswith("Z") or "T" not in timestamp
                    or len(timestamp) < 20):
                raise CIWaiting("CI checkout log lacks a runner timestamp")
            if name == step:
                if ended:
                    raise CIWaiting("CI checkout identity step is repeated")
                entered = True
                if message.startswith("##[group]"):
                    if command or message != "##[group]Run python3 -I - <<'PY'":
                        raise CIWaiting("CI checkout identity command is not isolated")
                    command = True
                elif message == "##[endgroup]":
                    if not command or group_closed:
                        raise CIWaiting("CI checkout identity command group is malformed")
                    group_closed = True
            elif entered:
                ended = True
            elif name not in preceding:
                raise CIWaiting("CI checkout identity follows an untrusted step")
            if marker not in message:
                continue
            # The runner echoes the Python source inside its command group.
            source_echo = message
            for cyan, reset in (("\x1b[36;1m", "\x1b[0m"), ("^[[36;1m", "^[[0m")):
                if source_echo.startswith(cyan) and source_echo.endswith(reset):
                    source_echo = source_echo[len(cyan):-len(reset)]
                    break
            if (name == step and command and not group_closed
                    and source_echo.strip().startswith('print("FACTORY_CI_IDENTITY=" + json.dumps({')):
                continue
            if (name != step or not command or not group_closed
                    or not message.startswith(marker)):
                raise CIWaiting("CI checkout identity marker is outside trusted step output")
            try:
                identity = json.loads(message[len(marker):])
            except ValueError as exc:
                raise CIWaiting("CI checkout identity is malformed") from exc
            if not isinstance(identity, dict):
                raise CIWaiting("CI checkout identity is malformed")
            identities.append(identity)
        if not command or not group_closed or len(identities) != 1:
            raise CIWaiting("CI job lacks one trusted checkout identity")
        return identities[0]

    def _observe(self, integration: dict[str, Any], run: dict[str, Any], workflow: dict[str, Any],
                 *, scope: str, required_checks: list[str] | None = None) -> dict[str, Any]:
        """Read one immutable run attempt, not the moving 'latest attempt' endpoint."""
        raw = self._gh_json("api", f"repos/{self.slug}/actions/runs/{run['databaseId']}/attempts/{run['attempt']}")
        if (raw.get("id") != run["databaseId"] or raw.get("run_attempt") != run["attempt"]
                or raw.get("head_sha") != run["headSha"] or raw.get("workflow_id") != workflow["id"]
                or raw.get("event") != run["event"] or raw.get("path") != workflow["path"]
                or raw.get("repository", {}).get("full_name", "").lower() != self.slug.lower()):
            raise CIWaiting("CI run identity is incomplete or changed during observation")
        base = integration["detail"].get("ci_evidence", {}).get("base_sha", integration["detail"].get("main_sha"))
        if scope == "pr":
            identities = [pr for pr in raw.get("pull_requests") or []
                          if pr.get("number") == integration["pr_number"]
                          and pr.get("head", {}).get("sha") == integration["head_sha"]]
            if len(identities) != 1 or not identities[0].get("base", {}).get("sha"):
                raise CIWaiting("CI run does not bind this PR head and base")
            base = identities[0]["base"]["sha"]
        jobs = self._gh_json("run", "view", str(run["databaseId"]), "--attempt", str(run["attempt"]),
                             "--repo", self.slug, "--json", "jobs") or {}
        lanes = [{"id": job["databaseId"], "name": job["name"], "status": job.get("status"),
                  "conclusion": job.get("conclusion"), "attempt": run["attempt"]}
                 for job in jobs.get("jobs", [])]
        required = self._required_ci_checks() if required_checks is None else required_checks
        required_lanes = [lane for lane in lanes if lane["name"] in required]
        complete_lanes = all(sum(lane["name"] == name for lane in lanes) == 1 for name in required)
        tested_sha = None
        for lane in required_lanes:
            if lane["status"] != "completed":
                continue
            log = self._gh("run", "view", str(run["databaseId"]), "--job", str(lane["id"]),
                           "--attempt", str(run["attempt"]), "--repo", self.slug, "--log").stdout
            identity = self._checkout_identity(log, lane=lane["name"])
            sha = identity.get("tested_sha")
            if (identity.get("run_id") != run["databaseId"] or identity.get("attempt") != run["attempt"]
                    or not isinstance(sha, str) or len(sha) != 40
                    or any(char not in "0123456789abcdef" for char in sha)
                    or (scope == "pr" and (identity.get("pr_head_sha") != integration["head_sha"]
                                          or identity.get("base_sha") != base))
                    or (scope != "pr" and sha != raw["head_sha"])
                    or (tested_sha is not None and tested_sha != sha)):
                raise CIWaiting("CI checkout identity does not bind this exact run attempt")
            tested_sha = sha
        # Failed-job reruns omit lanes that passed in an earlier attempt. Resolve
        # only missing lanes within this exact run, never from another head/run.
        missing = set(required) - {lane["name"] for lane in lanes}
        if missing and run["attempt"] > 1:
            prior_run = {**run, "attempt": run["attempt"] - 1}
            prior = self._observe(integration, prior_run, workflow, scope=scope,
                                  required_checks=sorted(missing))
            if (prior["base_sha"] != base or prior["api_head_sha"] != raw["head_sha"]
                    or (tested_sha is not None and prior["tested_sha"] is not None
                        and prior["tested_sha"] != tested_sha)):
                raise CIWaiting("CI rerun checkout identity differs from its earlier attempt")
            lanes.extend(lane for lane in prior["lanes"] if lane["name"] in missing)
            tested_sha = tested_sha or prior["tested_sha"]
            required_lanes = [lane for lane in lanes if lane["name"] in required]
            complete_lanes = all(sum(lane["name"] == name for lane in lanes) == 1 for name in required)
        status, conclusion = raw.get("status"), raw.get("conclusion")
        classification = "waiting"
        if status == "completed":
            if conclusion == "success":
                if (complete_lanes and tested_sha and all(j["status"] == "completed"
                        and j["conclusion"] == "success" for j in required_lanes)):
                    classification = "green"
            elif conclusion in ("failure", "timed_out", "startup_failure"):
                classification = "failure"
            elif conclusion == "cancelled":
                classification = "cancelled"
            else:
                classification = "inconclusive"
        return {"repository": self.project.repository, "pr_number": integration["pr_number"],
                "pr_head_sha": integration["head_sha"], "base_sha": base, "tested_sha": tested_sha,
                "api_head_sha": raw["head_sha"], "required_ci_checks": required,
                "workflow": workflow, "run_id": raw["id"], "attempt": raw["run_attempt"], "scope": scope,
                "event": raw["event"], "status": status, "conclusion": conclusion, "lanes": lanes,
                "classification": classification}
