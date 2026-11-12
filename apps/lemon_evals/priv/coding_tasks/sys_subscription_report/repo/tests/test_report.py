import pathlib
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
COLUMNS = ['region', 'account_count', 'active_accounts', 'active_seats', 'mrr_cents']


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        db = pathlib.Path(self.tmp.name) / 'subscriptions.db'
        sql = (ROOT / 'schema.sql').read_text() + (ROOT / 'sample.sql').read_text()
        result = subprocess.run(['sqlite3', str(db)], input=sql, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.conn = sqlite3.connect(db)
        self.addCleanup(self.conn.close)
        self.query = (ROOT / 'subscription_report.sql').read_text()

    def report(self, day):
        cursor = self.conn.execute(self.query, {'as_of': day})
        self.assertEqual([d[0] for d in cursor.description], COLUMNS)
        return cursor.fetchall()

    def test_inclusive_day_and_latest_tie(self):
        self.assertEqual(self.report('2025-02-01'), [
            ('North', 2, 1, 3, 7500),
            ('South', 2, 0, 0, 0),
            ('Unassigned', 1, 1, 4, 0)])

    def test_future_history_does_not_hide_old_state(self):
        self.assertEqual(self.report('2025-01-31'), [
            ('North', 2, 2, 3, 3000),
            ('South', 2, 0, 0, 0),
            ('Unassigned', 1, 0, 0, 0)])

    def test_before_all_history(self):
        self.assertEqual(self.report('2024-01-01'), [
            ('North', 2, 0, 0, 0), ('South', 2, 0, 0, 0), ('Unassigned', 1, 0, 0, 0)])


if __name__ == '__main__':
    unittest.main()
