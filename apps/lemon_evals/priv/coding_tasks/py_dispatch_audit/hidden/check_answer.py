"""Validate both an immutable audit snapshot and its structured findings."""
import json
import os
from pathlib import Path
import subprocess


def git(*arguments):
    result = subprocess.run(["git", *arguments], cwd="/work", capture_output=True)
    if result.returncode:
        raise SystemExit("cannot verify unchanged repository")
    return result.stdout


# Check index and worktree independently, including staged changes later undone on disk.
if (git("diff", "HEAD", "--name-only", "--")
        or git("diff", "--cached", "HEAD", "--name-only", "--")):
    raise SystemExit("read-only audit changed tracked files")
if git("ls-files", "--others", "--exclude-standard", "-z"):
    raise SystemExit("read-only audit created non-ignored files")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate answer key")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("nonstandard JSON constant")


try:
    raw = Path(os.environ.get("BENCHMARK_ANSWER_FILE", "/verify/answer.txt")).read_text(encoding="utf-8")
    answer = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
except (OSError, ValueError) as error:
    raise SystemExit(f"a structured JSON final answer is required: {error}")
expected = json.loads(Path("/verify/expected.json").read_text(encoding="utf-8"))


def compare(actual, reference, path="answer"):
    if type(actual) is not type(reference):
        raise SystemExit(f"wrong type at {path}")
    if isinstance(reference, dict):
        if actual.keys() != reference.keys():
            raise SystemExit(f"wrong fields at {path}")
        for key in reference:
            compare(actual[key], reference[key], f"{path}.{key}")
    elif isinstance(reference, list):
        if len(actual) != len(reference):
            raise SystemExit(f"wrong list size at {path}")
        for index, (value, wanted) in enumerate(zip(actual, reference)):
            compare(value, wanted, f"{path}[{index}]")
    elif actual != reference:
        raise SystemExit(f"incorrect finding at {path}")


compare(answer, expected)
print("dispatch audit accepted")
