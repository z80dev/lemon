package ledger_test

import (
	l "arena/ledger"
	"errors"
	"testing"
)

func TestEngineConflict(t *testing.T) {
	s, _ := l.NewSnapshot(nil)
	e, _ := l.NewEngine(s)
	if _, err := e.Recover(4, nil); !errors.Is(err, l.ErrConflict) {
		t.Fatal(err)
	}
}
