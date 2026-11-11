from .model import Entry
def expire(entry, deadline):
    return Entry(entry.account,entry.entry_id,entry.revision,entry.amount,deadline,entry.void)
