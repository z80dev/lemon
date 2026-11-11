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
# Run every test file explicitly: `unittest discover` skips directories without __init__.py.
mapfile -t agent_tests < <(find . -name 'test*.py' -not -path './.git/*' | sort)
(( ${#agent_tests[@]} > 0 ))
python3 -m unittest -v "${agent_tests[@]}" 2>&1 | tee /tmp/unittest.log
grep -qE '^Ran [1-9][0-9]* tests?' /tmp/unittest.log
