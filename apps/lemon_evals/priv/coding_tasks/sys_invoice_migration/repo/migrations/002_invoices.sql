-- The old upgrade only standardized display values, leaving a permissive table.
UPDATE invoices SET state = 'open' WHERE state = 'sent';
UPDATE invoices SET currency = upper(coalesce(currency, 'USD'));
