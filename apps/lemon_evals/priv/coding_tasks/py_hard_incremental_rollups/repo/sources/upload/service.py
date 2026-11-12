from .adapter import Adapter

def ingest(ledger, rows):
    ledger.apply([Adapter.decode(row) for row in rows])
    return ledger.totals()
