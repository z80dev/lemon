package releasegraph_test

import (
	rg "arena/releasegraph"
	"testing"
)

func TestSnapshotRestore(t *testing.T) {
	e, _ := rg.NewEngine([]rg.Package{{Name: "core"}})
	r, err := rg.Restore(e.Snapshot())
	if err != nil || len(r.Snapshot().Packages) != 1 {
		t.Fatal(err)
	}
}
