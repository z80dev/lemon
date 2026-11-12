from . import parse, matches

def select(rules, shipment):
    return [name for name, source in rules.items() if matches(parse(source), shipment)]
