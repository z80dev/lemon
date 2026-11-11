def routes(registry):
    return [{'code':r.code,'country':r.country,'priority':r.priority} for r in registry.rules()]
