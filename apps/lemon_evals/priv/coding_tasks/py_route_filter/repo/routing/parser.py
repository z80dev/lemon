from .errors import ParseError
from .lexer import tokenize

def parse(text):
    tokens = tokenize(text)
    parts = []
    position = 0
    while position < len(tokens):
        group = tokens[position:position + 3]
        if len(group) < 3:
            raise ParseError('incomplete comparison', len(text))
        (field, start), (operator, at), (value, value_at) = group
        if operator not in ('==', '!='):
            raise ParseError('comparison expected', at)
        if not value.startswith('"'):
            raise ParseError('string expected', value_at)
        parts.append(('eq' if operator == '==' else 'ne', field, value[1:-1]))
        position += 3
        if position < len(tokens):
            if tokens[position][0] != '&&':
                raise ParseError('conjunction expected', tokens[position][1])
            position += 1
    if not parts:
        raise ParseError('empty expression', len(text))
    result = parts[0]
    for part in parts[1:]:
        result = ('and', result, part)
    return result
