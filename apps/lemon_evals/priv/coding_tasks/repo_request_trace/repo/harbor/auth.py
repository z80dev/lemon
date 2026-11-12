from .tokens import TOKENS
from .errors import Rejection
def authenticate(headers):
    tenant = TOKENS.get(headers.get('authorization', '').removeprefix('Bearer '))
    if tenant is None:
        raise Rejection(401, 'AUTH_TOKEN', 'harbor.auth.authenticate')
    return tenant
