# Local shelf dependency upgrade
Migrate export.py, lookup.py and manifest.py from vendor.shelf_v1 to
vendor.shelf_v2. Delete vendor/shelf_v1.py after migrating every consumer;
do not add aliases, compatibility shims, or change the v2 implementation.
Both versions are vendored; no installation or network access is needed.
Add unittest regression tests and update this README's usage notes.

The new Store(records) accepts an iterable of record dictionaries.
Regular records contain key, value, optional deleted and etag fields;
{"checkpoint": true} records model empty provider partitions.
Store.session() is a context manager. Session.scan(*, prefix="",
cursor=None, page_size=2) returns Page(entries, next_cursor). Entries
contain key, UTF-8 JSON payload bytes, etag and deleted. The opaque
cursor MUST be passed unchanged; only None means end, even if entries
is empty. Tombstones consume page space but are not exported. A session
must be open for scan/read; always close it, including on decoding errors.
Session.read(key) raises MissingKey for missing/deleted keys; a stored
JSON null is present, and must not be confused with absence.

Preserve these application APIs, now accepting shelf_v2.Store:
* export_records(store, prefix="", page_size=2): return all live matching
  {"key": key, "value": decoded_value} records, sorted by key. Respect
  caller page_size and prefix, traverse empty pages, and do not leak
  tombstones or metadata into the result.
* lookup_value(store, key, default=None): decode a present value; return
  default ONLY for MissingKey. Preserve false, zero, empty strings and
  JSON null. Decode errors must propagate as ValueError.
* build_manifest(store, prefix=""): {"count": live_count, "keys": sorted
  live_keys, "total_bytes": sum of len(json.dumps(value, ensure_ascii=False,
  sort_keys=True, separators=(",", ":")).encode("utf-8")) over live values}.
  This is canonical JSON byte size, not Python repr or provider payload
  size. It must handle all JSON value types. Do not bypass sessions to
  read private Store fields.

## Usage

Run from this directory with Python 3; no external packages are required:

```python
from vendor.shelf_v2 import Store
from export import export_records
from lookup import lookup_value
from manifest import build_manifest

store = Store([
    {"checkpoint": True},
    {"key": "app/name", "value": "café"},
    {"key": "app/optional", "value": None},
    {"key": "app/old", "value": 1, "deleted": True},
])
rows = export_records(store, prefix="app/", page_size=1)
# [{"key": "app/name", "value": "café"}, {"key": "app/optional", "value": None}]
missing = object()
assert lookup_value(store, "app/optional", missing) is None
assert lookup_value(store, "absent", missing) is missing
assert build_manifest(store, "app/") == {
    "count": 2, "keys": ["app/name", "app/optional"], "total_bytes": 11,
}
```

The application functions manage their own v2 sessions, including closing
on errors. Pass a Store, not an open session. Invalid JSON/UTF-8 payloads
raise ValueError; missing and deleted keys alone use the lookup default.
The v1 provider has been removed. Run regression tests with
`python3 -m unittest discover -v`.
