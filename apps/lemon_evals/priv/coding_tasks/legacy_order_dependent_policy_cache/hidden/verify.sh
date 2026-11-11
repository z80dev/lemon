#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import itertools
import os
import subprocess
import sys
from policy import Engine, compile_policy

first = compile_policy("canonical", {"allow": ["b", "a", "a"], "deny": ["z"]})
second = compile_policy("canonical", {"deny": ["z", "z"], "allow": ["a", "b"]})
assert first is second, "semantic compilation cache was removed"
for order in itertools.permutations(range(3)):
    engines = [Engine({"shared": spec}) for spec in [
        {"allow": ["a"], "deny": ["x"]},
        {"allow": ["b"], "deny": ["a"]},
        {"allow": [], "deny": ["b"]},
    ]]
    allowed = [{"a"}, {"b"}, set()]
    denied = [{"x"}, {"a"}, {"b"}]
    for index in order:
        engine = engines[index]
        for role in ["a", "b", "x", "temporary"]:
            assert engine.allows("shared", role) == (role in allowed[index] and role not in denied[index])
            assert engine.allows("shared", role, [role]) == (role not in denied[index])
            assert engine.allows("shared", role) == (role in allowed[index] and role not in denied[index])
            assert engine.allows("missing", role, [role]) is False
    for index in reversed(order):
        assert engines[index].allows("shared", "temporary") is False
config = {"before": {"allow": ["yes"], "deny": []}}
engine = Engine(config)
config["before"]["allow"].clear()
config["before"]["deny"].append("yes")
assert engine.allows("before", "yes") is True
assert Engine(config).allows("before", "yes") is False
for seed in range(8):
    environment = dict(os.environ, PYTHONHASHSEED=str(seed + 1))
    result = subprocess.run([sys.executable, "repro.py", "--seed", str(seed)], env=environment, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
# Explicit opposite orders also exercise the original tests, independent of repro.py.
names = ["temporary_grant", "default_denies_writer", "other_tenant", "deny_wins", "unknown", "snapshot"]
for order in [names, list(reversed(names)), names[2:] + names[:2]]:
    result = subprocess.run([sys.executable, "-m", "unittest", *["test_policy.PolicyTests.test_" + name for name in order]], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
PY
python3 -m unittest discover -v 2>&1 | tee /tmp/unittest.log
! grep -q 'Ran 0 tests' /tmp/unittest.log
