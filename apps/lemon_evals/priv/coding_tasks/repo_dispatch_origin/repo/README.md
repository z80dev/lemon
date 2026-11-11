# Dispatch desk

An offline dispatch tracking service. Run `go run ./cmd/dispatchd` and request
`GET /v1/dispatches/D-100` with `X-Account: north`. Run tests with `go test ./...`.
The demo starts on :8080; PORT overrides the port. No external services are used.

## Request path

`api.Router` -> `api.DispatchHandler` -> `service.Tracker` ->
`repository.Dispatches` -> `storage.Adapter` -> `ledger.Memory`.
The ledger stores dispatch rows and event rows separately; their read order is
insertion order, NOT event order. Fixtures intentionally include late imports.
`storage.Adapter` owns row-to-domain reconstruction. The view and CLI must not
infer history or repair storage results.

## Contract

GET /v1/dispatches/{id} is account-scoped using the trimmed X-Account header.
Missing account: 401 with {"error":"account required"}; absent dispatch (including
one owned by another account): 404 with {"error":"dispatch not found"}.
Successful JSON has exactly id, reference, status, origin and latest_hub.
Origin is null if there is no accepted event; otherwise it is
{"hub":"...","at":"RFC3339 timestamp"}. It is the earliest accepted event by
(timestamp, sequence), independent of ledger insertion order. A moved event is
never an origin. Timestamps are compared as instants, not strings. Sequence is
unique per dispatch; lower sequence wins timestamp ties. Latest_hub is the hub
of the latest accepted OR moved event by the same tuple (higher sequence wins
latest ties); it is an empty string if neither exists. Other event kinds do
not affect either value. Status and reference come from the dispatch row.
All reads are side-effect-free, and events from other accounts/dispatches must
not leak into a reconstruction. Returned domain values must not alias internal
ledger storage. Existing service, repository, CLI and HTTP public APIs remain.

## Layout

ledger contains persistence and import operations; storage reconstructs domain
objects; repository and service implement application boundaries; view and api
serialize responses; cli and cmd are the interactive entry points. The seed
package supplies a realistic late-import example. The docs contain operator
notes and the event format.
