#!/usr/bin/env bash
set -euo pipefail
cp /verify/test_dates.py tests/test_hidden_dates.py
python3 -m unittest discover -s tests -v
