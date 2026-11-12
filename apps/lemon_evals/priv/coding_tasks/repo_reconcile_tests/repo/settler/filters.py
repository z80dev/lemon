def for_account(entries, account):
    return (entry for entry in entries if entry.account == account)
def revisions_after(entries, revision):
    return (entry for entry in entries if entry.revision > revision)
