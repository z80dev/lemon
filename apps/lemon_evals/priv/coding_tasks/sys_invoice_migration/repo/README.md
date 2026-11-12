# Invoice ledger schema upgrade

The billing ledger uses SQLite 3.40. `schema.sql` is the permissive version-1
schema; `sample.sql` is a small production-shaped export. The entry point is
`sqlite3 ledger.db < migrate.sql`, run from this directory. Fix the entry point
and its two migration fragments; no Python migration runner is needed.

## Version 2 contract

Keep the existing table and column names and column order. Preserve every row,
primary key, relationship, and value, with exactly these transformations:
* invoice state `sent` becomes `open`; `draft`, `open`, and `paid` are unchanged;
* currency becomes `upper(trim(currency))`; NULL or empty-after-trim becomes USD.
SQLite `trim` means its default ASCII-space trimming. Do not trim other values.
No other legacy-value repair is permitted: invalid data must fail atomically.

Constraints apply to future inserts AND updates:
* `invoices`: id INTEGER PRIMARY KEY; invoice_number TEXT NOT NULL UNIQUE
  (case-sensitive); customer_code TEXT NOT NULL with nonempty trim;
  state TEXT NOT NULL in draft/open/paid; currency TEXT NOT NULL, exactly three
  ASCII uppercase letters; total_cents INTEGER NOT NULL, stored as integer and
  >= 0; issued_on TEXT NOT NULL. No date-format validation is required.
* `invoice_lines`: id INTEGER PRIMARY KEY; invoice_id INTEGER NOT NULL referencing
  invoices(id) with ON DELETE RESTRICT; description TEXT NOT NULL with nonempty
  trim; quantity INTEGER NOT NULL stored as integer and > 0; unit_price_cents
  INTEGER NOT NULL stored as integer and >= 0.
* `payments`: id INTEGER PRIMARY KEY; invoice_id INTEGER NOT NULL referencing
  invoices(id) with ON DELETE RESTRICT; external_ref TEXT NOT NULL UNIQUE
  (case-sensitive, empty is allowed); amount_cents INTEGER NOT NULL stored as
  integer and > 0; paid_on TEXT NOT NULL. No date-format validation is required.

Declared INTEGER affinity may losslessly coerce numeric strings to integers;
nonintegral REAL values must not pass the integer checks. Foreign keys must
reject missing parents on insert/update, reject parent deletion while either
child table refers to it, and reject changing a referenced parent ID.

The migration must preserve unrelated tables and their data. Only the three
ledger tables are rebuilt; no user triggers, views, or indexes refer to them in
the supported input. Empty databases with the version-1 schema are supported.
All DDL and data changes must commit together. On any invalid legacy value or
orphaned relationship the sqlite3 process must return nonzero, with the original
schema, data, and user_version unchanged. Successful migration sets user_version
(to 2 from either 1 or 2), and enables foreign_keys in that same connection.
Reapplying is supported and must preserve data and constraints, including rows
written after the first migration. Rebuilding tables on rerun is acceptable.
Concurrent writers and arbitrary schema versions are outside the contract.

## Local workflow

```
sqlite3 ledger.db < schema.sql
sqlite3 ledger.db < sample.sql
sqlite3 ledger.db < migrate.sql
python3 -m unittest discover -s tests -v
```
The tests create disposable database files and invoke the SQLite CLI; they do
not require external Python packages.
