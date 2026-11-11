def warm(service, countries):
    for country in countries:
        try: service.quote(country,'standard',1)
        except LookupError: pass
