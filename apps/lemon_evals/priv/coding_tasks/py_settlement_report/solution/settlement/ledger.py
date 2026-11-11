from .dates import in_month

def monthly_totals(document, month, zone):
    charges = {row['id']: row for row in document['charges'] if row['status'] == 'settled'}
    totals = {}
    for charge in charges.values():
        if in_month(charge['settled_at'], month, zone):
            totals.setdefault(charge['merchant'], [0, 0])[0] += charge['amount_cents']
    for refund in document['refunds']:
        charge = charges.get(refund['charge_id'])
        if charge is not None and in_month(refund['posted_at'], month, zone):
            totals.setdefault(charge['merchant'], [0, 0])[1] += refund['amount_cents']
    return totals
