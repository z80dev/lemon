def created(event, remaining):
    return dict(status=201, key=event['key'], amount=event['amount'], fee=event['fee'], remaining=remaining, replayed=False)
def rejected(error):
    return dict(status=error.status, code=error.code, origin=error.origin)
