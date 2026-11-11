import asyncio


class FlightBook:
    """Own the currently registered requests for a loader."""

    def __init__(self):
        self._tasks = {}

    @property
    def pending_count(self):
        return sum(not task.done() for task in self._tasks.values())

    def acquire(self, key, factory):
        task = self._tasks.get(key)
        if task is None:
            task = asyncio.create_task(factory())
            self._tasks[key] = task
        return task

    def discard(self, key):
        self._tasks.pop(key, None)
