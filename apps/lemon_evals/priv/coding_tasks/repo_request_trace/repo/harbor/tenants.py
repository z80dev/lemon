TENANTS = {'team-birch': {'currency': 'USD'}, 'team-cedar': {'currency': 'EUR'}}
def get(tenant):
    return TENANTS[tenant]
