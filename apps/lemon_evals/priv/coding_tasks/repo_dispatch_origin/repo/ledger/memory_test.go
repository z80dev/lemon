package ledger_test

import (
    "testing"
    "example.com/dispatch/ledger"
)
func TestEventsAreCopied(t *testing.T) {
    db := ledger.New()
    db.Append(ledger.EventRow{Account:"a",DispatchID:"x",Hub:"BOS"})
    rows, _ := db.Events("a","x")
    rows[0].Hub = "corrupted"
    again, _ := db.Events("a","x")
    if again[0].Hub != "BOS" { t.Fatal("ledger returned shared rows") }
}
