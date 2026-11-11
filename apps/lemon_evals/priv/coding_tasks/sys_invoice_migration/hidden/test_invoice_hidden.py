import pathlib
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path.cwd()
TABLES = ('invoices', 'invoice_lines', 'payments')


class InvoiceContract(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.db = pathlib.Path(self.tmp.name) / 'ledger.db'
        self.run_sql((ROOT / 'schema.sql').read_text() + (ROOT / 'sample.sql').read_text())

    def run_sql(self, text, success=True):
        result = subprocess.run(['sqlite3', str(self.db)], input=text, text=True,
                                cwd=ROOT, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, 'invalid legacy data was accepted')
        return result.stdout

    def conn(self):
        conn = sqlite3.connect(self.db)
        conn.execute('PRAGMA foreign_keys=ON')
        self.addCleanup(conn.close)
        return conn

    def snapshot(self):
        with sqlite3.connect(self.db) as conn:
            return (conn.execute("SELECT type,name,tbl_name,sql FROM sqlite_master ORDER BY name").fetchall(),
                    [conn.execute('SELECT * FROM ' + name + ' ORDER BY id').fetchall()
                     for name in TABLES], conn.execute('PRAGMA user_version').fetchone())

    def test_all_values_and_unrelated_data_survive(self):
        self.run_sql("""
CREATE TABLE notes (key TEXT PRIMARY KEY, value BLOB);
INSERT INTO notes VALUES ('audit', x'00ff10');
INSERT INTO invoices VALUES (91,'inv-11','  customer  ','open','   ',0,'not-a-date');
INSERT INTO invoice_lines VALUES (95,91,'  retained  ',3,0);
INSERT INTO payments VALUES (98,91,'',1,'arbitrary');
""")
        before = self.snapshot()[1]
        output = self.run_sql('.read migrate.sql\nPRAGMA foreign_keys;\n')
        self.assertEqual(output.strip(), '1')
        conn = self.conn()
        expected = [tuple(row[:3]) + ('open' if row[3] == 'sent' else row[3],
                    (row[4] or '').strip(' ').upper() or 'USD') + tuple(row[5:])
                    for row in before[0]]
        self.assertEqual(conn.execute('SELECT * FROM invoices ORDER BY id').fetchall(), expected)
        for name, rows in zip(TABLES[1:], before[1:]):
            self.assertEqual(conn.execute('SELECT * FROM ' + name + ' ORDER BY id').fetchall(), rows)
        self.assertEqual(conn.execute('SELECT * FROM notes').fetchall(), [('audit', bytes.fromhex('00ff10'))])
        self.assertEqual(conn.execute('PRAGMA foreign_key_check').fetchall(), [])
        self.assertEqual(conn.execute('PRAGMA user_version').fetchone(), (2,))

    def test_new_constraints_on_insert_and_update(self):
        self.run_sql('.read migrate.sql\n')
        conn = self.conn()
        invalid = {
            'invoices': {
                'invoice_number': [None, 'INV-47'],
                'customer_code': [None, '', '   '],
                'state': [None, 'sent', 'OPEN', 'cancelled'],
                'currency': [None, '', 'usd', 'US', 'USDD', 'U1D', 'ÉUR', ' USD'],
                'total_cents': [None, -1, 1.25, 'n/a'],
                'issued_on': [None],
            },
            'invoice_lines': {
                'invoice_id': [None, 999], 'description': [None, '', '   '],
                'quantity': [None, 0, -2, 1.5, 'bad'],
                'unit_price_cents': [None, -1, 0.5, 'bad'],
            },
            'payments': {
                'invoice_id': [None, 999], 'external_ref': [None, 'wire-103'],
                'amount_cents': [None, 0, -1, 1.25, 'bad'], 'paid_on': [None],
            },
        }
        target = {'invoices': 11, 'invoice_lines': 61, 'payments': 103}
        for table, columns in invalid.items():
            for column, values in columns.items():
                for value in values:
                    with self.subTest(table=table, column=column, value=value):
                        # Duplicate external_ref needs a different existing payment.
                        if table == 'payments' and column == 'external_ref' and value == 'wire-103':
                            conn.execute("INSERT INTO payments VALUES (200,11,'other',2,'today')")
                            row_id = 200
                        else:
                            row_id = target[table]
                        try:
                            with self.assertRaises(sqlite3.IntegrityError):
                                conn.execute(f'UPDATE {table} SET {column}=? WHERE id=?', (value, row_id))
                        finally:
                            conn.rollback()
        inserts = [
            "INSERT INTO invoices VALUES (200,'INV-11','X','open','USD',0,'x')",
            "INSERT INTO invoices VALUES (11,'different','X','open','USD',0,'x')",
            "INSERT INTO invoice_lines VALUES (200,999,'x',1,0)",
            "INSERT INTO invoice_lines VALUES (200,11,'x',1.5,0)",
            "INSERT INTO payments VALUES (200,999,'new',1,'x')",
            "INSERT INTO payments VALUES (200,11,'wire-103',1,'x')",
        ]
        for sql in inserts:
            with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                conn.execute(sql)
        conn.rollback()
        for sql in ['DELETE FROM invoices WHERE id=11', 'DELETE FROM invoices WHERE id=47',
                    'UPDATE invoices SET id=999 WHERE id=11', 'UPDATE invoices SET id=999 WHERE id=47']:
            with self.subTest(sql=sql), self.assertRaises(sqlite3.IntegrityError):
                conn.execute(sql)
        conn.rollback()
        conn.execute("INSERT INTO invoices VALUES (200,'inv-11','X','open','GBP','0','x')")
        conn.execute("INSERT INTO invoice_lines VALUES (200,200,'x','2','0')")
        conn.execute("INSERT INTO payments VALUES (200,200,'WIRE-103','1','x')")
        conn.execute('DELETE FROM payments WHERE id=200')
        conn.execute('DELETE FROM invoice_lines WHERE id=200')
        conn.execute('DELETE FROM invoices WHERE id=200')
        conn.commit()

    def test_rerun_with_new_rows(self):
        self.run_sql('.read migrate.sql\n')
        self.run_sql("""PRAGMA foreign_keys=ON;
INSERT INTO invoices VALUES (500,'INV-500','new','open','CAD',150,'2026-01-01');
INSERT INTO invoice_lines VALUES (700,500,'new line',1,150);
INSERT INTO payments VALUES (900,500,'new payment',150,'2026-01-02');
""")
        before = self.snapshot()[1]
        self.run_sql('.read migrate.sql\n.read migrate.sql\n')
        self.assertEqual(self.snapshot()[1], before)
        conn = self.conn()
        self.assertEqual(conn.execute('PRAGMA foreign_key_check').fetchall(), [])
        with self.assertRaises(sqlite3.IntegrityError):
            conn.execute('UPDATE payments SET amount_cents=0 WHERE id=900')

    def test_empty_ledger(self):
        self.run_sql('DELETE FROM invoice_lines; DELETE FROM payments; DELETE FROM invoices;')
        self.run_sql('.read migrate.sql\n.read migrate.sql\n')
        self.assertEqual(self.snapshot()[1], [[], [], []])

    def test_invalid_legacy_data_rolls_back_everything(self):
        corruptions = [
            "UPDATE invoices SET currency='U1D' WHERE id=11;",
            'UPDATE invoices SET total_cents=-1 WHERE id=47;',
            "UPDATE invoices SET invoice_number='INV-11' WHERE id=47;",
            'UPDATE invoice_lines SET quantity=0 WHERE id=61;',
            'UPDATE invoice_lines SET invoice_id=999 WHERE id=61;',
            'UPDATE payments SET amount_cents=0 WHERE id=103;',
            'UPDATE payments SET invoice_id=999 WHERE id=103;',
        ]
        for corruption in corruptions:
            with self.subTest(corruption=corruption):
                self.db.unlink()
                self.run_sql((ROOT / 'schema.sql').read_text() + (ROOT / 'sample.sql').read_text() + corruption)
                before = self.snapshot()
                self.run_sql('.read migrate.sql\n', success=False)
                self.assertEqual(self.snapshot(), before)


if __name__ == '__main__':
    unittest.main()
