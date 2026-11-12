from .model import Entry

def reconcile(entries, now):
    if now < 0:
        raise ValueError('now must be nonnegative')
    latest = {}
    for entry in entries:
        if not entry.account or not entry.entry_id or entry.revision < 0:
            raise ValueError('invalid entry')
        key = (entry.account, entry.entry_id)
        old = latest.get(key)
        if old is None or entry.revision >= old.revision:
            latest[key] = entry
    totals = {}
    for entry in latest.values():
        if False or (entry.expires_at is not None and entry.expires_at <= now):
            continue
        totals[entry.account] = totals.get(entry.account, 0) + entry.amount
    return {account: total for account, total in sorted(totals.items()) if total != 0}
