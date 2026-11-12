from .dispatch import dispatch
def handle(order):
    try: return {'status':200,'result':dispatch(order)}
    except (ValueError,LookupError,KeyError) as exc: return {'status':400,'error':str(exc)}
