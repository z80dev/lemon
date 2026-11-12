#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
import subprocess
from pathlib import Path
r=subprocess.run(['python3','report.py'],capture_output=True,text=True)
assert r.returncode==0 and r.stdout.strip()=='TOTAL=42'
assert Path('data.csv').read_text()=='name,amount\nalpha, 10\nbeta,12\ngamma,20\n'
PY
