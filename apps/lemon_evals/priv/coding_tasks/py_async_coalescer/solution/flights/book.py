import asyncio


async def _invoke(factory):
    # Invocation belongs to the shared task, including synchronous exceptions.
    return await factory()


class FlightBook:
    """Own a flight until completion, independently of its waiters."""

    def __init__(self):
        self._tasks = {}

    @property
    def pending_count(self):
        return sum(not task.done() for task in self._tasks.values())

    def acquire(self, key, factory):
        task = self._tasks.get(key)
        if task is None or task.done():
            task = asyncio.create_task(_invoke(factory))
            self._tasks[key] = task
            task.add_done_callback(lambda completed: self._completed(key, completed))
        return task

    def _completed(self, key, task):
        if self._tasks.get(key) is task:
            del self._tasks[key]
        # Orphaned failures must still be observed; awaiting this task later
        # continues to raise the original exception.
        if not task.cancelled():
            task.exception()
