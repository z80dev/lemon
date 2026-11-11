from .model import Request
def request(country, tier, weight, hazmat):
    if not isinstance(country,str) or not country.strip(): raise ValueError('COUNTRY')
    if tier not in ('standard','priority'): raise ValueError('TIER')
    if type(weight) is not int or weight <= 0: raise ValueError('WEIGHT')
    if type(hazmat) is not bool: raise ValueError('HAZMAT')
    return Request(country.strip().upper(),tier,weight,hazmat)
