from .catalog import lookup
from .handling import charge
from .dates import shipping_day

def quote_invoice(invoice):
    rate=lookup(invoice['lane'],invoice['grams'],shipping_day(invoice['shipping_date']))
    handling=charge(invoice)
    return {'postage_cents':rate.cents,'handling_cents':handling,'total_cents':rate.cents+handling}
