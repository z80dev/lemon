import unittest
from rooms import Booking, Calendar

class CalendarTests(unittest.TestCase):
    def test_room_scoping(self):
        calendar = Calendar([Booking('a', 'blue', 10, 20)])
        self.assertEqual(calendar.conflicts('blue', 12, 14), ['a'])
        self.assertEqual(calendar.conflicts('red', 12, 14), [])

    def test_touching(self):
        self.assertEqual(Calendar([Booking('a', 'blue', 10, 20)]).conflicts('blue', 20, 30), [])
