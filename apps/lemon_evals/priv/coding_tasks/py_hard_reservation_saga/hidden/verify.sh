#!/usr/bin/env bash
set -euo pipefail
cd "${WORK_DIR:-/work}"
export PYTHONPATH="$PWD"
python3 -m unittest discover -s tests -p 'test_*.py'
python3 "${VERIFY_DIR:-/verify}/arena_hidden_contract.py"
