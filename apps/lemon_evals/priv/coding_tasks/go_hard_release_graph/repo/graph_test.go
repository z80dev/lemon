package releasegraph_test

import (
	rg "arena/releasegraph"
	"testing"
)

func TestSinglePackage(t *testing.T) {
	g, e := rg.Build([]rg.Package{{Name: "core"}})
	if e != nil || len(g.Packages()) != 1 {
		t.Fatal(e)
	}
}
