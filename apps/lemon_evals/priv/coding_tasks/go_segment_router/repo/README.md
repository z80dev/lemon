# Segment router

This library selects a next-hop service from URL-like path prefixes. Prefixes are logical paths, not URL parsers: no decoding is performed. A configuration is constructed once and then queried concurrently. Run `go test ./...`.
