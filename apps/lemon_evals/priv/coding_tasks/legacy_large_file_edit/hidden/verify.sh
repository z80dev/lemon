#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from catalog import lookup, VALUES
assert lookup('target')==999999
assert len(VALUES)==12001
for i in range(12000): assert lookup('item_%05d' % i)==i
PY
