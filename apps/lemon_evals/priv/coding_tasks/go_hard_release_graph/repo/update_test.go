package releasegraph_test

import (
	rg "arena/releasegraph"
	"errors"
	"testing"
)

func TestRevisionConflict(t *testing.T) {
	e, _ := rg.NewEngine(nil)
	_, err := e.Apply(rg.Update{Expected: 2})
	if !errors.Is(err, rg.ErrConflict) || e.Snapshot().Revision != 1 {
		t.Fatal(err)
	}
}
