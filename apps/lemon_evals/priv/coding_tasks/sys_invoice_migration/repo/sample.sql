INSERT INTO invoices VALUES
 (11, 'INV-11', 'ACME', 'sent', ' usd ', 2500, '2025-02-01'),
 (29, 'INV-29', 'NORTH', 'draft', NULL, 0, '2025-02-02'),
 (47, 'INV-47', 'ACME', 'paid', 'eur', 900, '2025-01-20');
INSERT INTO invoice_lines VALUES
 (61, 11, 'Consulting', 2, 1250),
 (82, 47, 'Support', 1, 900);
INSERT INTO payments VALUES
 (103, 47, 'wire-103', 900, '2025-01-21');
