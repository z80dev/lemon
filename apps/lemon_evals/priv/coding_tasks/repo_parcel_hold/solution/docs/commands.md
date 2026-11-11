# Operator commands

parcelctl --store PATH show ID emits a parcel JSON line including hold (null or
an object with reason). `hold ID "awaiting customer"` places a hold; `release ID`
removes it. All successful commands print the same full parcel view.

HTTP clients use GET /v1/parcels/{id}, POST /v1/parcels/{id}/hold with
{"reason":"awaiting customer"}, and DELETE /v1/parcels/{id}/hold. The two mutation
routes return the full updated parcel. Errors use {"error":"message"} and
400 (input), 404 (missing), 409 (conflict), or 500 (storage).

Reasons are Unicode-trimmed and limited to 120 code points. Holding a delivered
parcel is forbidden. Repeating the same hold or releasing an unheld parcel is
an idempotent no-op; trying a different reason while held conflicts.
