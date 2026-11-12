# Running the desk

The executable uses the in-memory ledger and listens on PORT (8080 by default).
Use the HTTP API for support lookups or invoke cli.Run with an account and ID
when embedding the desk in an operator tool. There is no background importer;
ledger.Append is the explicit ingestion boundary.
