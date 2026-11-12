from .orders import invoice
def entries(orders):
    return [{'reference':o['reference'],**invoice(o)} for o in orders]
