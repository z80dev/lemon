import unittest
from rooms import Booking, Calendar

class Contract(unittest.TestCase):
    def test_complete_ordered_conflicts(self):
        records = [Booking('z','r',5,15), Booking('b','r',1,12), Booking('a','r',1,4),
                   Booking('gone','r',0,100,True), Booking('other','x',0,100),
                   Booking('left','r',-10,0), Booking('right','r',20,30)]
        calendar = Calendar(iter(records))
        self.assertEqual(calendar.conflicts('r',0,20), ['a','b','z'])
        self.assertEqual(calendar.bookings, records)
        self.assertEqual(calendar.conflicts('missing',0,20), [])
        self.assertEqual(calendar.conflicts('r',4,5), ['b'])
    def test_invalid_even_empty(self):
        for calendar in (Calendar([]), Calendar([Booking('a','r',0,5)])):
            for start,end in [(0,0),(3,2),(-1,-1)]:
                with self.assertRaises(ValueError): calendar.conflicts('r',start,end)
    def test_negative_and_containment(self):
        c=Calendar([Booking('a','r',-5,5)])
        self.assertEqual(c.conflicts('r',-10,-5), [])
        self.assertEqual(c.conflicts('r',5,8), [])
        self.assertEqual(c.conflicts('r',-1,1), ['a'])
        self.assertEqual(c.conflicts('r',-10,10), ['a'])
unittest.main()
