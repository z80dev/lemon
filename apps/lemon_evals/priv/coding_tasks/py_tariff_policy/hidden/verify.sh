#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest discover -s tests -v
PYTHONPATH="/work${PYTHONPATH:+:$PYTHONPATH}" python3 /verify/test_policy.py -v
