# Snapshot janitor

The catalog contains snapshots from several volumes. `retention.Plan` computes deletions only; the caller performs them. Pins, recency and per-volume retention are independent protections. `go test ./...` runs the examples.
