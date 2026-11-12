from datetime import date
def shipping_day(raw):
    try:
        if not isinstance(raw,str): raise ValueError()
        return date.fromisoformat(raw)
    except (TypeError,ValueError): raise ValueError('INVALID_DATE')
