# Conditional notes

This package serves editable notes to clients that use optimistic concurrency. Handler state is local, and deleted keys retain their revision counter to prevent stale clients from updating a recreated note. Run `go test -race ./...`.
