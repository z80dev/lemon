package ledger_test

import (
	l "arena/ledger"
	"bytes"
	"testing"
)

func TestReport(t *testing.T) {
	s, _ := l.NewSnapshot([]l.Account{{ID: "cash", Currency: "USD", Balance: 100}})
	var b bytes.Buffer
	if e := l.WriteReport(&b, l.Result{State: s}); e != nil || b.Len() == 0 {
		t.Fatal(e)
	}
}
