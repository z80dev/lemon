"""Operator-only single tiny synthetic live request. Never called by tests/replay.

Run only within an explicitly authorized paid-request allowance. This command
makes at most ONE classification POST (no retries), after catalog verification.
"""
from __future__ import annotations

import argparse
import json

from .adapter import DecisionAdapter
from .config import DecisionConfig


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live", action="store_true", help="explicitly authorize one synthetic paid request")
    args = parser.parse_args(argv)
    if not args.live:
        parser.error("--live is required; no request made")
    config = DecisionConfig(max_retries=0, deadline_s=20, max_input_bytes=512)
    receipt = DecisionAdapter(config).classify({
        "id": "SYNTHETIC-SMOKE", "revision": 1,
        "goal": "Correct one spelling mistake in a synthetic documentation fixture.",
        "acceptance": ["Only the spelling changes."],
        "evidence": [{"path": "synthetic.txt", "summary": "Single word typo, no executable code."}],
    })
    # No task text, provider free text, credentials, headers or generation IDs.
    evidence = {"model": config.model, "endpoint_path": "/api/v1/systemone",
                "status": receipt["status"], "http_status": receipt["http_status"],
                "latency_ms": receipt["latency_ms"], "usage": receipt["usage"],
                "error_class": receipt["error_class"],
                "protocol_verified": receipt["status"] == "available"}
    print(json.dumps(evidence, sort_keys=True, allow_nan=False))
    return 0 if receipt["status"] == "available" else 1


if __name__ == "__main__":
    raise SystemExit(main())
