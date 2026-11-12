from .catalog import lookup
from .handling import charge

def quote_invoice(invoice):
    rate=lookup(invoice['lane'],invoice['grams'])
    handling=charge(invoice)
    return {'postage_cents':rate.cents,'handling_cents':handling,'total_cents':rate.cents+handling}
