#!/usr/bin/env python3
"""Run #555's baseline and demand an assertion kill for every source mutant.

Run only in an idle worktree: each mutant temporarily patches one production file.
All original bytes are restored, including on SIGINT/SIGTERM or a failed command.
No git state, dependency manifests, or unrelated source files are changed.
"""

import os
from pathlib import Path
import re
import signal
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
CODING_TEST = "apps/coding_agent/test/coding_agent/session/crash_model_test.exs"
ROUTER_TEST = "apps/lemon_router/test/lemon_router/crash_model_test.exs"
OUTBOX_TEST = "apps/lemon_channels/test/lemon_channels/outbox_crash_model_test.exs"
SESSION_MANAGER = "apps/coding_agent/lib/coding_agent/session_manager.ex"
PERSISTENCE = "apps/coding_agent/lib/coding_agent/session/persistence.ex"
MUTATIONS = [
    (
        "JournalPrefix",
        SESSION_MANAGER,
        "when not complete? ->\n          {:halt, {:ok, state}}",
        "when not complete? ->\n          {:halt, {:error, :mutated_torn_tail}}",
        CODING_TEST,
    ),
    (
        "TranscriptValid",
        PERSISTENCE,
        "if repairable_missing_results?(violations) do",
        "if not repairable_missing_results?(violations) do",
        CODING_TEST,
    ),
    (
        "IntentTruth",
        PERSISTENCE,
        "started: MapSet.member?(intents, tool_call_id)",
        "started: not MapSet.member?(intents, tool_call_id)",
        CODING_TEST,
    ),
    (
        "FinishOnce",
        "apps/lemon_router/lib/lemon_router/session_transitions.ex",
        "|> Map.put(:active, nil)",
        "|> Map.put(:active, state.active)",
        ROUTER_TEST,
    ),
    (
        "ReplayOnce",
        "apps/lemon_router/lib/lemon_router/restart_carryover.ex",
        "case submit.(item.request) do",
        "case submit.(Map.put(item.request, :run_id, LemonCore.Id.run_id())) do",
        ROUTER_TEST,
    ),
    (
        "OutboxKeys",
        "apps/lemon_channels/lib/lemon_channels/outbox/queue_store.ex",
        'entry.payload.idempotency_key || "outbox:#{entry.durable_id}"',
        'entry.payload.idempotency_key || "mutated:#{entry.durable_id}"',
        OUTBOX_TEST,
    ),
]


def run_tests(paths):
    command = ["mix", "test", *paths, "--seed", "1", "--exclude", "integration"]
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(
        command,
        cwd=ROOT,
        env={**os.environ, "MIX_ENV": "test"},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=180,
        check=False,
    )
    print(result.stdout, end="", flush=True)
    return result


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def main():
    signal.signal(signal.SIGTERM, interrupt)
    baseline = run_tests([CODING_TEST, ROUTER_TEST, OUTBOX_TEST])
    if baseline.returncode != 0:
        sys.exit("Baseline failed; no mutation evidence is valid.")

    for name, relative, needle, replacement, test in MUTATIONS:
        path = ROOT / relative
        original = path.read_bytes()
        source = original.decode()
        if source.count(needle) != 1:
            sys.exit(f"{name}: expected exactly one mutation anchor in {relative}")
        mutated = source.replace(needle, replacement).encode()
        try:
            path.write_bytes(mutated)
            result = run_tests([test])
        finally:
            # Never overwrite edits made concurrently by a human/another process.
            current = path.read_bytes()
            if current == mutated:
                path.write_bytes(original)
            elif current != original:
                raise RuntimeError(f"Concurrent edit in {relative}; restore its mutation manually")

        assertion_kill = (
            result.returncode != 0
            and f"{name}:" in result.stdout
            and re.search(r"\d+\) test ", result.stdout)
            and re.search(
                r"(?:\d+ tests?, [1-9]\d* failures?|Failed: [1-9]\d* tests?)",
                result.stdout,
            )
        )
        if not assertion_kill:
            sys.exit(f"{name}: survived, or failed outside its invariant assertion")
        print(f"KILLED {name}: named invariant assertion failed", flush=True)

    # Recompile restored source too: do not leave mutated BEAMs for later tests.
    restored = run_tests([CODING_TEST, ROUTER_TEST, OUTBOX_TEST])
    if restored.returncode != 0:
        sys.exit("Restored baseline failed")
    print("PASS: baseline, six assertion-killed mutants, restored baseline", flush=True)


if __name__ == "__main__":
    main()
