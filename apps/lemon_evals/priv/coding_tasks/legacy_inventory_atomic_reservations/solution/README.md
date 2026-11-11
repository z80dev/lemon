# Stockroom
`python -m stockroom.cli --db stock.db add SKU QUANTITY` adds stock;
`list` prints SKU-sorted JSON objects with sku and quantity fields.
Keep those existing commands and their output unchanged.

Implement atomic, durable order reservations through all five existing
layers: validation.py, domain.py, repository.py, service.py, cli.py.
Add standard-library unittest regression tests, including a legacy DB.

Public contracts:
* Stock(sku, quantity, reserved=0) has available = quantity - reserved.
* Repository.stock(sku) returns Stock; missing SKU raises KeyError.
  Existing databases have only stocks(sku TEXT PRIMARY KEY,
  quantity INTEGER NOT NULL). Upgrade on open, retaining all stock.
* Service.reserve(order_id, lines) accepts a nonblank string order ID
  and a nonempty list of {"sku": string, "quantity": positive int}.
  Reject bool quantities, nonintegers, blank/nonstring IDs or SKUs,
  missing fields, and non-list lines with ValueError. Strip surrounding
  whitespace on IDs/SKUs. Aggregate duplicate SKUs before checking stock.
* Return {"order_id": normalized_id, "items": [{"sku": ..., "quantity":
  aggregated_quantity}, ...]}, sorted by SKU. Persist the order and
  each stock's reserved quantity in ONE transaction. Unknown SKUs raise
  KeyError; insufficient available stock raises ValueError. Any failure
  leaves both stock and orders unchanged.
* Replaying the same normalized order and aggregated quantities is
  idempotent, even if input order/duplication differs and after reopening
  the database. Reusing its ID for different quantities raises ValueError.
  Check replay before checking current availability. Separate Repository
  instances must observe one another's committed reservations.
* `reserve ORDER SKU:QUANTITY [SKU:QUANTITY ...]` uses Service.reserve
  and prints that result as JSON. Validation, unknown SKU and stock
  errors print one diagnostic to stderr, return status 2, and no stdout
  or traceback. Existing add/list success behavior remains unchanged.
Repository.close() releases its SQLite connection. No external packages.

## Using reservations

For example, `python -m stockroom.cli --db stock.db reserve order-1 A:2 A:3`
reserves five units of A and prints the normalized order as JSON. Repeating
that order with `A:5` returns the saved order without reserving more stock.
The legacy `list` quantity remains total stock, not available stock; Python
callers can inspect `Repository.stock("A").reserved` and `.available`.

Opening a legacy database adds a zero-default `reserved` column and a durable
`reservation_orders` table. Validation canonicalizes the request before it
reaches the repository. A SQLite `BEGIN IMMEDIATE` transaction serializes
replay checks, availability checks, stock updates, and order insertion across
connections. Any exception rolls back the complete reservation. Adding stock
increases total quantity without resetting existing reservations.

Regression coverage is discoverable with `python -m unittest discover -v`;
`test_reservations.py` covers migration, validation, rollback (including an
order-write failure), durable replay, independent connections, competing
reservations, and CLI success/error output. The existing tests remain intact.
