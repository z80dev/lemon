# Snapshot storage

The file is an object with a records map keyed by parcel ID. Each record has
id, destination, state and revision. Open accepts a nonexistent file as an empty
store. Every mutation writes a temporary file beside the snapshot, closes it,
and atomically renames it over the destination. A failed save does not publish
the candidate in memory. A single Store serializes mutation callbacks.
