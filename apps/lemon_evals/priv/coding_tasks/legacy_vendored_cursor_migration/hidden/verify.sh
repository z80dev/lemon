#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import hashlib
import importlib.abc
import json
import random
import sys
from pathlib import Path

class RejectOld(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "vendor.shelf_v1":
            raise AssertionError("old provider is still used")
        return None
sys.meta_path.insert(0, RejectOld())
from export import export_records
from lookup import lookup_value
from manifest import build_manifest
from vendor.shelf_v2 import Store

assert not Path("vendor/shelf_v1.py").exists(), "remove the obsolete dependency"
assert hashlib.sha256(Path("vendor/shelf_v2.py").read_bytes()).hexdigest() == "b7ea358b2ef2019c16a4464b090428866bc02c39acb9bb512cba709c3a577abe", "do not alter the vendored v2 contract"
values = [None, False, 0, "", "café", {"z": [1, False], "a": "雪"}, [1, None]]
for seed in range(5):
    rows = [{"key": ("app/" if i % 3 else "other/") + str(i), "value": values[i % len(values)], "deleted": i % 7 == 4} for i in range(127 + seed)]
    random.Random(seed).shuffle(rows)
    # The first page is empty and a later page consists only of tombstones.
    rows = [{"checkpoint": True}] * 3 + [{"key": "app/dead", "value": 9, "deleted": True}] + rows
    for prefix in ["", "app/", "other/", "absent/"]:
        expected = sorted([{"key": row["key"], "value": row["value"]} for row in rows if "key" in row and row["key"].startswith(prefix) and not row.get("deleted")], key=lambda row: row["key"])
        for size in [1, 2, 5, 200]:
            store = Store(rows)
            assert export_records(store, prefix, size) == expected
            assert store.active_sessions == 0
            assert store.scan_sizes and set(store.scan_sizes) == {size}
        store = Store(rows)
        assert build_manifest(store, prefix) == {
            "count": len(expected), "keys": [row["key"] for row in expected],
            "total_bytes": sum(len(json.dumps(row["value"], ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")) for row in expected),
        }
        assert store.active_sessions == 0 and store.scan_sizes
    store = Store([{"key": str(i), "value": value} for i, value in enumerate(values)] + [{"key": "gone", "deleted": True, "value": 1}])
    marker = object()
    for i, value in enumerate(values):
        assert lookup_value(store, str(i), marker) == value
    assert lookup_value(store, "missing", marker) is marker
    assert lookup_value(store, "gone", marker) is marker
    assert store.active_sessions == 0
for operation in [lambda s: lookup_value(s, "bad"), lambda s: export_records(s), lambda s: build_manifest(s)]:
    store = Store([{"key": "bad", "raw_payload": b"not-json"}])
    try:
        operation(store)
    except ValueError:
        pass
    else:
        raise AssertionError("decode error was suppressed")
    assert store.active_sessions == 0, "failed decode leaked a session"
PY
# Run every test file explicitly: `unittest discover` skips directories without __init__.py.
mapfile -t agent_tests < <(find . -name 'test*.py' -not -path './.git/*' | sort)
(( ${#agent_tests[@]} > 0 ))
python3 -m unittest -v "${agent_tests[@]}" 2>&1 | tee /tmp/unittest.log
grep -qE '^Ran [1-9][0-9]* tests?' /tmp/unittest.log
