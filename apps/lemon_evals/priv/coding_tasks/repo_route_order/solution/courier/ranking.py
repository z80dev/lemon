def ordered(rules):
    return sorted(rules,key=lambda rule:(rule.priority,rule.code))
