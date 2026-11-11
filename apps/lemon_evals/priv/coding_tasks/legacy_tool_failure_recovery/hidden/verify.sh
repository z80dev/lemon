#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from calculator import average
assert average([1,2])==1.5
assert average([-1,2])==0.5
try: average([])
except ValueError: pass
else: raise AssertionError('empty average accepted')
PY
python3 -m unittest discover -v 2>&1 | tee /tmp/unittest.log
! grep -q 'Ran 0 tests' /tmp/unittest.log
