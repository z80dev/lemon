package releasegraph_test

import (
	rg "arena/releasegraph"
	"testing"
)

func TestLevels(t *testing.T) {
	for i, s := range []string{"none", "patch", "minor", "major"} {
		if rg.Rank(s) != i {
			t.Fatal(s)
		}
	}
	if rg.Rank("MINOR") != -1 {
		t.Fatal("case")
	}
}
