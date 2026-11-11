from collections import Counter
def accounts(entries): return dict(Counter(e.account for e in entries))
def revisions(entries): return max((e.revision for e in entries), default=0)
