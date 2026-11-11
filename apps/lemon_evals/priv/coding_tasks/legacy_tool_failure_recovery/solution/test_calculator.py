import unittest
from calculator import average


class AverageTest(unittest.TestCase):
    def test_fraction(self):
        self.assertEqual(average([1, 2]), 1.5)

    def test_mixed_signs(self):
        self.assertEqual(average([-1, 2]), 0.5)

    def test_empty(self):
        with self.assertRaises(ValueError):
            average([])


if __name__ == '__main__':
    unittest.main()
