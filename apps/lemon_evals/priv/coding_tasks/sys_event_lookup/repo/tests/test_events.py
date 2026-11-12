import pathlib
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class LookupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        db = pathlib.Path(self.tmp.name) / 'events.db'
        sql = ''.join((ROOT / name).read_text() for name in
                      ('schema.sql', 'sample.sql', 'indexes.sql'))
        result = subprocess.run(['sqlite3', str(db)], input=sql, text=True,
                                capture_output=True, cwd=ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.conn = sqlite3.connect(db)
        self.addCleanup(self.conn.close)
        self.query = (ROOT / 'event_lookup.sql').read_text()
        self.params = dict(tenant_id=10, start_at='2025-03-10T10:00:00Z',
                           end_at='2025-03-11T00:00:00Z', limit=20)

    def test_half_open_range_and_ties(self):
        self.assertEqual(self.conn.execute(self.query, self.params).fetchall(), [
            (3, '2025-03-10T12:30:00Z', 'logout', None),
            (2, '2025-03-10T12:30:00Z', 'purchase', '{"cents":500}')])
        self.params['limit'] = 1
        self.assertEqual(self.conn.execute(self.query, self.params).fetchone()[0], 3)
        self.params['limit'] = 0
        self.assertEqual(self.conn.execute(self.query, self.params).fetchall(), [])

    def test_range_search_uses_lookup_index_without_sort(self):
        details = [row[3] for row in self.conn.execute('EXPLAIN QUERY PLAN ' + self.query, self.params)]
        self.assertTrue(any('SEARCH ' in d and 'events_live_lookup' in d
                            and 'occurred_at>?' in d and 'occurred_at<?' in d for d in details), details)
        self.assertFalse(any('TEMP B-TREE' in d for d in details), details)


if __name__ == '__main__':
    unittest.main()
