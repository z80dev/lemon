package releasegraph_test

import (
	rg "arena/releasegraph"
	"testing"
)

func TestInitialRevision(t *testing.T) {
	e, err := rg.NewEngine(nil)
	if err != nil || e.Snapshot().Revision != 1 {
		t.Fatal(err)
	}
}
