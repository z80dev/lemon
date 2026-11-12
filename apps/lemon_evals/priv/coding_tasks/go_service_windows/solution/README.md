# Service maintenance windows

Normalize accepts half-open integer-second windows, validates all intervals, and combines overlaps and touching boundaries. It sorts copies and never changes or aliases caller input. Empty input returns nil; invalid intervals return ErrInvalid. Run `go test ./...`.
