import re
from .errors import ParseError

IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_.-]*')

def tokenize(text):
    result = []
    i = 0
    while i < len(text):
        char = text[i]
        if char in ' \t\r\n':
            i += 1
            continue
        if char == '"':
            start = i
            i += 1
            decoded = []
            while i < len(text) and text[i] != '"':
                char = text[i]
                if char in '\r\n':
                    raise ParseError('raw line break', i)
                if char == '\\':
                    escape_at = i
                    i += 1
                    if i == len(text):
                        raise ParseError('unterminated string', start)
                    escapes = {'"': '"', '\\': '\\', 'n': '\n', 't': '\t'}
                    if text[i] not in escapes:
                        raise ParseError('unknown escape', escape_at)
                    decoded.append(escapes[text[i]])
                else:
                    decoded.append(char)
                i += 1
            if i == len(text):
                raise ParseError('unterminated string', start)
            result.append(('STRING', ''.join(decoded), start))
            i += 1
            continue
        identifier = IDENT.match(text, i)
        if identifier:
            result.append(('IDENT', identifier.group(), i))
            i = identifier.end()
            continue
        pair = text[i:i + 2]
        if pair in ('==', '!=', '&&', '||'):
            result.append((pair, pair, i))
            i += 2
        elif char in '!()':
            result.append((char, char, i))
            i += 1
        else:
            raise ParseError('unrecognized character', i)
    result.append(('EOF', '', len(text)))
    return result
