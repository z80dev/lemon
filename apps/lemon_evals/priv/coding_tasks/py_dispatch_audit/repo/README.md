# Dispatch settlement review

This stdlib-only service computes carrier charges from dispatch manifests.
`data/dispatch.json` is the settlement snapshot being reviewed. The account map
contains negotiated rebates; shipment dimensions are centimeters and actual
weights are grams. Monetary calculations use integer cents throughout.

The loader converts the manifest into immutable records. Weight policy, carrier
rate tables, per-shipment billing and account reporting live in separate modules.
The report CLI prints the aggregate view; `billing.quote` exposes shipment-level
charges for audit callers. Status handling and rebate order are business rules in
the implementation, not data-cleaning recommendations.

```sh
python3 -m dispatch data/dispatch.json
python3 -m unittest discover -s tests -v
```

This is an investigation snapshot: do not modify it during an audit. The visible
tests describe a few unrelated, small examples rather than the settlement answer.
