#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from slug import slug
assert slug(' Hello,   World!! ') == 'hello-world'
assert slug('A_B / C') == 'a-b-c'
assert slug('---') == ''
PY
# Run every test file explicitly: `unittest discover` skips directories without __init__.py.
mapfile -t agent_tests < <(find . -name 'test*.py' -not -path './.git/*' | sort)
(( ${#agent_tests[@]} > 0 ))
python3 -m unittest -v "${agent_tests[@]}" 2>&1 | tee /tmp/unittest.log
grep -qE '^Ran [1-9][0-9]* tests?' /tmp/unittest.log
