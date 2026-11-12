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
