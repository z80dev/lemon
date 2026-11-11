class Rejection(Exception):
    def __init__(self, status, code, origin):
        self.status, self.code, self.origin = status, code, origin
