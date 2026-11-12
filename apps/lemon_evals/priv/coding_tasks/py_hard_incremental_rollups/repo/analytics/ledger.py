class Ledger:
    def __init__(self):
        self.events = []

    def apply(self, events):
        self.events.extend(events)

    def totals(self):
        buckets = {}
        for event in self.events:
            key = (event['tenant'], event['day'])
            entry = buckets.setdefault(key, {'tenant': key[0], 'day': key[1], 'value': 0, 'count': 0})
            entry['value'] += event['value']
            entry['count'] += 1
        return [buckets[key] for key in sorted(buckets)]
