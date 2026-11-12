from copy import deepcopy
from datetime import date
import re


def validate(event):
    fields = {'id', 'tenant', 'revision', 'day', 'value', 'deleted'}
    if not isinstance(event, dict) or set(event) != fields:
        raise ValueError('event schema')
    if any(not isinstance(event[k], str) or not event[k] for k in ('id', 'tenant')):
        raise ValueError('identity')
    if type(event['revision']) is not int or event['revision'] < 1 or type(event['value']) is not int or type(event['deleted']) is not bool:
        raise ValueError('event types')
    day = event['day']
    if not isinstance(day, str) or not re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}', day):
        raise ValueError('day')
    try:
        date.fromisoformat(day)
    except ValueError:
        raise ValueError('day') from None
    if event['deleted'] and event['value'] != 0:
        raise ValueError('deleted value')
    return deepcopy(event)


class Ledger:
    def __init__(self):
        self._events = {}

    def apply(self, events):
        if not isinstance(events, list):
            raise ValueError('batch')
        candidate = self._events.copy()
        for raw in events:
            event = validate(raw)
            key = (event['tenant'], event['id'])
            previous = candidate.get(key)
            if previous is not None:
                if event['revision'] < previous['revision']:
                    continue
                if event['revision'] == previous['revision']:
                    if event != previous:
                        raise ValueError('revision conflict')
                    continue
            candidate[key] = event
        self._events = candidate

    def totals(self):
        buckets = {}
        for event in self._events.values():
            if event['deleted']:
                continue
            key = (event['tenant'], event['day'])
            entry = buckets.setdefault(key, {'tenant': key[0], 'day': key[1], 'value': 0, 'count': 0})
            entry['value'] += event['value']
            entry['count'] += 1
        return [buckets[key] for key in sorted(buckets)]

    def checkpoint(self):
        return {'version': 2, 'events': [deepcopy(self._events[key]) for key in sorted(self._events)]}

    @classmethod
    def restore(cls, checkpoint):
        if not isinstance(checkpoint, dict) or set(checkpoint) != {'version', 'events'} or type(checkpoint['version']) is not int or checkpoint['version'] != 2 or not isinstance(checkpoint['events'], list):
            raise ValueError('checkpoint')
        result = cls()
        for raw in checkpoint['events']:
            event = validate(raw)
            key = (event['tenant'], event['id'])
            if key in result._events:
                raise ValueError('duplicate identity')
            result._events[key] = event
        return result
