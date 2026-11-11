.bail on
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;
.read migrations/002_invoices.sql
.read migrations/002_children.sql
PRAGMA user_version = 2;
COMMIT;
PRAGMA foreign_keys = ON;
