import unittest
from stock import Movement, Checkpoint, balances

class HistoryTests(unittest.TestCase):
    def test_revision_and_order(self):
        events=[Movement('a',1,'red',1,5),Movement('a',2,'blue',3,7),Movement('b',1,'red',2,-2)]
        self.assertEqual(balances(events,[Checkpoint('red',9),Checkpoint('blue',2),Checkpoint('blue',3)]),[-2,0,7])
    def test_empty(self):
        self.assertEqual(balances([], [Checkpoint('absent',0)]), [0])
        self.assertEqual(balances([], []), [])
