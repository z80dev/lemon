import asyncio
import unittest
from flights import Coalescer


class CoalescerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tasks = []
        self.gates = []

    async def asyncTearDown(self):
        for gate in self.gates:
            gate.set()
        for task in self.tasks:
            if not task.done():
                task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)

    def gate(self):
        event = asyncio.Event()
        self.gates.append(event)
        return event

    async def start(self, coalescer, key, factory):
        entered = asyncio.Event()
        async def call():
            entered.set()
            return await coalescer.run(key, factory)
        task = asyncio.create_task(call())
        self.tasks.append(task)
        await entered.wait()
        return task

    async def test_shared_identity_and_not_a_cache(self):
        c = Coalescer()
        release, began = self.gate(), asyncio.Event()
        calls = []
        value = object()
        async def factory():
            calls.append(1)
            began.set()
            await release.wait()
            return value
        first = await self.start(c, "catalog", factory)
        await began.wait()
        second = await self.start(c, "catalog", factory)
        self.assertEqual(c.pending_count, 1)
        release.set()
        self.assertIs(await first, value)
        self.assertIs(await second, value)
        self.assertEqual(calls, [1])
        self.assertEqual(c.pending_count, 0)
        self.assertIs(await c.run("catalog", factory), value)
        self.assertEqual(calls, [1, 1])

    async def test_cancelling_first_waiter_keeps_other_waiter_alive(self):
        c = Coalescer()
        release, began = self.gate(), asyncio.Event()
        async def factory():
            began.set()
            await release.wait()
            return 42
        first = await self.start(c, "profile", factory)
        await began.wait()
        second = await self.start(c, "profile", factory)
        first.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await first
        self.assertFalse(second.done())
        self.assertEqual(c.pending_count, 1)
        release.set()
        self.assertEqual(await second, 42)

    async def test_distinct_keys_do_not_block_each_other(self):
        c = Coalescer()
        release, began = self.gate(), asyncio.Event()
        async def blocked():
            began.set()
            await release.wait()
            return "slow"
        async def immediate():
            return "fast"
        slow = await self.start(c, "a", blocked)
        await began.wait()
        self.assertEqual(await c.run("b", immediate), "fast")
        self.assertFalse(slow.done())
        release.set()
        self.assertEqual(await slow, "slow")


if __name__ == "__main__":
    unittest.main()
