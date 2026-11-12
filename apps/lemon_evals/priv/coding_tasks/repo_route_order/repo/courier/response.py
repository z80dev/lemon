def quote(rule, request, cents):
    return {'route':rule.code,'country':request.country,'tier':request.tier,'weight':request.weight,'hazmat':request.hazmat,'cents':cents}
