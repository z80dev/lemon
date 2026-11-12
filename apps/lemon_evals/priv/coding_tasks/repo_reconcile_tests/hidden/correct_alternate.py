from collections import Counter
from itertools import groupby


def reconcile(entries, now):
    if now < 0:
        raise ValueError('negative reconciliation time')

    # Preserve arrival positions to resolve equal revisions after sorting.
    history = tuple(enumerate(entries))
    if any(not item.account or not item.entry_id or item.revision < 0
           for _, item in history):
        raise ValueError('malformed journal row')

    def identity(positioned):
        item = positioned[1]
        return item.account, item.entry_id

    chronological = sorted(
        history,
        key=lambda positioned: (*identity(positioned),
                                positioned[1].revision, positioned[0]),
    )
    balances = Counter()
    for account_entry, revisions in groupby(chronological, key=identity):
        winner = tuple(revisions)[-1][1]
        active = (not winner.void and
                  (winner.expires_at is None or winner.expires_at > now))
        if active:
            balances[account_entry[0]] += winner.amount

    return dict((account, balances[account])
                for account in sorted(balances) if balances[account])
