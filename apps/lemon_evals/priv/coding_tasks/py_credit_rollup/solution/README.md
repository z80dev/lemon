# Credit rollup

Stdlib-only ledger import: `from credit_rollup import rollup, RowError`.
Pass an open text stream (use `newline=""` for files). The importer consumes its
current position without closing it. Run `python3 -m unittest discover -s tests -v`.

## Input and validation

The exact CSV header is `account,currency,kind,amount,memo`. Standard strict CSV
quoting supports commas, doubled quotes and embedded newlines. Completely blank
records are ignored. Other records require five fields. Account, currency, kind,
and amount are stripped; memo is ignored. Validation checks field count, nonempty
account, three ASCII uppercase currency letters, `sale`/`refund`, then amount.
Unsigned ASCII amounts allow integer, one or two decimal digits, leading zeroes,
and zero, up to 999999999999.99. Decimal parses money; integer cents aggregate it
without dependence on the caller's decimal precision.

`RowError` is a ValueError with `record`, `line`, `reason`: the logical data record
number ignores blank records; the physical start line includes blank and embedded
newlines. Its message is `record N, line L: REASON`. Header errors use record 0,
line 1. Reasons are `expected header account,currency,kind,amount,memo`,
`expected 5 fields`, `account is empty`, `invalid currency`, `invalid kind`,
`invalid amount`, or `invalid CSV`. The first failure stops import.

## Output

`{"groups": [...], "totals": {...}}` is JSON-ready. Groups have account,
currency, count, sales, refunds, net and sort by (account, currency). Totals omit
the grouping keys and deliberately combine currencies without conversion. All
money is a fixed two-decimal string; count includes zero-valued transactions.
Sales/refunds sum independently; net subtracts refunds and never prints negative
zero. Header-only input has an empty groups list and zero totals.

`models.py` defines validated records, `parser.py` validates CSV and money, and
`report.py` performs aggregation and serialization.
