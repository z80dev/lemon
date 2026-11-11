package retention

import (
	"errors"
	"math"
	"math/rand"
	"reflect"
	"sort"
	"testing"
)

func reference(in []Snapshot, p Policy) []string {
	var out []string
	for _, s := range in {
		if s.Pinned || s.Created >= p.Cutoff {
			continue
		}
		rank := 0
		for _, q := range in {
			if !q.Pinned && q.Volume == s.Volume && (q.Created > s.Created || q.Created == s.Created && q.ID < s.ID) {
				rank++
			}
		}
		if rank >= p.Keep {
			out = append(out, s.ID)
		}
	}
	sort.Strings(out)
	return out
}
func TestPlanContract(t *testing.T) {
	in := []Snapshot{{"old", "a", 1, false}, {"new", "a", 8, false}, {"pin", "a", 10, true}, {"tie-b", "b", 4, false}, {"tie-a", "b", 4, false}, {"recent", "c", 9, false}, {"extreme", "d", math.MinInt64, false}}
	for _, p := range []Policy{{0, 9}, {1, 9}, {2, math.MaxInt64}, {100, 0}} {
		before := append([]Snapshot(nil), in...)
		got, err := Plan(in, p)
		want := reference(in, p)
		if err != nil || !reflect.DeepEqual(got, want) || !reflect.DeepEqual(in, before) {
			t.Fatalf("policy %v: %v %v want %v", p, got, err, want)
		}
	}
	for _, bad := range [][]Snapshot{{{"", "a", 1, false}}, {{"x", "", 1, false}}, {{"x", "a", 1, false}, {"x", "b", 2, true}}} {
		got, err := Plan(bad, Policy{})
		if got != nil || !errors.Is(err, ErrInvalid) {
			t.Fatalf("bad accepted %v", bad)
		}
	}
	if got, err := Plan(nil, Policy{Keep: -1}); got != nil || !errors.Is(err, ErrInvalid) {
		t.Fatal("negative keep")
	}
	r := rand.New(rand.NewSource(17))
	for trial := 0; trial < 80; trial++ {
		var data []Snapshot
		for n := 0; n < 45; n++ {
			data = append(data, Snapshot{ID: string(rune(1000 + n)), Volume: string(rune('a' + r.Intn(4))), Created: int64(r.Intn(15) - 7), Pinned: r.Intn(5) == 0})
		}
		p := Policy{r.Intn(5), int64(r.Intn(9) - 4)}
		got, err := Plan(data, p)
		if err != nil || !reflect.DeepEqual(got, reference(data, p)) {
			t.Fatalf("random policy %v: %v %v", p, got, err)
		}
	}
}
