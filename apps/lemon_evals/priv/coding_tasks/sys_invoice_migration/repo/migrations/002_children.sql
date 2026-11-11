-- Child rows used to be discarded when invoice totals were recalculated.
DELETE FROM invoice_lines;
DELETE FROM payments;
