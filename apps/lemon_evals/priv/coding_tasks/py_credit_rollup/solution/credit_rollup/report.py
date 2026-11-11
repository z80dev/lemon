"""Produce JSON-ready account summaries."""
from .parser import transactions


def _money(cents):
    sign = "-" if cents < 0 else ""
    whole, fraction = divmod(abs(cents), 100)
    return f"{sign}{whole}.{fraction:02d}"


def rollup(source):
    groups = {}
    totals = {"count": 0, "sales": 0, "refunds": 0}
    for transaction in transactions(source):
        key = (transaction.account, transaction.currency)
        group = groups.setdefault(key, {"account": key[0], "currency": key[1],
                                        "count": 0, "sales": 0, "refunds": 0})
        field = "refunds" if transaction.kind == "refund" else "sales"
        for bucket in (group, totals):
            bucket["count"] += 1
            bucket[field] += transaction.cents
    rows = [groups[key] for key in sorted(groups)]
    for bucket in rows + [totals]:
        bucket["net"] = _money(bucket["sales"] - bucket["refunds"])
        bucket["sales"] = _money(bucket["sales"])
        bucket["refunds"] = _money(bucket["refunds"])
    return {"groups": rows, "totals": totals}
