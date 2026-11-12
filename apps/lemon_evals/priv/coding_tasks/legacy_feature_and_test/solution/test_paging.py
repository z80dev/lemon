import unittest
from paging import paginate


class PagingTests(unittest.TestCase):
    def test_pages(self):
        items = list(range(8))
        self.assertEqual(paginate(items, 1, 3), [0, 1, 2])
        self.assertEqual(paginate(items, 2, 3), [3, 4, 5])
        self.assertEqual(paginate(items, 3, 3), [6, 7])
        self.assertEqual(paginate(items, 4, 3), [])
        self.assertEqual(paginate([], 1, 3), [])
        self.assertEqual(items, list(range(8)))

    def test_nonpositive_values(self):
        for page, size in [(0, 2), (-1, 2), (1, 0), (1, -1)]:
            with self.subTest(page=page, size=size):
                with self.assertRaises(ValueError):
                    paginate([1], page, size)
