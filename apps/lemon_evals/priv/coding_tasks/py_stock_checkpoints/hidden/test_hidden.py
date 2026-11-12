import math
import random
import unittest
from stock import Movement, Checkpoint, balances

class CountedTime(int):
    count=0
    budget=0
    def tick(self):
        CountedTime.count += 1
        if CountedTime.count > CountedTime.budget:
            raise AssertionError('timestamp comparison budget exceeded; batch still rescans events')
    def __lt__(self, other):
        self.tick()
        return int.__lt__(self,other)
    def __le__(self, other):
        self.tick()
        return int.__le__(self,other)
    def __gt__(self, other):
        self.tick()
        return int.__gt__(self,other)
    def __ge__(self, other):
        self.tick()
        return int.__ge__(self,other)

def oracle(events,points):
    winners={}
    for event in events:
        if event.event_id not in winners or event.revision >= winners[event.event_id].revision:
            winners[event.event_id]=event
    return [sum(e.delta for e in winners.values() if e.sku==p.sku and e.at<=p.at) for p in points]

class Contract(unittest.TestCase):
    def test_revisions_move_and_tie(self):
        events=[Movement('a',2,'x',10,9),Movement('b',0,'x',0,4),Movement('a',1,'z',-1,500),Movement('a',2,'y',-3,-8),Movement('b',1,'x',0,2)]
        points=[Checkpoint('y',-3),Checkpoint('y',-4),Checkpoint('x',0),Checkpoint('z',100),Checkpoint('y',99),Checkpoint('x',0)]
        original=events[:]
        self.assertEqual(balances(iter(events),iter(points)),[-8,0,2,0,-8,2])
        self.assertEqual(events,original)
    def test_seeded_differential(self):
        r=random.Random(710)
        for _ in range(40):
            events=[Movement(str(r.randrange(16)),r.randrange(4),r.choice('abc'),r.randrange(-15,16),r.randrange(-20,21)) for _ in range(r.randrange(100))]
            points=[Checkpoint(r.choice('abcd'),r.randrange(-20,21)) for _ in range(30)]
            self.assertEqual(balances(events,points),oracle(events,points))
        self.assertEqual(balances(iter([]),iter([])),[])
    def test_large_comparison_budget(self):
        n=5000
        CountedTime.count=0
        CountedTime.budget=24*(2*n)*math.ceil(math.log2(2*n+2))
        order=list(range(n)); random.Random(10).shuffle(order)
        events=[Movement(str(i),0,'only',CountedTime(i),1) for i in order]
        points=[Checkpoint('only',CountedTime(i)) for i in reversed(range(n))]
        self.assertEqual(balances(events,points),list(range(n,0,-1)))
        self.assertLessEqual(CountedTime.count,CountedTime.budget)
unittest.main()
