def charge(invoice):
    value=invoice.get('handling_cents',0)
    if type(value) is not int or value < 0: raise ValueError('INVALID_HANDLING')
    return value
