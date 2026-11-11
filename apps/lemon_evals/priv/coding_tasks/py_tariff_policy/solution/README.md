# Parcel rates

Checkout calls `quote(weight_kg, zone, express=False)` and accounting calls
`make_line(reference, weight_kg, zone, quantity=1, express=False)`.
All money and weights use `decimal.Decimal`; currency is USD.

## Shared policy

`parcel_rates.policy.calculate(weight_kg, zone, express=False)` owns weight
bands, express and fuel adjustments, validation, and final ROUND_HALF_UP
cent rounding. Both consumers resolve `policy.calculate` on every call, so a
policy replacement applies immediately without reimporting either consumer.
Invoices multiply the returned rounded unit amount by quantity and never
reprice or reround it. Quantity validation precedes the shared policy call.

Zones are local, regional, and remote. Half-kilogram bands round upward;
the first kilogram is included in each zone's base charge.

    python3 -m unittest discover -s tests -v
