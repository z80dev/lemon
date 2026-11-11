# Postroom
Parcel pricing and dispatch. `postroom/catalog.py` is the full published tariff history. It is deliberately kept as one file to match the carrier's release format. `postroom/invoice.py` is its only lookup consumer; other layers build invoices or consume their totals. CLI: `python3 -m postroom.cli`. Tests: `python3 -m unittest discover -s tests -v`.

The catalog uses lower-exclusive, upper-inclusive weight bands in grams, and integer cents. Lane codes are case-sensitive. A publication takes effect on its effective date, and remains active until the next publication for that lane. Shipping date, not invoice/billing date, determines the applicable publication. Published ROWS are immutable business data and must not be edited, removed, reordered, or duplicated.

The invoice mapping contains lane, grams, shipping_date (ISO YYYY-MM-DD), billed_on (for accounting only), and optional handling_cents (default zero). Its quote is exactly {postage_cents, handling_cents, total_cents}; handling is a nonnegative integer, validated by the existing helper.
