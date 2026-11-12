import unittest
from unittest.mock import MagicMock, call

from export import export_records
from lookup import lookup_value
from manifest import build_manifest
from vendor.shelf_v2 import Entry, Page, Store


class ExportTests(unittest.TestCase):
    def test_basic(self):
        store = Store([{"key": "b", "value": {"n": 2}}, {"key": "a", "value": {"n": 1}}])
        self.assertEqual(export_records(store), [
            {"key": "a", "value": {"n": 1}}, {"key": "b", "value": {"n": 2}},
        ])
        self.assertEqual(lookup_value(store, "absent", "fallback"), "fallback")
        self.assertEqual(store.active_sessions, 0)

    def test_pagination_prefix_tombstones_and_bytes(self):
        rows = [{"checkpoint": True}] * 3 + [
            {"key": "app/dead", "deleted": True, "raw_payload": b"not-json"},
            {"key": "app/z", "value": [None, False]},
            {"key": "other/a", "value": 3},
            {"checkpoint": True},
            {"key": "app/a", "raw_payload": ' {"text": "雪"} '.encode("utf-8"),
             "etag": "private-metadata"},
        ]
        for size in (1, 2, 5, 100):
            with self.subTest(page_size=size):
                store = Store(iter(rows))
                self.assertEqual(export_records(store, "app/", size), [
                    {"key": "app/a", "value": {"text": "雪"}},
                    {"key": "app/z", "value": [None, False]},
                ])
                self.assertEqual(set(store.scan_sizes), {size})
                self.assertEqual(store.active_sessions, 0)

    def test_only_none_ends_an_opaque_cursor_scan(self):
        store = MagicMock()
        session = store.session.return_value.__enter__.return_value
        session.scan.side_effect = [
            Page((), ""),
            Page((Entry("p/a", b"null", "etag", False),), None),
        ]
        self.assertEqual(export_records(store, "p/", 3), [{"key": "p/a", "value": None}])
        self.assertEqual(session.scan.call_args_list, [
            call(prefix="p/", cursor=None, page_size=3),
            call(prefix="p/", cursor="", page_size=3),
        ])
        store.session.return_value.__exit__.assert_called_once()

    def test_lookup_preserves_all_present_json_values(self):
        values = [None, False, 0, "", "café", [], {}, [1, None], {"a": True}]
        store = Store([{"key": str(i), "value": value} for i, value in enumerate(values)] + [
            {"key": "deleted", "value": 42, "deleted": True},
        ])
        marker = object()
        for index, value in enumerate(values):
            with self.subTest(value=value):
                self.assertEqual(lookup_value(store, str(index), marker), value)
                self.assertEqual(store.active_sessions, 0)
        self.assertIs(lookup_value(store, "missing", marker), marker)
        self.assertIs(lookup_value(store, "deleted", marker), marker)
        self.assertIsNone(lookup_value(store, "missing"))
        self.assertEqual(store.active_sessions, 0)

    def test_manifest_uses_all_live_values_and_canonical_utf8_sizes(self):
        values = [None, False, 0, "", "café", {"z": [1, False], "a": "雪"},
                  [1, None], True, 1.25]
        canonical = ["null", "false", "0", '""', '"café"',
                     '{"a":"雪","z":[1,false]}', '[1,null]', "true", "1.25"]
        rows = [{"key": "app/%02d" % i, "value": value}
                for i, value in enumerate(values)]
        rows[5] = {"key": "app/05", "raw_payload":
                   ' { "z" : [1, false], "a" : "\\u96ea" } '.encode("utf-8")}
        store = Store([{"checkpoint": True}] * 3 + list(reversed(rows)) + [
            {"key": "other/x", "value": "excluded"},
            {"key": "app/dead", "deleted": True, "raw_payload": b"invalid"},
        ])
        self.assertEqual(build_manifest(store, "app/"), {
            "count": len(values),
            "keys": ["app/%02d" % i for i in range(len(values))],
            "total_bytes": sum(len(text.encode("utf-8")) for text in canonical),
        })
        self.assertEqual(store.active_sessions, 0)
        self.assertGreater(len(store.scan_sizes), 1)

    def test_empty_results(self):
        for rows in ([], [{"checkpoint": True}] * 5,
                     [{"key": "gone", "value": 1, "deleted": True}]):
            with self.subTest(rows=rows):
                store = Store(rows)
                self.assertEqual(export_records(store), [])
                self.assertEqual(build_manifest(store), {"count": 0, "keys": [], "total_bytes": 0})
                self.assertEqual(store.active_sessions, 0)

    def test_decode_errors_propagate_and_close_every_session(self):
        operations = (export_records, build_manifest, lambda store: lookup_value(store, "bad"))
        for payload in (b"not-json", b"\xff"):
            for operation in operations:
                with self.subTest(payload=payload, operation=operation):
                    store = Store([{"key": "bad", "raw_payload": payload}])
                    with self.assertRaises(ValueError):
                        operation(store)
                    self.assertEqual(store.active_sessions, 0)

    def test_invalid_page_size_propagates_and_closes_session(self):
        for size in (0, -1, True, 1.5):
            with self.subTest(page_size=size):
                store = Store([])
                with self.assertRaises(ValueError):
                    export_records(store, page_size=size)
                self.assertEqual(store.active_sessions, 0)
