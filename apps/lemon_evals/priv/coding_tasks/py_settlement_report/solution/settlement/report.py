from .ledger import monthly_totals

def build_report(document, month, zone):
    totals = monthly_totals(document, month, zone)
    return {'month': month, 'zone': zone, 'merchants': [
        {'merchant': merchant, 'gross_cents': totals[merchant][0],
         'refund_cents': totals[merchant][1], 'net_cents': totals[merchant][0] - totals[merchant][1]}
        for merchant in sorted(totals)]}
