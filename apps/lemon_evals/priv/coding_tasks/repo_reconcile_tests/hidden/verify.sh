#!/usr/bin/env bash
set -euo pipefail
python3 /verify/check_changes.py
test -f tests/test_reconcile.py || { echo 'Missing tests/test_reconcile.py'; exit 1; }
cp /verify/reference.py settler/reconcile.py
python3 -B -m unittest discover -s tests -p test_reconcile.py -v
for mutant in /verify/mutants/*.py; do
  cp "$mutant" settler/reconcile.py
  find settler -type d -name __pycache__ -exec rm -rf {} +
  if python3 -B -m unittest discover -s tests -p test_reconcile.py > /tmp/mutant-output 2>&1; then
    echo "Tests missed $(basename "$mutant")"; cat /tmp/mutant-output; exit 1
  fi
done
cp /verify/reference.py settler/reconcile.py
