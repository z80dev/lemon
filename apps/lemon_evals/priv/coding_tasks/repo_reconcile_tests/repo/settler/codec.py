import json
from .model import Entry
def decode(line):
    return Entry(**json.loads(line))
def encode(entry):
    return json.dumps(entry.__dict__,sort_keys=True)
