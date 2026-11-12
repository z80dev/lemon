# stocksum

`go run ./cmd/stocksum [-sku NAME] [-min N]` summarizes stock movements from CSV on stdin. Run tests with `go test ./...`. The app package owns parsing and reporting; main only wires process streams.
