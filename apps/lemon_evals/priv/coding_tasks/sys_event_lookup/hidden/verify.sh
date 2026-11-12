#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest discover -s tests -v
python3 /verify/test_event_hidden.py
