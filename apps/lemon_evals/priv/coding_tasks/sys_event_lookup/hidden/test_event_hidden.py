import pathlib
import random
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path.cwd()


class EventLookupContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = pathlib.Path(self.tmp.name) / 'events.db'
        self.conn = sqlite3.connect(self.db)
        self.addCleanup(self.conn.close)
        self.conn.executescript((ROOT / 'schema.sql').read_text())
        self.conn.execute('CREATE INDEX unrelated_kind ON events(kind)')
        # Simulate an installed older, incorrect definition of the required index.
        self.conn.execute('CREATE INDEX events_live_lookup ON events(tenant_id)')
        rng = random.Random(704)
        self.rows = []
        for event_id in range(1, 1801):
            tenant = rng.choice([-3, 1, 1, 1, 2, 7, 99])
            day = rng.randrange(1, 7)
            hour = rng.randrange(0, 24)
            minute = rng.choice([0, 15, 30, 45])
            stamp = f'2025-04-{day:02}T{hour:02}:{minute:02}:00Z'
            payload = None if event_id % 11 == 0 else f'payload {event_id} 雪'
            deleted = '' if event_id % 7 == 0 else ('2025-05-01T00:00:00Z' if event_id % 13 == 0 else None)
            self.rows.append((event_id, tenant, stamp, ['login', 'purchase', 'other'][event_id % 3], payload, deleted))
        # Explicit bounds, timestamp ties and deleted same-timestamp neighbors.
        self.rows.extend([
            (9001, 1, '2025-04-03T12:00:00Z', 'edge', 'start', None),
            (9002, 1, '2025-04-03T12:00:00Z', 'edge', 'tie', None),
            (9003, 1, '2025-04-03T12:00:00Z', 'edge', 'deleted', ''),
            (9004, 1, '2025-04-04T06:00:00Z', 'edge', 'end', None),
            (9005, 2, '2025-04-03T12:00:00Z', 'edge', 'other', None),
        ])
        self.conn.executemany('INSERT INTO events VALUES (?,?,?,?,?,?)', self.rows)
        self.conn.commit()
        self.install()
        self.query = (ROOT / 'event_lookup.sql').read_text()

    def install(self):
        result = subprocess.run(['sqlite3', str(self.db)],
                                input='.bail on\n.read indexes.sql\n', text=True,
                                cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        # EXPLAIN alone does not execute SQLite's schema-version check. Refresh
        # this connection after the separate CLI connection replaces the index.
        self.conn.execute('SELECT name FROM sqlite_master').fetchall()

    def expected(self, params):
        eligible = [r for r in self.rows if r[1] == params['tenant_id'] and r[5] is None
                    and params['start_at'] <= r[2] < params['end_at']]
        eligible.sort(key=lambda r: (r[2], r[0]), reverse=True)
        return [(r[0], r[2], r[3], r[4]) for r in eligible[:params['limit']]]

    def test_results_many_bounds_tenants_and_limits(self):
        ranges = [
            ('2025-04-03T12:00:00Z', '2025-04-04T06:00:00Z'),
            ('2025-04-03T12:00:00Z', '2025-04-03T12:00:01Z'),
            ('2025-04-01T00:00:00Z', '2025-04-07T00:00:00Z'),
            ('2025-04-04T06:00:00Z', '2025-04-04T06:00:00Z'),
            ('2025-04-05T00:00:00Z', '2025-04-02T00:00:00Z'),
            ('2024-01-01T00:00:00Z', '2024-01-02T00:00:00Z'),
        ]
        for tenant in [-3, 1, 2, 7, 99, 12345]:
            for start, end in ranges:
                for limit in [0, 1, 2, 17, 4000]:
                    params = dict(tenant_id=tenant, start_at=start, end_at=end, limit=limit)
                    with self.subTest(params=params):
                        self.assertEqual(self.conn.execute(self.query, params).fetchall(), self.expected(params))

    def test_plan_is_ordered_range_search(self):
        for tenant in [1, 12345]:
            for limit in [1, 20, 5000]:
                params = dict(tenant_id=tenant, start_at='2025-04-02T05:00:00Z',
                              end_at='2025-04-05T08:00:00Z', limit=limit)
                details = [row[3] for row in self.conn.execute('EXPLAIN QUERY PLAN ' + self.query, params)]
                searches = [d for d in details if 'SEARCH ' in d and 'events_live_lookup' in d]
                self.assertTrue(any('tenant_id=?' in d and 'occurred_at>?' in d and 'occurred_at<?' in d
                                    for d in searches), details)
                self.assertFalse(any('TEMP B-TREE' in d for d in details), details)

    def test_installer_reapplies_without_data_or_unrelated_index_loss(self):
        before = self.conn.execute('SELECT * FROM events ORDER BY event_id').fetchall()
        self.install()
        self.install()
        self.assertEqual(self.conn.execute('SELECT * FROM events ORDER BY event_id').fetchall(), before)
        self.assertIsNotNone(self.conn.execute("SELECT 1 FROM sqlite_master WHERE type='index' AND name='unrelated_kind'").fetchone())
        params = dict(tenant_id=1, start_at='2025-04-01T00:00:00Z', end_at='2025-04-07T00:00:00Z', limit=12)
        self.assertEqual(self.conn.execute(self.query, params).fetchall(), self.expected(params))


if __name__ == '__main__':
    unittest.main()
