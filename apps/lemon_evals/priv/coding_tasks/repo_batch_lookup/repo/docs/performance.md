# Lookup workload

Each order has one customer and zero or more product lines. Duplicate order IDs,
shared customers and repeated SKUs are common in support exports. The memory
repositories expose FindMany but the enrichment service still performs one
Find per order/customer/line. Counters record every call and its argument keys;
they are suitable for deterministic query-count tests.
