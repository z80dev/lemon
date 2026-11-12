# Inventory reconciliation

The nightly importer combines an opening stock snapshot and a batch of movements. Cancellation records may arrive before their targets. Only final balances are published. Run `go test ./...`.
