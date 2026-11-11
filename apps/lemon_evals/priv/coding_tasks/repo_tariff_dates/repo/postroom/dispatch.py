from .orders import invoice
from .invoice import quote_invoice
from .labels import render
def dispatch(order):
    return {'reference':order['reference'],'label':render(order['address'],order['reference']),
            'quote':quote_invoice(invoice(order))}
