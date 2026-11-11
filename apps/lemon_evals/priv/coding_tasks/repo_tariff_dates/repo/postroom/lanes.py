def for_depot(depot):
    if type(depot) is not int or not 0 <= depot < 60: raise ValueError('UNKNOWN_DEPOT')
    return f'NW-{depot:02d}'
