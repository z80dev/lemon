package storage

import "example.com/dispatch/ledger"

func before(a, b ledger.EventRow) bool {
    if a.At.Equal(b.At) { return a.Sequence < b.Sequence }
    return a.At.Before(b.At)
}
func locationEvent(kind string) bool { return kind == "accepted" || kind == "moved" }
