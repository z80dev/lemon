#!/usr/bin/env bash
set -euo pipefail
git diff --quiet HEAD || { echo 'Read-only task changed tracked files'; exit 1; }
test -z "$(git ls-files --others --exclude-standard)" || { echo 'Read-only task added files'; exit 1; }
python3 /verify/check.py
