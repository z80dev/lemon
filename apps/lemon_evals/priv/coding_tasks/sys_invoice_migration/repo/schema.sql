PRAGMA foreign_keys = OFF;
PRAGMA user_version = 1;
CREATE TABLE invoices (
    id INTEGER PRIMARY KEY,
    invoice_number TEXT,
    customer_code TEXT,
    state TEXT,
    currency TEXT,
    total_cents INTEGER,
    issued_on TEXT
);
CREATE TABLE invoice_lines (
    id INTEGER PRIMARY KEY,
    invoice_id INTEGER REFERENCES invoices(id) ON DELETE CASCADE,
    description TEXT,
    quantity INTEGER,
    unit_price_cents INTEGER
);
CREATE TABLE payments (
    id INTEGER PRIMARY KEY,
    invoice_id INTEGER REFERENCES invoices(id) ON DELETE CASCADE,
    external_ref TEXT,
    amount_cents INTEGER,
    paid_on TEXT
);
