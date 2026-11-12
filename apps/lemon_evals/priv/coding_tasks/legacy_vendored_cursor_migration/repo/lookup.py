from vendor.shelf_v1 import get


def lookup_value(store, key, default=None):
    return get(store, key) or default
