from .book import FlightBook


class Coalescer:
    """Collapse duplicate reads while their callers are waiting."""

    def __init__(self):
        self._book = FlightBook()

    @property
    def pending_count(self):
        return self._book.pending_count

    async def run(self, key, factory):
        task = self._book.acquire(key, factory)
        try:
            return await task
        finally:
            self._book.discard(key)
