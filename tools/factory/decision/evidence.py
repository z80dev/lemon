"""Whitelist compact evidence, never transcripts; reject rather than silently truncate."""
from __future__ import annotations

import hashlib
import json
import re

_SECRET = re.compile(
    r"(?i)(?:\bsk-[a-z0-9_-]{8,}|\bbearer\s+[^\s\"']+|"
    r"\b(?:api[_-]?key|password|token|secret)\s*[:=]\s*[^\s,;\"']+)"
)


class EvidenceError(ValueError):
    pass


def compact(task: dict, max_bytes: int) -> dict:
    """Callers must supply sanitized summaries. Obvious credential syntax is rejected.

    Only id, revision, goal, acceptance and evidence are ever sent. Additional
    ledger fields (raw_request, transcripts, environment, policy) are ignored.
    Limits apply before serialization as well, bounding processing/allocation.
    """
    if not isinstance(task, dict):
        raise EvidenceError("invalid_evidence")

    def text(value: object, limit: int) -> str:
        if not isinstance(value, str) or len(value) > limit:
            raise EvidenceError("input_too_large_or_invalid")
        if _SECRET.search(value):
            raise EvidenceError("unsanitized_evidence")
        return value

    identifier = text(task.get("id"), 128)
    revision = task.get("revision")
    if not identifier or type(revision) is not int or not 1 <= revision <= 2**63 - 1:
        raise EvidenceError("invalid_task_identity")
    goal = text(task.get("goal"), max_bytes)
    if not goal.strip():
        raise EvidenceError("missing_goal")
    acceptance = task.get("acceptance", [])
    evidence = task.get("evidence", [])
    if not isinstance(acceptance, list) or len(acceptance) > 20 or not isinstance(evidence, list) or len(evidence) > 20:
        raise EvidenceError("input_too_large_or_invalid")
    criteria = [text(item, 1000) for item in acceptance]
    summaries = []
    for item in evidence:
        if not isinstance(item, dict) or set(item) - {"path", "summary"}:
            raise EvidenceError("invalid_repository_evidence")
        summaries.append({"path": text(item.get("path", ""), 300),
                          "summary": text(item.get("summary"), 1500)})
    state = {"task_id": identifier, "revision": revision, "goal": goal,
             "acceptance": criteria, "repository_evidence": summaries}
    if len(canonical(state)) > max_bytes:
        raise EvidenceError("input_too_large")
    return state


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")


def digest(value: object) -> str:
    return hashlib.sha256(canonical(value)).hexdigest()
