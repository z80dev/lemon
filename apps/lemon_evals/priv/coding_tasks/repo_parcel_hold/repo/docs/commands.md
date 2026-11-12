# Operator commands

parcelctl --store PATH show ID emits the parcel as one JSON line. Unknown
commands and incorrect argument counts return a usage error. parceld shares
the same service and supports GET /v1/parcels/{id}; missing parcels return
404 with {"error":"parcel not found"}.
