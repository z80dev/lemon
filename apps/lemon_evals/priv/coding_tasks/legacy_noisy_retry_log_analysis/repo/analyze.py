import json
import sys
from collections import Counter


def analyze(lines):
    errors = Counter()
    succeeded = failed = malformed = 0
    for line in lines:
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except ValueError:
            malformed += 1
            continue
        if event.get("status") == "error" or event.get("severity") == "error":
            errors[event.get("code", "E_TIMEOUT")] += 1
        if event.get("type") == "complete":
            if event["status"] == "success":
                succeeded += 1
            else:
                failed += 1
    return {"completed": succeeded + failed, "succeeded": succeeded,
            "failed": failed, "recovered": 0, "pending": 0,
            "malformed": malformed, "error_counts": dict(errors), "failures": []}


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        print(json.dumps(analyze(source), sort_keys=True))
