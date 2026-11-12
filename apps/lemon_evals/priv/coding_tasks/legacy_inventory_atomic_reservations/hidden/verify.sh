#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import json
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
from stockroom.domain import Stock
from stockroom.repository import Repository
from stockroom.service import Service

def raises(kind, operation):
    try:
        operation()
    except kind:
        return
    raise AssertionError("expected " + kind.__name__)

assert Stock("A", 9, 4).available == 5
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / "legacy.db"
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE stocks(sku TEXT PRIMARY KEY, quantity INTEGER NOT NULL)")
        connection.executemany("INSERT INTO stocks VALUES (?, ?)", [("A", 10), ("B", 4)])
    repository = Repository(path)
    service = Service(repository)
    assert repository.stock("A").reserved == 0
    expected = {"order_id": "one", "items": [{"sku": "A", "quantity": 5}, {"sku": "B", "quantity": 2}]}
    assert service.reserve(" one ", [{"sku": "B", "quantity": 2}, {"sku": " A ", "quantity": 2}, {"sku": "A", "quantity": 3}]) == expected
    assert (repository.stock("A").quantity, repository.stock("A").reserved, repository.stock("A").available) == (10, 5, 5)
    raises(ValueError, lambda: service.reserve("one", [{"sku": "A", "quantity": 4}]))
    raises(ValueError, lambda: service.reserve("two", [{"sku": "A", "quantity": 4}, {"sku": "B", "quantity": 3}]))
    raises(KeyError, lambda: service.reserve("two", [{"sku": "A", "quantity": 1}, {"sku": "missing", "quantity": 1}]))
    assert repository.stock("A").reserved == 5
    assert repository.stock("B").reserved == 2
    for bad_id in [None, " ", 7]:
        raises(ValueError, lambda: service.reserve(bad_id, [{"sku": "A", "quantity": 1}]))
    for lines in [None, {}, (), [], [{}], [{"sku": "A"}], [{"sku": " ", "quantity": 1}], [{"sku": 3, "quantity": 1}]]:
        raises(ValueError, lambda: service.reserve("bad", lines))
    for quantity in [True, False, 0, -1, 1.5, "2", None]:
        raises(ValueError, lambda: service.reserve("bad", [{"sku": "A", "quantity": quantity}]))
    raises(ValueError, lambda: service.reserve("duplicate-overflow", [{"sku": "A", "quantity": 3}, {"sku": "A", "quantity": 3}]))
    assert repository.stock("A").reserved == 5
    second = Repository(path)
    try:
        assert second.stock("A").reserved == 5
        Service(second).reserve("two", [{"sku": "A", "quantity": 5}])
        assert repository.stock("A").available == 0
        assert service.reserve("one", list(reversed(expected["items"]))) == expected
        raises(ValueError, lambda: service.reserve("third", [{"sku": "A", "quantity": 1}]))
        service.add_stock("A", 2)
        assert second.stock("A").available == 2
        assert service.reserve("third", [{"sku": "A", "quantity": 1}])["order_id"] == "third"
    finally:
        second.close()
        repository.close()
    reopened = Repository(path)
    try:
        assert Service(reopened).reserve("one", expected["items"]) == expected
        assert reopened.stock("A").reserved == 11
    finally:
        reopened.close()

    def cli(*args):
        return subprocess.run([sys.executable, "-m", "stockroom.cli", "--db", str(path), *args], capture_output=True, text=True)
    result = cli("reserve", "cli", "B:1", "B:1")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"order_id": "cli", "items": [{"sku": "B", "quantity": 2}]}
    for args in [("reserve", "bad", "B:1"), ("reserve", "bad", "missing:1"), ("reserve", "bad", "A:no"), ("reserve", "bad", "A:0")]:
        result = cli(*args)
        assert result.returncode == 2 and result.stdout == "" and result.stderr.strip()
        assert "Traceback" not in result.stderr
    result = cli("list")
    assert result.returncode == 0
    assert json.loads(result.stdout) == [{"sku": "A", "quantity": 12}, {"sku": "B", "quantity": 4}]
    result = cli("add", "C", "3")
    assert result.returncode == 0 and json.loads(result.stdout) == {"sku": "C", "quantity": 3}
PY
# Run every test file explicitly: `unittest discover` skips directories without __init__.py.
mapfile -t agent_tests < <(find . -name 'test*.py' -not -path './.git/*' | sort)
(( ${#agent_tests[@]} > 0 ))
python3 -m unittest -v "${agent_tests[@]}" 2>&1 | tee /tmp/unittest.log
grep -qE '^Ran [1-9][0-9]* tests?' /tmp/unittest.log
