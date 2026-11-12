# Parcel rates

Checkout and accounting currently implement parcel pricing separately.
`tables.py` holds contracted rates; `validation.py` holds input rules.
Use Decimal weights and amounts. Quotes and invoice lines are public APIs.

Run: `python3 -m unittest discover -s tests -v`
