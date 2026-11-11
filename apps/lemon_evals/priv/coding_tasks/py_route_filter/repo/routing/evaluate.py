def matches(ast, record):
    kind = ast[0]
    if kind in ('eq', 'ne'):
        _, field, value = ast
        if field not in record:
            return False
        return record[field] == value if kind == 'eq' else record[field] != value
    if kind == 'not':
        return not matches(ast[1], record)
    if kind == 'and':
        return matches(ast[1], record) and matches(ast[2], record)
    if kind == 'or':
        return matches(ast[1], record) or matches(ast[2], record)
    raise ValueError('unknown expression kind')
