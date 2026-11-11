# Harbor reservations
An in-memory reservation gateway used to explain account charge auditing. `python3 -m harbor.cli` sends one example. Run `python3 -m unittest discover -s tests -v`.

The gateway handles routing, authentication, account project aliases, normalization, fee calculation, idempotency, budget admission, journal commit and audit recording. State is deliberately explicit and local. Tokens and projects are seed fixtures, not external services. Every handled request adds one audit row, including failures and replays. Monetary fields in responses are integer cents.
