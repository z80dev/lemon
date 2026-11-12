# Batch desk

An offline order lookup desk. Run `go test ./...`, or start
`go run ./cmd/batchdesk` and send POST /v1/orders/lookup with
{"ids":["O1","missing","O1"]}. The response is {"results":[...]}.
The demo listens on PORT (8080 by default). cli.Run exposes the same lookup
for an argument list of order IDs. No database server or network packages.

## Layers and current problem

api decodes requests and formats errors; service.Lookup enriches orders;
repository defines single and batch interfaces; memory implements the real
repository API and records operation counts via telemetry.Counters. service
currently calls Find in nested loops, although FindMany already exists for
all three repositories. Do not change repository interfaces or delete Find:
other consumers such as service.Inspector use it for single-order support.

## Lookup contract

service.New(orders repository.Orders, customers repository.Customers,
products repository.Products) returns *service.Lookup.
(*Lookup).Run(ids []string) ([]model.Result,error) preserves input order and
cardinality, including duplicate and missing IDs. IDs are opaque, so do not
trim or filter empty strings. A missing order yields
{"id":"requested ID","found":false,"summary":null}. Found rows produce
{"id":"requested ID","found":true,"summary":{"id":"order ID",
"customer_name":"name or empty","lines":[...],"total_cents":integer}}.
Each line preserves order and duplicates from the order, with fields sku,
title, quantity, unit_cents, available. Missing product means title "", price 0
and available false; found product means available true. Totals are the sum of
quantity*unit_cents; missing customer means customer_name "". Lines must be a
non-null empty JSON array when an order has no lines. Empty input returns a
non-nil empty results slice and no repository operations.

For every nonempty Run, issue exactly ONE Orders.FindMany with distinct input
IDs in first-encounter order, and ZERO Orders.Find calls. Iterate the found
orders in that unique request order to gather distinct customer IDs and SKUs
(lines in original order). Make exactly one Customers.FindMany if at least one
found order exists, otherwise none; make exactly one Products.FindMany if at
least one found line exists, otherwise none. The gathered key batches preserve
first-encounter order and include empty-string keys. No Customers.Find or
Products.Find calls are permitted from Lookup. Batch maps may omit missing
rows or include extra rows: ignore entries not requested and only enrich found
requested orders. No cross-request cache: each Run repeats the required calls.
Do not mutate input IDs, repository rows, line slices or returned repository
maps. Retain the same observable output through HTTP and CLI.

Call order is orders, customers (if needed), products (if needed). A repository
error must be returned unchanged, with a nil results slice; do not perform
downstream calls after an error. HTTP errors remain 500 {"error":"lookup failed"};
malformed requests remain 400 {"error":"invalid request"}. cli.Run returns the
same error without output. The operation-count requirement applies only to
Lookup.Run, not Inspector. Update docs/performance.md with the bounded call
plan. Use operation counts, not timing, to demonstrate the improvement.
