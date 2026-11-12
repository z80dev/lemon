from importlib import import_module

PRODUCTS = ['air', 'rail', 'hotel', 'car', 'ferry', 'tour', 'museum', 'theater', 'parking', 'camp', 'cruise', 'bike', 'shuttle', 'lounge', 'locker', 'workspace']

def make_service(product, engine):
    if product not in PRODUCTS:
        raise ValueError("unknown product")
    return import_module(f"products.{product}.service").Service(engine)
