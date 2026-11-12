package ledger_test

import (
	l "arena/ledger"
	"testing"
)

func TestTornHeader(t *testing.T) {
	r, n, e := l.Scan([]byte{0, 1})
	if e != nil || len(r) != 0 || n != 0 {
		t.Fatal(r, n, e)
	}
}
