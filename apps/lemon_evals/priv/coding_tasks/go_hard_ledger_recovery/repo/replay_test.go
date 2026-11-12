package ledger_test

import (
	l "arena/ledger"
	"testing"
)

func TestEmptyTransaction(t *testing.T) {
	s, _ := l.NewSnapshot(nil)
	r, e := l.Replay(s, []l.Record{{Sequence: 1, Kind: "begin", Tx: "empty"}, {Sequence: 2, Kind: "commit", Tx: "empty"}})
	if e != nil || len(r.Committed) != 1 || r.State.Sequence != 2 {
		t.Fatal(r, e)
	}
}
