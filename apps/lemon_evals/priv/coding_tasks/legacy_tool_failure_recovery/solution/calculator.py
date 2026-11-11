def average(values):
    if not values:
        raise ValueError("average requires at least one value")
    return sum(values) / len(values)
