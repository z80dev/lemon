import json
from pathlib import Path

_POLICY = json.loads(Path(__file__).with_name('policy.json').read_text())


def decode(raw):
    if not isinstance(raw, dict):
        raise ValueError('request object')
    if 'items' in raw:
        key = raw.get('key')
        items = raw['items']
        if not isinstance(items, list) or not items:
            raise ValueError('items')
        if any(not isinstance(item, dict) or 'sku' not in item or 'units' not in item for item in items):
            raise ValueError('item shape')
        lines = [(item['sku'], item['units']) for item in items]
    else:
        key = raw.get('request_id')
        if _POLICY['sku_field'] not in raw or _POLICY['quantity_field'] not in raw:
            raise ValueError('legacy shape')
        lines = [(raw[_POLICY['sku_field']], raw[_POLICY['quantity_field']])]
    if not isinstance(key, str) or not key:
        raise ValueError('key')
    for sku, units in lines:
        if not isinstance(sku, str) or not sku.startswith(_POLICY['prefix']) or type(units) is not int or units <= 0:
            raise ValueError('product line')
    if sum(units for _, units in lines) > _POLICY['limit']:
        raise ValueError('product limit')
    return key, lines
