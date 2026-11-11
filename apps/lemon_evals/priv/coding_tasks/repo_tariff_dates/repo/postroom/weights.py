def packed(items):
    return sum(item['grams']*item.get('quantity',1) for item in items)
