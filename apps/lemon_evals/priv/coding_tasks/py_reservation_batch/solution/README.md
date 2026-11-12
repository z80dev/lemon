# Stockroom ledger

The packing desk tracks available and reserved units per SKU in memory.
`Ledger({"tea": 10})` creates a private stock snapshot; `reserve` and
`release` return the ledger version. Snapshots contain immutable `Stock` values.

## Atomic order batches

Use `apply_batch(iterable_of_operations, expected_version=None)` to reserve
or release several SKUs as one transaction. Operations run in order on staged
stock. Any validation, stock, version, or iterator error leaves all stock and
the version untouched. A nonempty commit increments the version once; an empty
batch does not. `VersionConflict` exposes `expected` and `actual`.

Run the visible suite from this directory:

    python3 -m unittest discover -s tests -v
