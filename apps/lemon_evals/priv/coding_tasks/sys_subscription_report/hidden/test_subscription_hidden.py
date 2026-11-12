import pathlib
import random
import sqlite3
import unittest

ROOT = pathlib.Path.cwd()
COLUMNS = ['region', 'account_count', 'active_accounts', 'active_seats', 'mrr_cents']


class SubscriptionContract(unittest.TestCase):
    def setUp(self):
        self.conn = sqlite3.connect(':memory:')
        self.addCleanup(self.conn.close)
        self.conn.executescript((ROOT / 'schema.sql').read_text())
        self.query = (ROOT / 'subscription_report.sql').read_text()
        self.accounts = []
        self.events = []
        self.prices = {}

    def populate(self, accounts, prices, events):
        self.accounts = accounts
        self.events = events
        self.prices = prices
        self.conn.executemany('INSERT INTO accounts VALUES (?,?,?)', accounts)
        self.conn.executemany('INSERT INTO plans VALUES (?,?,?)',
                              [(key, f'Plan {key}', value) for key, value in prices.items()])
        self.conn.executemany('INSERT INTO subscription_events VALUES (?,?,?,?,?,?)', events)

    def expected(self, day):
        result = {}
        for account_id, _, region in self.accounts:
            label = 'Unassigned' if region is None else region
            totals = result.setdefault(label, [0, 0, 0, 0])
            totals[0] += 1
            eligible = [e for e in self.events if e[1] == account_id and e[2] <= day]
            if not eligible:
                continue
            event = max(eligible, key=lambda e: (e[2], e[0]))
            if event[3] == 'active':
                totals[1] += 1
                totals[2] += event[5]
                totals[3] += event[5] * self.prices[event[4]]
        return [(region, *totals) for region, totals in sorted(result.items())]

    def check_report(self, day):
        cursor = self.conn.execute(self.query, {'as_of': day})
        self.assertEqual([d[0] for d in cursor.description], COLUMNS)
        actual = cursor.fetchall()
        self.assertEqual(actual, self.expected(day))
        for row in actual:
            self.assertTrue(all(type(value) is int for value in row[1:]), row)

    def test_empty_and_eventless_accounts(self):
        self.populate([], {1: 100}, [])
        self.check_report('2025-01-01')
        self.accounts = [(1, 'A', None), (2, 'B', 'Unassigned'), (3, 'C', ''),
                         (4, 'D', 'a'), (5, 'E', 'A')]
        self.conn.executemany('INSERT INTO accounts VALUES (?,?,?)', self.accounts)
        self.check_report('2025-01-01')

    def test_dates_ties_status_transitions_and_plan_prices(self):
        accounts = [(i, f'Customer {i}', region) for i, region in enumerate(
            ['West', 'West', None, 'Unassigned', '', 'zero', 'zero', 'future', 'No history'], 1)]
        events = [
            (900, 1, '2024-01-01', 'active', 1, 99),
            (12, 1, '2025-01-31', 'active', 2, 3),
            (13, 1, '2025-02-01', 'paused', 2, 20),
            (14, 1, '2025-02-02', 'active', 1, 2),
            (99, 2, '2025-01-31', 'active', 2, 8),
            (100, 2, '2025-01-31', 'cancelled', 2, 8),
            (101, 2, '2025-03-01', 'active', 1, 5),
            (200, 3, '2025-01-01', 'active', 1, 1),
            (201, 4, '2025-01-01', 'active', 2, 2),
            (202, 5, '2025-01-01', 'paused', 2, 100),
            (203, 6, '2025-01-01', 'active', 2, 0),
            (204, 7, '2025-01-01', 'active', 3, 10),
            (205, 8, '2026-01-01', 'active', 2, 10),
        ]
        self.populate(accounts, {1: 1234, 2: 9876, 3: 0}, events)
        for day in ['2023-12-31', '2024-01-01', '2025-01-01', '2025-01-30',
                    '2025-01-31', '2025-02-01', '2025-02-02', '2025-03-01', '2026-01-01']:
            with self.subTest(day=day):
                self.check_report(day)
        self.conn.execute('UPDATE plans SET monthly_price_cents=7000 WHERE plan_id=1')
        self.prices[1] = 7000
        self.check_report('2025-01-31')

    def test_larger_scrambled_history_and_large_integer_revenue(self):
        rng = random.Random(331)
        accounts = [(i, f'A{i}', rng.choice([None, 'Unassigned', '', 'East', 'west', 'West', 'Éurope']))
                    for i in range(1, 90)]
        events = []
        event_ids = list(range(1, 1301))
        rng.shuffle(event_ids)
        for event_id in event_ids:
            account = rng.randrange(1, 80)
            day = rng.choice(['2024-12-31', '2025-01-01', '2025-01-15', '2025-01-31',
                              '2025-02-01', '2025-02-28', '2025-03-01', '2026-01-01'])
            events.append((event_id, account, day, rng.choice(['active', 'paused', 'cancelled']),
                           rng.choice([1, 2, 3]), rng.randrange(0, 1000)))
        self.populate(accounts, {1: 0, 2: 1499, 3: 1000000000}, events)
        for day in ['2024-12-30', '2024-12-31', '2025-01-14', '2025-01-15',
                    '2025-01-31', '2025-02-01', '2025-02-28', '2025-03-01', '2027-01-01']:
            with self.subTest(day=day):
                self.check_report(day)


if __name__ == '__main__':
    unittest.main()
