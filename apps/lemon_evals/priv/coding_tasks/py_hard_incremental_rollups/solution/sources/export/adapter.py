import json
from pathlib import Path
from analytics.ledger import validate

_SCHEMA = json.loads(Path(__file__).with_name('schema.json').read_text())


class Adapter:
    @staticmethod
    def decode(raw):
        if not isinstance(raw, dict):
            raise ValueError('wire object')
        event = {}
        for field, wire in _SCHEMA.items():
            if wire in raw:
                event[field] = raw[wire]
            elif field == 'revision':
                event[field] = 1
            elif field == 'deleted':
                event[field] = False
            else:
                raise ValueError('missing field: ' + wire)
        return validate(event)
