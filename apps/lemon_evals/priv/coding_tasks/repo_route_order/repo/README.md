# Courier quotes
The API and JSONL CLI (`python3 -m courier.cli`) share a long-lived quote service. Deployment warms common destinations before accepting traffic. Carrier plugins register immutable Rule records and can be refreshed without restarting the service. Run `python3 -m unittest discover -s tests -v`.

## Contract
`QuoteService(registry).quote(country, tier, weight, hazmat=False)` normalizes country with strip/uppercase. Tier must be standard or priority. Weight is a positive integer in kilograms (bool is not an integer for this API); hazmat must be bool. Invalid country/tier/weight/hazmat raises ValueError with respectively COUNTRY/TIER/WEIGHT/HAZMAT. Rule country is already canonical.

A rule matches only its country, listed tiers, weight <= max_weight, and (for a hazmat request) hazmat=True. Choose the matching rule with the smallest (priority, code) tuple; code is the lexicographic tie-break, independent of registration order. No match raises LookupError('NO_ROUTE'). Price is base + per_kg * weight. Return the exact six fields route, country, tier, weight, hazmat, cents. The API wraps success as {status:200, quote:...}, ValueError as {status:400,error:...}, LookupError as {status:404,error:...}.

Registry.register replaces a rule of the same code; Registry.remove removes it if present. Changes must affect the next quote, including previously empty destinations. Results depend only on the current registry and current request, never prior quotes, warmup, or plugin registration order. Caching is permitted but must preserve that contract. Existing cached requests must not resurrect removed rules or old prices.
