#!/usr/bin/env bash
set -euo pipefail
cd /work
python3 -m unittest discover -s /verify -p "test_*.py" -v
