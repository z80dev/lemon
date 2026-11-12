import json
from pathlib import Path


class DocumentError(ValueError):
    def __init__(self, filename):
        self.filename = filename
        super().__init__(f"cannot read JSON: {filename}")


def _reject_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")


def load_document(filename):
    try:
        return json.loads(Path(filename).read_text(encoding="utf-8"), parse_constant=_reject_constant)
    except (OSError, ValueError):
        raise DocumentError(filename) from None
