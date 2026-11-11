from .dates import in_month

def monthly_totals(document, month, zone):
    charges = {row['id']: row for row in document['charges']
               if row['status'] == 'settled' and in_month(row['settled_at'], month, zone)}
    totals = {}
    for charge in charges.values():
        totals.setdefault(charge['merchant'], [0, 0])[0] += charge['amount_cents']
    for refund in document['refunds']:
        if refund['charge_id'] in charges and in_month(refund['posted_at'], month, zone):
            merchant = charges[refund['charge_id']]['merchant']
            totals[merchant][1] += refund['amount_cents']
    return totals
