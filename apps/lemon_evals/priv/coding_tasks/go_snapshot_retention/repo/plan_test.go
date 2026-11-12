package retention

import "testing"

func TestEmptyCatalog(t *testing.T) {
	got, err := Plan(nil, Policy{Keep: 2, Cutoff: 100})
	if err != nil || len(got) != 0 {
		t.Fatalf("%v %v", got, err)
	}
}
