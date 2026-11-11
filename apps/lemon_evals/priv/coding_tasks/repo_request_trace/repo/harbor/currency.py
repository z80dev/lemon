from .errors import Rejection
def normalize(raw, tenant):
    if not isinstance(raw, str) or raw.upper() != tenant['currency']:
        raise Rejection(400, 'CURRENCY_INVALID', 'harbor.currency.normalize')
    return raw.upper()
