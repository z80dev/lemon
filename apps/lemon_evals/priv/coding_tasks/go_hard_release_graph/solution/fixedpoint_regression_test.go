package releasegraph_test

import (
	rg "arena/releasegraph"
	"errors"
	"reflect"
	"testing"
)

func TestReleaseTrainRegression(t *testing.T) {
	packages := []rg.Package{
		{Name: "z", Group: "train"},
		{Name: "a", Group: "train"},
		{Name: "consumer", Dependencies: []rg.Dependency{{Name: "a", Kind: "runtime", Policy: "compatible"}}},
	}
	engine, err := rg.NewEngine(packages)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := engine.Plan(rg.Request{Changes: []rg.Change{{Name: "z", Level: "major"}}})
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.Releases) != 3 || plan.Releases[0].Level != "major" || plan.Releases[1].Level != "minor" || !reflect.DeepEqual(plan.Waves, [][]string{{"a", "z"}, {"consumer"}}) {
		t.Fatal(plan)
	}
	before := engine.Snapshot()
	if _, err = engine.Apply(rg.Update{Expected: 1, Edits: []rg.Edit{{Remove: "a"}}}); !errors.Is(err, rg.ErrInvalid) {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, engine.Snapshot()) {
		t.Fatal("failed batch changed the graph")
	}
	replacement := packages[2]
	replacement.Dependencies = []rg.Dependency{{Name: "z", Kind: "build", Policy: "any"}}
	if _, err = engine.Apply(rg.Update{Expected: 1, Edits: []rg.Edit{{Remove: "a"}, {Upsert: &replacement}}}); err != nil {
		t.Fatal(err)
	}
	plan, err = engine.Plan(rg.Request{Changes: []rg.Change{{Name: "z", Level: "minor"}}})
	if err != nil || len(plan.Releases) != 2 || plan.Releases[0].Name != "consumer" || plan.Releases[0].Level != "patch" {
		t.Fatal(plan, err)
	}
}
