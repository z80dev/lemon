"""Offline replay of recorded decision recommendations.

Compares sanitized, pre-recorded complexity recommendations with the model the
factory actually used and (optionally) the later review/repair outcome.  The
result counts agreement only.  It is NOT an accuracy, ground-truth or
calibration measurement: the actual model is a human/policy choice, not a label.

This module never imports the adapter, never touches the network and never
reads credentials.  Inputs are strictly validated and bounded; error messages
name the row index and field but never echo input values.

Run: ``PYTHONPATH=tools/factory python3 -m decision.replay [--input FILE]``
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from itertools import islice
from pathlib import Path
from typing import Any, Iterable

MAX_INPUT_BYTES = 1_000_000
MAX_RECORDS = 1000
MAX_TIER_MODELS = 64
MAX_REPAIR_COUNT = 1000
STATUSES = ("available", "unavailable", "invalid", "off")
EXAMPLES_PATH = Path(__file__).with_name("replay_examples.json")
DISCLAIMER = (
    "Agreement between a recorded recommendation and the recorded actual model only. "
    "Not accuracy, not ground truth, not calibration."
)

_TASK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
CHOICES = ("simple", "standard", "complex", "insufficient_information")
ROUTABLE_CHOICES = ("simple", "standard", "complex")
_MODEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$")
_REVIEW = re.compile(r"^[a-z][a-z0-9_]{0,31}$")
_RECORD_KEYS = {"task_id", "recommendation", "actual_model", "outcome", "label"}
_REC_KEYS = {"status", "choice", "uncertainty"}
_OUTCOME_KEYS = {"review", "repair_count"}
_MAX_LABEL = 160


class ReplayError(ValueError):
    """Invalid replay input. The message never contains input values."""


def _reject_constant(_name: str) -> Any:
    raise ReplayError("non-finite number in input")


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _token(value: Any, pattern: re.Pattern[str], where: str) -> str:
    if not isinstance(value, str) or not pattern.match(value):
        raise ReplayError(f"{where}: invalid value")
    return value


def _validate_tier_models(tier_models: Any) -> dict[str, str]:
    if tier_models is None:
        return {}
    if not isinstance(tier_models, dict):
        raise ReplayError("tier_models: must be an object")
    if len(tier_models) > MAX_TIER_MODELS:
        raise ReplayError("tier_models: too many entries")
    out: dict[str, str] = {}
    for choice, model in tier_models.items():
        if not isinstance(choice, str) or choice not in ROUTABLE_CHOICES:
            raise ReplayError("tier_models key: not a routable choice")
        out[choice] = _token(model, _MODEL, "tier_models value")
    return out


def _validate_record(index: int, raw: Any) -> dict[str, Any]:
    where = f"record[{index}]"
    if not isinstance(raw, dict):
        raise ReplayError(f"{where}: must be an object")
    if set(raw) - _RECORD_KEYS:
        raise ReplayError(f"{where}: unexpected field")
    if "task_id" not in raw or "recommendation" not in raw:
        raise ReplayError(f"{where}: missing required field")
    task_id = _token(raw["task_id"], _TASK_ID, f"{where}.task_id")

    rec = raw["recommendation"]
    if not isinstance(rec, dict):
        raise ReplayError(f"{where}.recommendation: must be an object")
    if set(rec) - _REC_KEYS:
        raise ReplayError(f"{where}.recommendation: unexpected field")
    status = rec.get("status")
    if status not in STATUSES:
        raise ReplayError(f"{where}.recommendation.status: invalid value")
    choice = rec.get("choice")
    if choice is not None and (not isinstance(choice, str) or choice not in CHOICES):
        raise ReplayError(f"{where}.recommendation.choice: invalid value")
    if status == "available" and choice is None:
        raise ReplayError(f"{where}.recommendation.choice: required when available")
    uncertainty = rec.get("uncertainty")
    if uncertainty is not None:
        if not _is_number(uncertainty) or not 0.0 <= float(uncertainty) <= 1.0:
            raise ReplayError(f"{where}.recommendation.uncertainty: must be in [0, 1]")
        uncertainty = float(uncertainty)

    actual = raw.get("actual_model")
    if actual is not None:
        _token(actual, _MODEL, f"{where}.actual_model")

    review: str | None = None
    repair_count: int | None = None
    outcome = raw.get("outcome")
    if outcome is not None:
        if not isinstance(outcome, dict):
            raise ReplayError(f"{where}.outcome: must be an object")
        if set(outcome) - _OUTCOME_KEYS:
            raise ReplayError(f"{where}.outcome: unexpected field")
        review = outcome.get("review")
        if review is not None:
            _token(review, _REVIEW, f"{where}.outcome.review")
        repair_count = outcome.get("repair_count")
        if repair_count is not None and (
            not _is_int(repair_count) or not 0 <= repair_count <= MAX_REPAIR_COUNT
        ):
            raise ReplayError(f"{where}.outcome.repair_count: invalid value")

    label = raw.get("label")
    if label is not None and (not isinstance(label, str) or len(label) > _MAX_LABEL):
        raise ReplayError(f"{where}.label: invalid value")

    # Whitelisted copy: free-form label text is validated but never carried forward.
    return {
        "task_id": task_id,
        "recommendation": {"status": status, "choice": choice, "uncertainty": uncertainty},
        "actual_model": actual,
        "outcome": {"review": review, "repair_count": repair_count},
    }


def validate_records(records: Any) -> list[dict[str, Any]]:
    """Validate and return whitelisted copies of replay records."""
    if not isinstance(records, list):
        raise ReplayError("input: must be a JSON array")
    if len(records) > MAX_RECORDS:
        raise ReplayError("input: too many records")
    out = [_validate_record(i, raw) for i, raw in enumerate(records)]
    if len({r["task_id"] for r in out}) != len(out):
        raise ReplayError("input: duplicate task_id")
    return out


def parse_records(data: bytes | str) -> list[dict[str, Any]]:
    """Parse and validate a JSON byte/text payload (bounded to MAX_INPUT_BYTES)."""
    raw = data.encode("utf-8") if isinstance(data, str) else data
    if len(raw) > MAX_INPUT_BYTES:
        raise ReplayError("input: too large")
    try:
        parsed = json.loads(raw.decode("utf-8"), parse_constant=_reject_constant)
    except ReplayError:
        raise
    except (ValueError, RecursionError):
        raise ReplayError("input: not valid JSON") from None
    return validate_records(parsed)


def load_records(path: str | Path) -> list[dict[str, Any]]:
    """Read at most MAX_INPUT_BYTES from ``path`` and validate it."""
    try:
        with open(path, "rb") as handle:
            data = handle.read(MAX_INPUT_BYTES + 1)
    except OSError:
        raise ReplayError("input: cannot read file") from None
    return parse_records(data)


def _counter() -> dict[str, int]:
    return {"records": 0, "comparable": 0, "agree": 0, "disagree": 0}


def _bump(table: dict[str, dict[str, int]], key: str, verdict: str | None) -> None:
    row = table.setdefault(key, _counter())
    row["records"] += 1
    if verdict is not None:
        row["comparable"] += 1
        row[verdict] += 1


def evaluate(
    records: Iterable[dict[str, Any]], tier_models: dict[str, str] | None = None
) -> dict[str, Any]:
    """Aggregate agreement of recommendations with actual models.

    A record is *comparable* only when its recommendation is ``available``, its
    choice maps to a model through ``tier_models`` and ``actual_model`` is
    known.  Everything else is counted under ``excluded`` with its reason.
    Records are validated again, so raw/unsanitized input is safe to pass.
    """
    tiers = _validate_tier_models(tier_models)
    rows = validate_records(list(islice(records, MAX_RECORDS + 1)))

    excluded = {"no_recommendation": 0, "not_routable": 0, "unmapped_choice": 0, "actual_unknown": 0}
    by_status: dict[str, int] = {}
    by_choice: dict[str, dict[str, int]] = {}
    by_review: dict[str, dict[str, int]] = {}
    by_repair: dict[str, dict[str, int]] = {}
    agree = disagree = 0

    for row in rows:
        rec = row["recommendation"]
        by_status[rec["status"]] = by_status.get(rec["status"], 0) + 1
        verdict: str | None = None
        if rec["status"] != "available" or rec["choice"] is None:
            excluded["no_recommendation"] += 1
        elif rec["choice"] not in ROUTABLE_CHOICES:
            excluded["not_routable"] += 1
        elif rec["choice"] not in tiers:
            excluded["unmapped_choice"] += 1
        elif row["actual_model"] is None:
            excluded["actual_unknown"] += 1
        else:
            verdict = "agree" if row["actual_model"] == tiers[rec["choice"]] else "disagree"
            if verdict == "agree":
                agree += 1
            else:
                disagree += 1
        _bump(by_choice, rec["choice"] if rec["choice"] is not None else "none", verdict)
        outcome = row["outcome"]
        _bump(by_review, outcome["review"] if outcome["review"] is not None else "unknown", verdict)
        count = outcome["repair_count"]
        _bump(
            by_repair,
            "unknown" if count is None else ("repaired" if count > 0 else "not_repaired"),
            verdict,
        )

    return {
        "kind": "offline_replay_agreement",
        "disclaimer": DISCLAIMER,
        "records": len(rows),
        "comparable": agree + disagree,
        "agreement": {"agree": agree, "disagree": disagree},
        "excluded": excluded,
        "by_status": dict(sorted(by_status.items())),
        "by_complexity": dict(sorted(by_choice.items())),
        "by_outcome": {
            "review": dict(sorted(by_review.items())),
            "repair": dict(sorted(by_repair.items())),
        },
    }


def load_examples() -> list[dict[str, Any]]:
    """Load the bundled MOCK replay examples."""
    return load_records(EXAMPLES_PATH)


def _parse_tier_args(items: list[str]) -> dict[str, str]:
    tiers: dict[str, str] = {}
    for item in items:
        choice, sep, model = item.partition("=")
        if not sep:
            raise ReplayError("--tier-model: expected CHOICE=MODEL")
        tiers[choice] = model
    return tiers


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="python3 -m decision.replay",
        description="Offline agreement replay of recorded decision recommendations (no network).",
    )
    parser.add_argument("--input", help="JSON array of records (default: bundled MOCK examples)")
    parser.add_argument(
        "--tier-model",
        action="append",
        default=[],
        metavar="CHOICE=MODEL",
        help="map a complexity choice to the model it implies (repeatable)",
    )
    args = parser.parse_args(argv)
    try:
        tiers = _validate_tier_models(_parse_tier_args(args.tier_model))
        records = load_records(args.input) if args.input else load_examples()
        summary = evaluate(records, tiers)
    except ReplayError as exc:
        print(f"replay: {exc}", file=sys.stderr)
        return 2
    summary["source"] = "file" if args.input else "bundled MOCK examples (sanitized, not real history)"
    json.dump(summary, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
