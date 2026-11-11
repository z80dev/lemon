from .ledger import monthly_totals

def build_report(document, month, zone):
    totals = monthly_totals(document, month, zone)
    return {'month': month, 'zone': zone, 'merchants': [
        {'merchant': merchant, 'gross_cents': gross, 'refund_cents': refunds,
         'net_cents': gross + refunds}
        for merchant, (gross, refunds) in totals.items()]}
