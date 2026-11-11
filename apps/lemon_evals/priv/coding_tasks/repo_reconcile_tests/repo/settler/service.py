from .reader import read_entries
from .reconcile import reconcile
from .receipt import receipt
from .writer import write_totals
def settle(source, target, now):
    totals=reconcile(read_entries(source),now)
    write_totals(target,totals)
    return receipt(totals)
