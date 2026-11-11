def handle(service, payload):
    try: return {'status':200,'quote':service.quote(**payload)}
    except ValueError as error: return {'status':400,'error':str(error)}
    except LookupError as error: return {'status':404,'error':str(error)}
