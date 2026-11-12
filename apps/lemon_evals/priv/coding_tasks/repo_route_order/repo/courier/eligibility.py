def accepts(rule, request):
    return (rule.country == request.country and request.tier in rule.tiers
            and request.weight <= rule.max_weight and (not request.hazmat or rule.hazmat))
