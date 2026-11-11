import json
import sys
from collections import Counter, defaultdict


def _valid_event(event):
    for field in ("id", "job"):
        if not isinstance(event.get(field), str) or not event[field]:
            return False
    for field, minimum in (("seq", 0), ("attempt", 1)):
        if type(event.get(field)) is not int or event[field] < minimum:
            return False
    if event["type"] == "complete":
        return event.get("status") in ("success", "failed")
    if event.get("stage") not in ("fetch", "parse", "commit"):
        return False
    if event.get("status") not in ("ok", "error"):
        return False
    return event["status"] != "error" or (
        isinstance(event.get("code"), str) and bool(event["code"])
    )


def _event_order(event):
    return event["seq"], event["id"]


def analyze(lines):
    error_counts = Counter()
    errors_by_job = defaultdict(list)
    completions = {}
    jobs = set()
    seen = set()
    malformed = 0
    for line in lines:
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            malformed += 1
            continue
        if not isinstance(event, dict):
            malformed += 1
            continue
        if event.get("type") not in ("attempt", "complete"):
            continue
        if not _valid_event(event):
            malformed += 1
            continue
        if event["id"] in seen:
            continue
        seen.add(event["id"])
        job = event["job"]
        jobs.add(job)
        if event["type"] == "complete":
            previous = completions.get(job)
            if previous is None or _event_order(event) > _event_order(previous):
                completions[job] = event
        elif event["status"] == "error":
            error_counts[event["code"]] += 1
            errors_by_job[job].append(event)

    succeeded = recovered = 0
    failures = []
    for job, completion in completions.items():
        errors = errors_by_job.get(job, ())
        if completion["status"] == "success":
            succeeded += 1
            if any(error["seq"] <= completion["seq"] for error in errors):
                recovered += 1
            continue
        root = min(
            (error for error in errors
             if error["attempt"] == completion["attempt"]
             and error["seq"] <= completion["seq"]),
            key=_event_order, default=None,
        )
        failures.append({
            "job": job,
            "attempt": completion["attempt"],
            "code": root["code"] if root is not None else "unknown",
            "stage": root["stage"] if root is not None else None,
            "seq": root["seq"] if root is not None else completion["seq"],
        })
    failures.sort(key=lambda failure: (failure["seq"], failure["job"]))
    return {
        "completed": len(completions),
        "succeeded": succeeded,
        "failed": len(failures),
        "recovered": recovered,
        "pending": len(jobs) - len(completions),
        "malformed": malformed,
        "error_counts": dict(sorted(error_counts.items())),
        "failures": failures,
    }


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        print(json.dumps(analyze(source), sort_keys=True))
