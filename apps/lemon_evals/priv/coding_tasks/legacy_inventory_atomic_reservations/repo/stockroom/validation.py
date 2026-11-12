def sku(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("SKU must be a nonblank string")
    return value.strip()


def positive_quantity(value):
    if type(value) is not int or value <= 0:
        raise ValueError("quantity must be a positive integer")
    return value
