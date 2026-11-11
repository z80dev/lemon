from .responses import created
def commit(state, event):
    state.events.append(event)
    state.used += event['amount'] + event['fee']
    receipt = created(event, state.limit - state.used)
    state.receipts[event['key']] = receipt
    return dict(receipt)
