from .errors import ParseError
from .lexer import tokenize

class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.index = 0

    def accept(self, kind):
        if self.tokens[self.index][0] == kind:
            token = self.tokens[self.index]
            self.index += 1
            return token
        return None

    def expect(self, kind):
        token = self.accept(kind)
        if token is None:
            raise ParseError('expected ' + kind, self.tokens[self.index][2])
        return token

    def expression(self):
        node = self.conjunction()
        while self.accept('||') is not None:
            node = ('or', node, self.conjunction())
        return node

    def conjunction(self):
        node = self.unary()
        while self.accept('&&') is not None:
            node = ('and', node, self.unary())
        return node

    def unary(self):
        if self.accept('!') is not None:
            return ('not', self.unary())
        if self.accept('(') is not None:
            node = self.expression()
            self.expect(')')
            return node
        field = self.expect('IDENT')[1]
        operator = self.tokens[self.index]
        if operator[0] not in ('==', '!='):
            raise ParseError('expected comparison', operator[2])
        self.index += 1
        value = self.expect('STRING')[1]
        return ('eq' if operator[0] == '==' else 'ne', field, value)

def parse(text):
    parser = Parser(tokenize(text))
    node = parser.expression()
    parser.expect('EOF')
    return node
