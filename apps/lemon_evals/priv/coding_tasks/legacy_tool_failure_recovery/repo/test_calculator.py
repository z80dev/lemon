import unittest
from calculator import average
class AverageTest(unittest.TestCase):
 def test_fraction(self): self.assertEqual(average([1,2]),1.5)
if __name__=='__main__': unittest.main()
