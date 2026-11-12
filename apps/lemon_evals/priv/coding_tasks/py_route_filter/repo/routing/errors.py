class ParseError(ValueError):
    def __init__(self, message, pos):
        super().__init__(message)
        self.pos = pos
