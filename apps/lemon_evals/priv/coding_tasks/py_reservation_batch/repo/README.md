# Stockroom ledger

The packing desk tracks available and reserved units per SKU in memory.
`Ledger({"tea": 10})` creates a private stock snapshot; `reserve` and
`release` return the ledger version. Snapshots contain immutable `Stock` values.

## Atomic order batches

Use `apply_batch(iterable_of_operations, expected_version=None)` to reserve
or release several SKUs as one transaction. The existing bulk helper processes operations individually; upgrade it to
transactional behavior as described in the task. `VersionConflict` exposes `expected` and `actual`.

Run the visible suite from this directory:

    python3 -m unittest discover -s tests -v
