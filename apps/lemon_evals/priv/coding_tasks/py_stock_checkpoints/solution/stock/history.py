from bisect import bisect_right
from .revisions import latest

def balances(events, checkpoints):
    groups = {}
    for event in latest(events):
        groups.setdefault(event.sku, []).append(event)
    indexes = {}
    for sku, records in groups.items():
        records.sort(key=lambda event: event.at)
        times = []
        prefix = [0]
        for event in records:
            times.append(event.at)
            prefix.append(prefix[-1] + event.delta)
        indexes[sku] = (times, prefix)
    result = []
    for point in checkpoints:
        index = indexes.get(point.sku)
        if index is None:
            result.append(0)
        else:
            times, prefix = index
            result.append(prefix[bisect_right(times, point.at)])
    return result
