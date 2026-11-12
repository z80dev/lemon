# Durable journal replay

Repair the existing parser and replay engine without changing their public API. This is an ordered, transactional key/value journal, not a best-effort log reader. The crate has no dependencies.

## Public API

The crate root exports `Journal`, `Snapshot`, `ReplayError`, `ErrorKind`, and `replay`.
`Journal::new()`/`Default` start empty; `apply_line(&mut self, line: &str) -> Result<(), ErrorKind>` applies one record atomically; `snapshot(&self) -> Snapshot` exposes committed data only; `finish(self) -> Snapshot` discards an unfinished transaction. `Snapshot` has public `values: BTreeMap<String, String>` and `next_sequence: u64`. `replay(input: &str) -> Result<Snapshot, ReplayError>` processes `str::lines()` in order and finishes. `ReplayError { line: usize, kind: ErrorKind }` uses one-based physical line numbers, including blank lines. All public result/error types implement Debug, Clone, PartialEq, Eq.

## Wire format and ordering

An empty line is ignored. Other lines are exact pipe-separated records with no trimming:

* `n|BEGIN|tx`
* `n|PUT|key|value`
* `n|DELETE|key`
* `n|COMMIT|tx`
* `n|ROLLBACK|tx`

`n` is a canonical decimal integer in 1..u64::MAX (exclusive): ASCII digits, no sign or leading zero. Transaction IDs and keys are nonempty ASCII letters/digits/underscore/hyphen. A value is nonempty UTF-8 with no pipe, CR, or LF; spaces are preserved. Extra/missing fields, unknown operations, invalid tokens, and embedded CR/LF are `Format`. Empty input succeeds. `replay` accepts LF and CRLF via `str::lines`; direct `apply_line` receives a record without its terminator.

Sequence starts at 1 and every accepted nonempty record consumes exactly one. Parse errors take precedence over sequencing; a well-formed out-of-order record returns `Sequence { expected, actual }` before transaction-state checks. Rejected records change nothing, including pending writes and sequence, and may be retried. `next_sequence` is the next expected number, even when an unfinished transaction is discarded.

## Transactions

There is at most one open transaction. BEGIN while open returns `NestedTransaction`. PUT, DELETE, COMMIT, or ROLLBACK with none open returns `NoTransaction`. COMMIT/ROLLBACK must match the open ID exactly or return `TransactionMismatch`. PUT/DELETE affect only the pending transaction; last write wins, deleting an absent key is allowed, and DELETE after PUT cancels that value. COMMIT publishes all pending changes atomically; ROLLBACK discards them. Empty transactions are allowed. Snapshots never expose pending state. End-of-input discards pending changes (not their already consumed sequence numbers). Transactions can reuse IDs after closing. ErrorKind has exactly `Format`, `Sequence { expected: u64, actual: u64 }`, `NestedTransaction`, `NoTransaction`, `TransactionMismatch`.

Run `cargo test --offline`. Preserve behavior across incremental calls as well as whole-log replay.

## Implementation notes

Record parsing is allocation-free and completes before sequence/state validation. The engine increments the sequence only after an accepted transition. A transaction owns a write set of optional values; commit merges it, rollback drops it, and snapshots read only committed values.
