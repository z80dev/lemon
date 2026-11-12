# Credit rollup

A small back-office utility for grouping an exported credit ledger. No dependencies.

```python
from credit_rollup import rollup
with open("ledger.csv", newline="", encoding="utf-8") as stream:
    report = rollup(stream)
```

CSV columns are `account,currency,kind,amount,memo`. A sale increases net and a
refund decreases it. Reports contain per-account/currency groups and overall
totals; monetary report fields are two-decimal strings for direct JSON encoding.
`parser.py` owns row validation, `models.py` carries validated transactions, and
`report.py` owns aggregation. The current implementation predates quoted export
fields and strict import validation.

Run visible tests: `python3 -m unittest discover -s tests -v`.
