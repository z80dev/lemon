import asyncio
import unittest
from flights import Coalescer


class LifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tasks = []
        self.gates = []

    async def asyncTearDown(self):
        for event in self.gates:
            event.set()
        for task in self.tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        await self.turn()

    def event(self):
        value = asyncio.Event()
        self.gates.append(value)
        return value

    async def turn(self):
        checkpoint = asyncio.Event()
        asyncio.get_running_loop().call_soon(checkpoint.set)
        await checkpoint.wait()

    async def start(self, c, key, factory):
        entered = asyncio.Event()
        async def caller():
            entered.set()
            return await c.run(key, factory)
        task = asyncio.create_task(caller())
        self.tasks.append(task)
        await entered.wait()
        return task

    async def cancel(self, task):
        task.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await task

    async def test_all_cancelled_then_late_joiner(self):
        c = Coalescer()
        gate, began, finished = self.event(), self.event(), self.event()
        calls, cancelled = [], []
        result = object()
        async def factory():
            calls.append(1)
            began.set()
            try:
                await gate.wait()
                return result
            except asyncio.CancelledError:
                cancelled.append(1)
                raise
            finally:
                finished.set()
        first = await self.start(c, None, factory)
        await began.wait()
        second = await self.start(c, None, factory)
        await self.cancel(first)
        await self.cancel(second)
        self.assertEqual(c.pending_count, 1)
        self.assertFalse(finished.is_set())
        def forbidden():
            raise AssertionError("joining factory was invoked")
        late = await self.start(c, None, forbidden)
        gate.set()
        self.assertIs(await late, result)
        self.assertEqual(calls, [1])
        self.assertEqual(cancelled, [])
        self.assertEqual(c.pending_count, 0)

    async def test_noninitiating_cancellation_and_equal_keys(self):
        c = Coalescer()
        gate, began = self.event(), self.event()
        async def factory():
            began.set()
            await gate.wait()
            return None
        first = await self.start(c, ("tenant", 2), factory)
        await began.wait()
        other = await self.start(c, tuple(["tenant", 2]), lambda: self.fail("second factory"))
        await self.cancel(other)
        self.assertFalse(first.done())
        gate.set()
        self.assertIsNone(await first)

    async def test_shared_failure_identity_and_retry(self):
        c = Coalescer()
        gate, began = self.event(), self.event()
        boom = LookupError("upstream missing")
        async def bad():
            began.set()
            await gate.wait()
            raise boom
        first = await self.start(c, "x", bad)
        await began.wait()
        second = await self.start(c, "x", lambda: self.fail("unused factory"))
        gate.set()
        for task in (first, second):
            with self.assertRaises(LookupError) as caught:
                await task
            self.assertIs(caught.exception, boom)
        self.assertEqual(c.pending_count, 0)
        async def good():
            return 7
        self.assertEqual(await c.run("x", good), 7)

    async def test_synchronous_factory_failure_shared_before_invocation(self):
        c = Coalescer()
        boom = ValueError("factory setup failed")
        calls = []
        def broken():
            calls.append(1)
            raise boom
        # Both caller tasks are queued before the shared factory task can run.
        first = asyncio.create_task(c.run("x", broken))
        second = asyncio.create_task(c.run("x", broken))
        self.tasks.extend([first, second])
        failures = await asyncio.gather(first, second, return_exceptions=True)
        self.assertEqual(calls, [1])
        self.assertTrue(all(value is boom for value in failures))
        with self.assertRaises(ValueError) as caught:
            await c.run("x", broken)
        self.assertIs(caught.exception, boom)
        self.assertEqual(calls, [1, 1])

    async def test_factory_cancellation_evicted(self):
        c = Coalescer()
        gate, began = self.event(), self.event()
        async def cancelled():
            began.set()
            await gate.wait()
            raise asyncio.CancelledError()
        first = await self.start(c, "x", cancelled)
        await began.wait()
        second = await self.start(c, "x", cancelled)
        gate.set()
        for task in (first, second):
            with self.assertRaises(asyncio.CancelledError):
                await task
        self.assertEqual(c.pending_count, 0)
        async def good():
            return "retried"
        self.assertEqual(await c.run("x", good), "retried")

    async def test_orphan_failure_is_observed_and_retryable(self):
        c = Coalescer()
        gate, began, finished = self.event(), self.event(), self.event()
        loop = asyncio.get_running_loop()
        previous = loop.get_exception_handler()
        reports = []
        loop.set_exception_handler(lambda loop, context: reports.append(context))
        try:
            async def bad():
                began.set()
                try:
                    await gate.wait()
                    raise RuntimeError("orphan")
                finally:
                    finished.set()
            first = await self.start(c, "orphan", bad)
            await began.wait()
            await self.cancel(first)
            self.assertEqual(c.pending_count, 1)
            gate.set()
            await finished.wait()
            await self.turn()
            self.assertEqual(c.pending_count, 0)
            self.assertEqual(reports, [])
            async def good():
                return 19
            self.assertEqual(await c.run("orphan", good), 19)
        finally:
            gate.set()
            await self.turn()
            loop.set_exception_handler(previous)

    async def test_reentrant_completion_starts_new_flight_without_stale_eviction(self):
        c = Coalescer()
        gate, began = self.event(), self.event()
        newer = []
        calls = []
        async def next_factory():
            calls.append("next")
            began.set()
            await gate.wait()
            return "new"
        async def old_factory():
            # This schedules a new caller before old waiter resumption/cleanup.
            asyncio.get_running_loop().call_soon(
                lambda: newer.append(asyncio.create_task(c.run("key", next_factory))))
            return "old"
        self.assertEqual(await c.run("key", old_factory), "old")
        await began.wait()
        self.tasks.extend(newer)
        self.assertEqual(c.pending_count, 1)
        follower = await self.start(c, "key", lambda: self.fail("new flight lost"))
        gate.set()
        self.assertEqual(await follower, "new")
        self.assertEqual(await newer[0], "new")
        self.assertEqual(calls, ["next"])

    async def test_unhashable_key_does_not_invoke_factory(self):
        c = Coalescer()
        with self.assertRaises(TypeError):
            await c.run([], lambda: self.fail("factory called for invalid key"))
        self.assertEqual(c.pending_count, 0)


if __name__ == "__main__":
    unittest.main()
