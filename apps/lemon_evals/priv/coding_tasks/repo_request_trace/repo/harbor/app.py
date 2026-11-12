from . import routes, auth, service, audit, responses
from .errors import Rejection
def handle(state, method, path, headers, body):
    try:
        routes.resolve(method, path)
        tenant = auth.authenticate(headers)
        result = service.reserve(state, tenant, body)
    except Rejection as error:
        result = responses.rejected(error)
    audit.record(state, result)
    return result
