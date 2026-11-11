# Settler
Streaming revisioned journal projections. CLI: `python3 -m settler.cli --now 100 < entries.jsonl`. Tests: `python3 -m unittest discover -s tests -v`.

## Reconciliation contract
`settler.model.Entry(account: str, entry_id: str, revision: int, amount: int, expires_at: int | None = None, void: bool = False)` is immutable. Inputs use those types; amounts may be negative or zero, revisions and times are integer ticks. `settler.reconcile.reconcile(entries, now)` accepts any iterable, including a one-shot generator, and returns a dict of account names to integer balances.

Logical identity is the pair `(account, entry_id)`. Select the entry with greatest revision per identity, irrespective of input ordering; if revisions tie, the last input occurrence wins. First select the winning revision, then exclude it if void or if its non-None expiry is <= now (no resurrection of older versions). Sum remaining amounts per account. Omit zero balances; dict iteration must be in lexicographic account order. Empty input returns `{}`. Never mutate entries or the supplied collection.

A negative now raises ValueError, even for empty input. Any input entry with empty account, empty entry_id or negative revision raises ValueError, even if it would lose revision selection or be expired/void. Exact exception messages are not API. No other input validation is required.
