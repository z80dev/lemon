package ledger_test

import (
	l "arena/ledger"
	"testing"
)

func TestRecoverEmpty(t *testing.T) {
	s, _ := l.NewSnapshot(nil)
	r, e := l.Recover(s, nil)
	if e != nil || r.ValidBytes != 0 || r.State.Digest != s.Digest {
		t.Fatal(r, e)
	}
}
