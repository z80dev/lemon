package releasegraph_test

import (
	rg "arena/releasegraph"
	"arena/releasegraph/adapters/catalog"
	"os"
	"testing"
)

func TestRepositoryCatalog(t *testing.T) {
	p, e := catalog.Load(os.DirFS("."), "testdata/catalog")
	if e != nil || len(p) != 48 {
		t.Fatal(len(p), e)
	}
	g, e := rg.Build(p)
	if e != nil {
		t.Fatal(e)
	}
	for _, entry := range p {
		plan, e := g.Plan(rg.Request{Changes: []rg.Change{{Name: entry.Name, Level: "patch"}}, IncludePrivate: true})
		if e != nil || len(plan.Releases) == 0 {
			t.Fatal(entry.Name, e)
		}
	}
}
