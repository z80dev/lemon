#!/usr/bin/env bash
set -euo pipefail
python3 - <<'PY'
from money import format_money
from invoice import invoice_total
from receipt import receipt_total
from pathlib import Path
for value in [0, 123, -450]:
 expected = '$%.2f' % (value / 100)
 assert format_money(value) == invoice_total(value) == receipt_total(value) == expected
for name in ['invoice.py','receipt.py']:
 text=Path(name).read_text()
 assert 'format_money' in text and ' / 100' not in text
assert list(Path('.').glob('test*.py'))
PY
# Run every test file explicitly: `unittest discover` skips directories without __init__.py.
mapfile -t agent_tests < <(find . -name 'test*.py' -not -path './.git/*' | sort)
(( ${#agent_tests[@]} > 0 ))
python3 -m unittest -v "${agent_tests[@]}" 2>&1 | tee /tmp/unittest.log
grep -qE '^Ran [1-9][0-9]* tests?' /tmp/unittest.log
