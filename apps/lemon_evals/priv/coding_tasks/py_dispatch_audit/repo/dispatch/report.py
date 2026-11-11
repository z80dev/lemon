"""Aggregate settlement quotes by account."""
from .billing import quote


def _empty():
    return dict(billed=0, skipped=0, billable_kg=0, gross_cents=0,
                discount_cents=0, net_cents=0)


def summarize(shipments, rebates):
    accounts = {}
    totals = _empty()
    for shipment in shipments:
        row = accounts.setdefault(shipment.account, _empty())
        charge = quote(shipment, rebates[shipment.account])
        for bucket in (row, totals):
            bucket["billed"] += int(charge.billed)
            bucket["skipped"] += int(not charge.billed)
            for field in ("billable_kg", "gross_cents", "discount_cents", "net_cents"):
                bucket[field] += getattr(charge, field)
    return {"accounts": [dict(account=account, **accounts[account]) for account in sorted(accounts)],
            "totals": totals}
