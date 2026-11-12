from .model import Entry
def void(entry):
    return Entry(entry.account,entry.entry_id,entry.revision+1,0,void=True)
def replace_amount(entry, amount):
    return Entry(entry.account,entry.entry_id,entry.revision+1,amount,entry.expires_at)
