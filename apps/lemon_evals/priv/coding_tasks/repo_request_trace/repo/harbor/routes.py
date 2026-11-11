from .errors import Rejection
def resolve(method, path):
    if (method, path) != ('POST', '/v1/reservations'):
        raise Rejection(404, 'NOT_FOUND', 'harbor.routes.resolve')
    return 'reserve'
