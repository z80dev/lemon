from .codec import decode
from .repository import Repository


class Service:
    def __init__(self, engine):
        self.repository = Repository(engine)

    def book(self, raw):
        key, lines = decode(raw)
        return self.repository.reserve(key, lines)

    def cancel(self, key):
        return self.repository.cancel(key)

    def snapshot(self):
        return self.repository.snapshot()
