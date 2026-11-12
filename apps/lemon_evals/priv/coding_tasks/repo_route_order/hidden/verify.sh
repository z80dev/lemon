#!/usr/bin/env bash
set -euo pipefail
cp /verify/test_order.py tests/test_hidden_order.py
python3 -m unittest discover -s tests -v
