import unittest
from export import export_records
from lookup import lookup_value
from vendor.shelf_v2 import Store


class ExportTests(unittest.TestCase):
    def test_basic(self):
        store = Store([{"key": "b", "value": {"n": 2}}, {"key": "a", "value": {"n": 1}}])
        self.assertEqual(export_records(store), [{"key": "a", "value": {"n": 1}}, {"key": "b", "value": {"n": 2}}])
        self.assertEqual(lookup_value(store, "absent", "fallback"), "fallback")
