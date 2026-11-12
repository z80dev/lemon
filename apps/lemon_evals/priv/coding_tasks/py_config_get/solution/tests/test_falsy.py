import unittest
from configpeek.lookup import resolve


class FalsyTests(unittest.TestCase):
    def test_present_values(self):
        for value in (None, False, 0, "", [], {}):
            with self.subTest(value=value):
                self.assertEqual(resolve({"setting": value}, "setting"), value)

    def test_invalid_path(self):
        for path in ("", ".x", "x.", "x..y"):
            with self.assertRaisesRegex(ValueError, "^invalid key path$"):
                resolve({}, path)
