import json
from pathlib import Path
try:
    actual=json.loads(Path('/verify/answer.txt').read_text())
except (ValueError, OSError) as exc:
    raise SystemExit('Expected the requested JSON answer: '+str(exc))
expected=json.loads(Path('/verify/expected.json').read_text())
for key,value in expected.items():
    assert actual.get(key)==value, f'Incorrect trace fact: {key}: {actual.get(key)!r}'
