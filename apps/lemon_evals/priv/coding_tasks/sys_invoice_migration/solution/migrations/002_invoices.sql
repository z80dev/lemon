CREATE TABLE invoices_v2 (
    id INTEGER PRIMARY KEY,
    invoice_number TEXT NOT NULL UNIQUE,
    customer_code TEXT NOT NULL CHECK (trim(customer_code) <> ''),
    state TEXT NOT NULL CHECK (state IN ('draft', 'open', 'paid')),
    currency TEXT NOT NULL CHECK (
        length(currency) = 3 AND length(CAST(currency AS BLOB)) = 3
        AND currency NOT GLOB '*[^A-Z]*'
    ),
    total_cents INTEGER NOT NULL CHECK (
        typeof(total_cents) = 'integer' AND total_cents >= 0
    ),
    issued_on TEXT NOT NULL
);
INSERT INTO invoices_v2
SELECT id, invoice_number, customer_code,
       CASE state WHEN 'sent' THEN 'open' ELSE state END,
       coalesce(nullif(upper(trim(currency)), ''), 'USD'),
       total_cents, issued_on
FROM invoices;
DROP TABLE invoices;
ALTER TABLE invoices_v2 RENAME TO invoices;
