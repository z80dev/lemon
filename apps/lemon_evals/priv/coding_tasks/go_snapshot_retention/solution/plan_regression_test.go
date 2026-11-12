package retention

import "testing"

func TestPinsDoNotUseKeepSlots(t *testing.T) {
	got, err := Plan([]Snapshot{{"pin", "a", 10, true}, {"keep", "a", 9, false}, {"drop", "a", 8, false}}, Policy{1, 20})
	if err != nil || len(got) != 1 || got[0] != "drop" {
		t.Fatal(got, err)
	}
}
