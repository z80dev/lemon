# Lookup workload and bounded query plan

Lookup.Run deduplicates requested order IDs in first-encounter order, then
calls Orders.FindMany once. Only found requested orders contribute enrichment
keys: distinct customer IDs and SKUs are collected in order of requested orders
and original line order. Each nonempty key set gets one FindMany call. Output
is expanded back to the original request order, including duplicates and misses.

An empty request makes zero calls. An all-missing request makes one. Found
orders without lines use two; a populated request uses at most three calls,
irrespective of duplicate orders, shared customers or repeated SKUs. Empty
strings remain valid keys. No cross-request cache is used. A failure stops the
plan immediately and is returned without partial results. Inspector remains a
single-order consumer and continues using Find.

Use telemetry.Counters.Calls to verify operation names and key batches rather
than elapsed time. The visible service test documents the populated call plan.
