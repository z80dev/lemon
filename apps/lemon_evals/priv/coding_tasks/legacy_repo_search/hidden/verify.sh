#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import os
from pathlib import Path
os.environ['API_TOKEN_V2']='benchmark-token'
from service.auth import token
assert token()=='benchmark-token'
for name in ['service/auth.py','scripts/launch.sh','docs/config.txt']:
 assert 'API_TOKEN_V1' not in Path(name).read_text()
 assert 'API_TOKEN_V2' in Path(name).read_text()
assert 'TIMEOUT=30' in Path('docs/config.txt').read_text()
assert list(Path('.').rglob('test*.py'))
PY
python3 -m unittest discover -v 2>&1 | tee /tmp/unittest.log
! grep -q 'Ran 0 tests' /tmp/unittest.log
