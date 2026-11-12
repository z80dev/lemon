import re
from .errors import ParseError

TOKEN = re.compile(r'\s+|[A-Za-z_][A-Za-z0-9_.-]*|==|!=|&&|\|\||!|\(|\)|"[^"\n]*"')

def tokenize(text):
    result = []
    position = 0
    while position < len(text):
        found = TOKEN.match(text, position)
        if found is None:
            raise ParseError('unrecognized character', position)
        value = found.group()
        if not value.isspace():
            result.append((value, position))
        position = found.end()
    return result
