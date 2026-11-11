from .errors import Rejection
def require(body):
    if not isinstance(body, dict) or any(k not in body for k in ('project','day','amount','currency','request_id')):
        raise Rejection(400, 'BODY_FIELDS', 'harbor.schema.require')
    return dict(body)
