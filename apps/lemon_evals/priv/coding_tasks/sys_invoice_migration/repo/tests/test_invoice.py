import pathlib
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.db = pathlib.Path(self.temp.name) / 'ledger.db'
        self.cli((ROOT / 'schema.sql').read_text() + (ROOT / 'sample.sql').read_text())

    def cli(self, sql):
        result = subprocess.run(['sqlite3', str(self.db)], input=sql, text=True,
                                cwd=ROOT, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def connect(self):
        conn = sqlite3.connect(self.db)
        conn.execute('PRAGMA foreign_keys = ON')
        self.addCleanup(conn.close)
        return conn

    def test_preserves_rows_and_normalizes(self):
        self.assertEqual(self.cli('.read migrate.sql\nPRAGMA foreign_keys;\n').strip(), '1')
        conn = self.connect()
        self.assertEqual(conn.execute('SELECT id, state, currency FROM invoices ORDER BY id').fetchall(),
                         [(11, 'open', 'USD'), (29, 'draft', 'USD'), (47, 'paid', 'EUR')])
        self.assertEqual(conn.execute('SELECT * FROM invoice_lines ORDER BY id').fetchall(),
                         [(61, 11, 'Consulting', 2, 1250), (82, 47, 'Support', 1, 900)])
        self.assertEqual(conn.execute('SELECT * FROM payments').fetchall(),
                         [(103, 47, 'wire-103', 900, '2025-01-21')])
        self.assertEqual(conn.execute('PRAGMA user_version').fetchone(), (2,))
        self.assertEqual(conn.execute('PRAGMA foreign_key_check').fetchall(), [])

    def test_constraints_and_rerun(self):
        self.cli('.read migrate.sql\n')
        self.cli('.read migrate.sql\n')
        conn = self.connect()
        for sql in ["UPDATE invoices SET total_cents=-1 WHERE id=11",
                    "UPDATE invoices SET state='sent' WHERE id=11",
                    'DELETE FROM invoices WHERE id=47',
                    'UPDATE invoice_lines SET invoice_id=999 WHERE id=61',
                    'UPDATE invoice_lines SET quantity=0 WHERE id=61',
                    'UPDATE payments SET amount_cents=0 WHERE id=103']:
            with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                conn.execute(sql)


if __name__ == '__main__':
    unittest.main()
