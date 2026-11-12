package releasegraph_test

import (
	rg "arena/releasegraph"
	"testing"
)

func TestPackageOwnership(t *testing.T) {
	in := []rg.Package{{Name: "core"}}
	g, _ := rg.Build(in)
	in[0].Name = "other"
	out := g.Packages()
	out[0].Name = "mutated"
	if g.Packages()[0].Name != "core" {
		t.Fatal("alias")
	}
}
