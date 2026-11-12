from .codec import decode
from .repository import Repository

class Service:
    def __init__(self, engine):
        self.repository = Repository(engine)

    def book(self, raw):
        return self.repository.book(*decode(raw))
