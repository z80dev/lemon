import asyncio
from .book import FlightBook


class Coalescer:
    """Share work, but never share cancellation between callers."""

    def __init__(self):
        self._book = FlightBook()

    @property
    def pending_count(self):
        return self._book.pending_count

    async def run(self, key, factory):
        task = self._book.acquire(key, factory)
        return await asyncio.shield(task)
