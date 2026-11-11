# Parcel desk

An offline parcel support tool backed by a durable JSON snapshot. Run
`go test ./...` for visible tests. `go run ./cmd/parcelctl --store PATH show ID`
reads a parcel. `go run ./cmd/parceld` serves GET /v1/parcels/{id} on :8080;
PARCEL_STORE overrides parcels.json and PORT overrides 8080. A new store is
empty. Embedders provision parcels through storage.Store.Create.

## Existing boundaries

model owns domain values, storage encodes records and atomically replaces the
snapshot, service enforces business rules, api exposes JSON and cli implements
the command grammar. app wires the same service into HTTP and CLI. Keep these
layers: implementing holds only in a handler or process-local map is not enough.
Store.Open(path) returns *Store; Get(id), Create(model.Parcel) and
Update(id, func(*model.Parcel) (bool,error)) return a parcel and error.
Update's bool reports whether the callback changed the parcel. False is a true
no-op: no persistence write. Updates are serialized per Store, copy values at
boundaries, and publish memory state only after a successful atomic disk write.
Missing IDs return model.ErrNotFound ("parcel not found"). Store.Close is not
needed: each successful mutation is durable before returning.

## Hold feature contract

Add model.Hold with exported Reason string, and Hold *Hold on model.Parcel.
The JSON view always contains exactly id, destination, state, revision, hold.
hold is null or {"reason":"normalized reason"}; state stays ready/delivered.
All existing GET and CLI show operations must expose it. Persist holds in the
snapshot and restore them on Open; absent hold data in old snapshots means nil.
Returned parcels/hold pointers and caller inputs must not alias stored data.

Add service.Desk.PlaceHold(id,reason string) (model.Parcel,error) and
ReleaseHold(id string) (model.Parcel,error). Trim surrounding Unicode whitespace
from reasons, then require 1..120 Unicode code points. Validate reason before
lookup. Invalid reason: model.ErrInvalidReason, "reason must contain 1 to 120 characters".
Missing parcel: model.ErrNotFound. A delivered parcel cannot be placed on hold:
model.ErrDelivered, "delivered parcel cannot be held". A ready parcel's first
hold increments Revision once. An existing identical normalized reason is an
idempotent no-op, with no revision or disk write. A different reason returns
model.ErrAlreadyHeld, "parcel already held", without changing anything.
Delivered-state rejection precedes already-held checks. Release removes a hold
and increments Revision once; an unheld parcel is a no-op, even if delivered.
Never alter ID/destination/state. Failed validation, conflict and persistence
failures must leave memory and disk unchanged. Preserve underlying I/O errors.

POST /v1/parcels/{id}/hold accepts exactly one JSON object with only reason
(a string). Missing, empty or whitespace-only reason uses ErrInvalidReason.
Invalid JSON, non-object values, unknown fields, non-string reason including
null, or trailing JSON return 400 {"error":"invalid request"}.
DELETE /v1/parcels/{id}/hold releases; GET /v1/parcels/{id} reads.
Both hold routes return 200 with the complete parcel view on success, 404 for
missing parcel, 409 for delivered/already-held conflicts, 400 for invalid
reason; errors are exactly {"error":"<message>"}. Unexpected/storage errors
return 500 {"error":"internal error"}.

cli.Run(args []string, desk *service.Desk, out io.Writer) error gains
`hold ID REASON` and `release ID`; REASON is one argument (quote in a shell).
Successful commands output one JSON line with the same full view as GET and
return nil. Domain/storage errors return unchanged and produce no output.
All command arity/unknown-command errors return
"usage: parcel show ID | hold ID REASON | release ID" and produce no output.
The parcelctl executable continues using --store PATH before command arguments.
Document the commands, HTTP routes and durable hold semantics in docs.
