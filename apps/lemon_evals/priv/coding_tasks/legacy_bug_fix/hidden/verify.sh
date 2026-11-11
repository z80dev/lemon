#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from slug import slug
assert slug(' Hello,   World!! ') == 'hello-world'
assert slug('A_B / C') == 'a-b-c'
assert slug('---') == ''
PY
python3 -m unittest discover -v 2>&1 | tee /tmp/unittest.log
! grep -q 'Ran 0 tests' /tmp/unittest.log
