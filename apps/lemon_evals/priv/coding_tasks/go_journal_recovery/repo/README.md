# Local event journal

The journal is written by a single process. Shutdown can interrupt a frame, so reopening must distinguish a torn suffix from corruption in committed data. Encode owns frame construction, Scan validates replay, AppendFile handles reopening. `go test ./...`.
