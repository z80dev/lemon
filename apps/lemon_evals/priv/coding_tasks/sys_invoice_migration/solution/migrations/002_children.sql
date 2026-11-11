CREATE TABLE invoice_lines_v2 (
    id INTEGER PRIMARY KEY,
    invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
    description TEXT NOT NULL CHECK (trim(description) <> ''),
    quantity INTEGER NOT NULL CHECK (typeof(quantity) = 'integer' AND quantity > 0),
    unit_price_cents INTEGER NOT NULL CHECK (
        typeof(unit_price_cents) = 'integer' AND unit_price_cents >= 0
    )
);
INSERT INTO invoice_lines_v2 SELECT * FROM invoice_lines;
DROP TABLE invoice_lines;
ALTER TABLE invoice_lines_v2 RENAME TO invoice_lines;
CREATE TABLE payments_v2 (
    id INTEGER PRIMARY KEY,
    invoice_id INTEGER NOT NULL REFERENCES invoices(id) ON DELETE RESTRICT,
    external_ref TEXT NOT NULL UNIQUE,
    amount_cents INTEGER NOT NULL CHECK (
        typeof(amount_cents) = 'integer' AND amount_cents > 0
    ),
    paid_on TEXT NOT NULL
);
INSERT INTO payments_v2 SELECT * FROM payments;
DROP TABLE payments;
ALTER TABLE payments_v2 RENAME TO payments;
-- CHECK has no subqueries; an assertion table makes orphan rejection transactional.
CREATE TEMP TABLE migration_assertion (ok INTEGER NOT NULL CHECK (ok = 1));
INSERT INTO migration_assertion
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM invoice_lines l LEFT JOIN invoices i ON i.id = l.invoice_id
    WHERE i.id IS NULL
) OR EXISTS (
    SELECT 1 FROM payments p LEFT JOIN invoices i ON i.id = p.invoice_id
    WHERE i.id IS NULL
) THEN 0 ELSE 1 END;
DROP TABLE migration_assertion;
