import json
from pathlib import Path


class DocumentError(ValueError):
    def __init__(self, filename):
        self.filename = filename
        super().__init__(f"cannot read JSON: {filename}")


def load_document(filename):
    try:
        return json.loads(Path(filename).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise DocumentError(filename) from None
