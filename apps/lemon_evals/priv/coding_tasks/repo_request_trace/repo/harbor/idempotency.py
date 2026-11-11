def lookup(state, key):
    value = state.receipts.get(key)
    if value is None:
        return None
    return {**value, 'status': 200, 'replayed': True}
