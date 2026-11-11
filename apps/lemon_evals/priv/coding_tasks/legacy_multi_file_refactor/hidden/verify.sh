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
python3 -m unittest discover -v 2>&1 | tee /tmp/unittest.log
! grep -q 'Ran 0 tests' /tmp/unittest.log
