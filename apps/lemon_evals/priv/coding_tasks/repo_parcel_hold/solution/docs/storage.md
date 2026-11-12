# Snapshot storage

The file is an object with a records map keyed by parcel ID. Each record has
id, destination, state and revision. Open accepts a nonexistent file as an empty
store. Every mutation writes a temporary file beside the snapshot, closes it,
and atomically renames it over the destination. A failed save does not publish
the candidate in memory. A single Store serializes mutation callbacks.

Optional hold_reason records the normalized hold reason; absent means no hold,
so pre-hold snapshots remain readable. Hold creation/removal increments revision
exactly once. Idempotent requests do not write a new snapshot. A failed save
leaves both the in-memory parcel and the old snapshot unchanged, including
hold metadata. Returned holds and caller inputs are copied at storage boundaries.
