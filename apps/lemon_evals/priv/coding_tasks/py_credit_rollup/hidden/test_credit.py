import csv
import io
import json
import random
import unittest
from decimal import localcontext
from credit_rollup import RowError, rollup

HEADER = "account,currency,kind,amount,memo\n"


def report(text):
    source = io.StringIO(text, newline="")
    result = rollup(source)
    assert not source.closed
    return result


class CreditContracts(unittest.TestCase):
    def error(self, text, record, line, reason):
        with self.assertRaises(RowError) as caught:
            report(text)
        error = caught.exception
        self.assertIsInstance(error, ValueError)
        self.assertEqual((error.record, error.line, error.reason), (record, line, reason))
        self.assertEqual(str(error), f"record {record}, line {line}: {reason}")

    def test_quoted_fields_and_order(self):
        result = report(HEADER + 'Z,USD,refund,0.10,"memo, with ""quotes""\nand a line"\n A , EUR , sale , 001.2 ,x\nZ,USD,sale,0.03,x\nA,USD,sale,0,x\n')
        self.assertEqual(result, {"groups": [
            {"account": "A", "currency": "EUR", "count": 1, "sales": "1.20", "refunds": "0.00", "net": "1.20"},
            {"account": "A", "currency": "USD", "count": 1, "sales": "0.00", "refunds": "0.00", "net": "0.00"},
            {"account": "Z", "currency": "USD", "count": 2, "sales": "0.03", "refunds": "0.10", "net": "-0.07"}],
            "totals": {"count": 4, "sales": "1.23", "refunds": "0.10", "net": "1.13"}})
        self.assertEqual(json.loads(json.dumps(result)), result)

    def test_zero_and_blank(self):
        self.assertEqual(report(HEADER + "\n\r\n"), {"groups": [], "totals": {"count": 0, "sales": "0.00", "refunds": "0.00", "net": "0.00"}})
        self.assertEqual(report(HEADER + "A,USD,refund,0.00,x\n")["totals"]["net"], "0.00")
        self.error(HEADER + ",,,,\n", 1, 2, "account is empty")

    def test_physical_and_logical_positions(self):
        self.error(HEADER + '\nA,USD,sale,1,"two\nlines"\n\nB,USD,sale,no,x\n', 2, 6, "invalid amount")
        self.error(HEADER + '\nA,USD,sale,1,x\n\nB,USD,sale,2,"unterminated\n', 2, 5, "invalid CSV")
        self.error(HEADER + 'A,USD,sale,1,"memo"junk\n', 1, 2, "invalid CSV")
        self.error('"broken\n', 0, 1, "invalid CSV")

    def test_headers(self):
        for text in ("", "\n", "account,currency,kind,amount,memo,extra\n", "\ufeff" + HEADER, HEADER.replace("account", " account"), HEADER.replace("currency,kind", "kind,currency")):
            with self.subTest(text=text):
                self.error(text, 0, 1, "expected header account,currency,kind,amount,memo")

    def test_validation_priority(self):
        cases = [("A,USD,sale,1", "expected 5 fields"), ("A,USD,sale,1,x,y", "expected 5 fields"), (" ,bad,bad,bad,x", "account is empty"), ("A,usd,bad,bad,x", "invalid currency"), ("A,US1,sale,1,x", "invalid currency"), ("A,USＤ,sale,1,x", "invalid currency"), ("A,USD,SALE,bad,x", "invalid kind")]
        for row, reason in cases:
            with self.subTest(row=row):
                self.error(HEADER + row + "\n", 1, 2, reason)
        for amount in ("", "-0", "+1", "1.234", "1.", ".25", "1e2", "NaN", "Infinity", "1_000", "１２", "999999999999.991", "1000000000000"):
            with self.subTest(amount=amount):
                self.error(HEADER + f"A,USD,sale,{amount},x\n", 1, 2, "invalid amount")

    def test_exact_large_values_and_context(self):
        text = HEADER + "A,USD,sale,999999999999.99,x\n" * 50 + "A,USD,refund,0.01,x\n"
        with localcontext() as context:
            context.prec = 4
            result = report(text)
        self.assertEqual(result["totals"], {"count": 51, "sales": "49999999999999.50", "refunds": "0.01", "net": "49999999999999.49"})

    def test_deterministic_mixed_ledger(self):
        rng = random.Random(2081)
        rows = []
        expected = {}
        for _ in range(220):
            account = rng.choice(["a", "A", "z, ltd", "雪"])
            currency = rng.choice(["EUR", "USD", "JPY"])
            kind = rng.choice(["sale", "refund"])
            cents = rng.randrange(100000)
            rows.append([account, currency, kind, f"{cents // 100}.{cents % 100:02d}", "audit\nentry"])
            bucket = expected.setdefault((account, currency), [0, 0, 0])
            bucket[0] += 1
            bucket[1 if kind == "sale" else 2] += cents
        stream = io.StringIO(newline="")
        writer = csv.writer(stream)
        writer.writerow(["account", "currency", "kind", "amount", "memo"])
        writer.writerows(rows)
        actual = report(stream.getvalue())
        def money(cents):
            return ("-" if cents < 0 else "") + f"{abs(cents)//100}.{abs(cents)%100:02d}"
        groups = []
        for (account, currency), (count, sales, refunds) in sorted(expected.items()):
            groups.append(dict(account=account, currency=currency, count=count, sales=money(sales), refunds=money(refunds), net=money(sales-refunds)))
        self.assertEqual(actual["groups"], groups)
        sales = sum(bucket[1] for bucket in expected.values())
        refunds = sum(bucket[2] for bucket in expected.values())
        self.assertEqual(actual["totals"], dict(count=220, sales=money(sales), refunds=money(refunds), net=money(sales-refunds)))

    def test_stream_current_position(self):
        stream = io.StringIO("ignored\n" + HEADER + "A,USD,sale,1,x\n")
        stream.readline()
        self.assertEqual(rollup(stream)["totals"]["sales"], "1.00")
        self.assertFalse(stream.closed)
