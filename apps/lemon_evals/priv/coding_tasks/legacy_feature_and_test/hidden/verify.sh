#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from paging import paginate
from pathlib import Path
assert paginate(list(range(8)),2,3)==[3,4,5]
assert paginate([1],3,2)==[]
for args in [(0,2),(1,0),(-1,3)]:
 try: paginate([1],*args)
 except ValueError: pass
 else: raise AssertionError('invalid pagination accepted')
assert list(Path('.').glob('test*.py'))
PY
# Run every test file explicitly: `unittest discover` skips directories without __init__.py.
mapfile -t agent_tests < <(find . -name 'test*.py' -not -path './.git/*' | sort)
(( ${#agent_tests[@]} > 0 ))
python3 -m unittest -v "${agent_tests[@]}" 2>&1 | tee /tmp/unittest.log
grep -qE '^Ran [1-9][0-9]* tests?' /tmp/unittest.log
