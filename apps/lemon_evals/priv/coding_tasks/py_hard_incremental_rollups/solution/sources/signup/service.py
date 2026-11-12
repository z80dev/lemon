from analytics.ledger import Ledger
from .adapter import Adapter


def ingest(ledger, rows):
    if not isinstance(rows, list):
        raise ValueError('rows')
    events = [Adapter.decode(row) for row in rows]
    ledger.apply(events)
    return ledger.totals()


def preview(ledger, rows):
    projected = Ledger.restore(ledger.checkpoint())
    return ingest(projected, rows)
