import json

from vendor.shelf_v2 import MissingKey


def lookup_value(store, key, default=None):
    with store.session() as session:
        try:
            entry = session.read(key)
        except MissingKey:
            return default
        return json.loads(entry.payload.decode("utf-8"))
