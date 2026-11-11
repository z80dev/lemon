import unittest
from analyze import analyze


class AnalyzeTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(analyze(iter(["\n"])), {
            "completed": 0, "succeeded": 0, "failed": 0, "recovered": 0,
            "pending": 0, "malformed": 0, "error_counts": {}, "failures": [],
        })
