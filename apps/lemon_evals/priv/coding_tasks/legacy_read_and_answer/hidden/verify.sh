#!/usr/bin/env bash
set -euo pipefail
git diff --quiet HEAD
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "Unexpected untracked files" >&2
  exit 1
fi
python3 - <<'PY'
import os
answer=os.environ['BENCHMARK_ANSWER']
assert '7317' in answer and '7304' in answer
PY
