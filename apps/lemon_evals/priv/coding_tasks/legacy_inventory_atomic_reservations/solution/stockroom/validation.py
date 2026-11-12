def sku(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("SKU must be a nonblank string")
    return value.strip()


def positive_quantity(value):
    if type(value) is not int or value <= 0:
        raise ValueError("quantity must be a positive integer")
    return value


def order_id(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("order ID must be a nonblank string")
    return value.strip()


def reservation_lines(value):
    if not isinstance(value, list) or not value:
        raise ValueError("reservation lines must be a nonempty list")
    quantities = {}
    for line in value:
        if not isinstance(line, dict) or "sku" not in line or "quantity" not in line:
            raise ValueError("each reservation line needs sku and quantity")
        name = sku(line["sku"])
        quantity = positive_quantity(line["quantity"])
        quantities[name] = quantities.get(name, 0) + quantity
    return [{"sku": name, "quantity": quantities[name]} for name in sorted(quantities)]
