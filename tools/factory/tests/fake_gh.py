#!/usr/bin/env python3
"""Minimal `gh` stand-in for integrator tests: PRs and merges act on a local bare
origin (FAKE_GH_ORIGIN); workflow runs are whatever the test injects into the
JSON state file (FAKE_GH_STATE)."""

from __future__ import annotations

import json
import os
import subprocess
import sys

STATE = os.environ["FAKE_GH_STATE"]
ORIGIN = os.environ["FAKE_GH_ORIGIN"]


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", ORIGIN, *args], check=True, capture_output=True, text=True).stdout.strip()


def load() -> dict:
    with open(STATE) as handle:
        return json.load(handle)


def save(state: dict) -> None:
    with open(STATE, "w") as handle:
        json.dump(state, handle)


def opt(args: list[str], name: str) -> str | None:
    return args[args.index(name) + 1] if name in args else None


def view(pr: dict, fields: str) -> dict:
    head = git("rev-parse", f"refs/heads/{pr['head']}") if pr["state"] == "OPEN" else pr["head_oid"]
    full = {"number": pr["number"], "state": pr["state"], "headRefOid": head,
            "mergeCommit": {"oid": pr["merge"]} if pr.get("merge") else None}
    return {k: full[k] for k in fields.split(",")}


def main(args: list[str]) -> int:
    state = load()
    state.setdefault("calls", []).append(args)
    prs = state.setdefault("prs", [])
    if args[:2] == ["pr", "create"]:
        number = len(prs) + 1
        prs.append({"number": number, "head": opt(args, "--head"), "state": "OPEN", "title": opt(args, "--title")})
        save(state)
        print(f"https://example.invalid/pull/{number}")
        return 0
    if args[:2] == ["pr", "view"]:
        key = args[2]
        pr = next((p for p in reversed(prs) if str(p["number"]) == key or p["head"] == key), None)
        save(state)
        if pr is None:
            print("no pull requests found", file=sys.stderr)
            return 1
        print(json.dumps(view(pr, opt(args, "--json"))))
        return 0
    if args[:2] == ["pr", "merge"]:
        pr = next(p for p in prs if str(p["number"]) == args[2])
        head = git("rev-parse", f"refs/heads/{pr['head']}")
        if head != opt(args, "--match-head-commit"):
            save(state)
            print("head commit mismatch", file=sys.stderr)
            return 1
        merged = subprocess.run(["git", "-C", ORIGIN, "merge-tree", "--write-tree", "main", head],
                                capture_output=True, text=True)
        if merged.returncode != 0:
            save(state)
            print("Pull request is not mergeable: merge conflict", file=sys.stderr)
            return 1
        tree = merged.stdout.split()[0]
        main_sha = git("rev-parse", "main")
        commit = git("commit-tree", tree, "-p", main_sha, "-p", head, "-m", f"Merge pull request #{pr['number']}")
        git("update-ref", "refs/heads/main", commit)
        pr.update(state="MERGED", merge=commit, head_oid=head)
        save(state)
        return 0
    if args[:2] == ["run", "list"]:
        runs = state.get("runs", [])
        branch, commit = opt(args, "--branch"), opt(args, "--commit")
        runs = [r for r in runs if (branch is None or r.get("branch") == branch) and
                (commit is None or r["headSha"] == commit)]
        save(state)
        print(json.dumps([{k: r[k] for k in opt(args, "--json").split(",")} for r in runs]))
        return 0
    if args[:2] == ["run", "view"]:
        save(state)
        if "--log-failed" in args:
            print("test (1/4)\tRun tests\t** (ExUnit) 1 failure: expected true, got false")
        else:
            print(json.dumps({"jobs": [{"name": "test (1/4)", "conclusion": "failure"}]}))
        return 0
    save(state)
    print(f"fake gh: unsupported {args}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
