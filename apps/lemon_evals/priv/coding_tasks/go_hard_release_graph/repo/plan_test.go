package releasegraph_test

import (
	rg "arena/releasegraph"
	"testing"
)

func TestDirectPatch(t *testing.T) {
	g, _ := rg.Build([]rg.Package{{Name: "core"}})
	p, e := g.Plan(rg.Request{Changes: []rg.Change{{Name: "core", Level: "patch"}}})
	if e != nil || len(p.Releases) != 1 || p.Releases[0].After.Patch != 1 {
		t.Fatal(p, e)
	}
}
