# Settlement export

This service combines charge settlement events and refund events into an accounting-month payout export. Run `python3 -m settlement data/sample.json --month 2025-03 --zone America/New_York` to inspect the report. Input timestamps carry offsets, while accounting calendars use the requested IANA timezone. The command and `build_report` expose the same report schema.

Run visible checks with `python3 -m unittest discover -s tests -v`.
