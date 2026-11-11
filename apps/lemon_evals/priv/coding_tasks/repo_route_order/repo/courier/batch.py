def quotes(service, requests):
    results=[]
    for item in requests:
        try: results.append(service.quote(**item))
        except LookupError as error: results.append({'error':str(error)})
    return results
