package ledger_test

import (
	l "arena/ledger"
	"testing"
)

func TestNewSnapshot(t *testing.T) {
	s, e := l.NewSnapshot([]l.Account{{ID: "cash", Currency: "USD", Balance: 100}})
	if e != nil || s.Sequence != 0 || len(s.Digest) != 64 {
		t.Fatal(s, e)
	}
}
