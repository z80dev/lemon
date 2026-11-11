package inventory

import (
	"errors"
	"math/rand"
	"reflect"
	"testing"
)

func TestReconciliation(t *testing.T) {
	open := map[string]int64{"tea": 4, "zero": 0}
	events := []Event{{ID: "c", Kind: "cancel", Ref: "r"}, {ID: "s", Kind: "ship", SKU: "tea", Quantity: 10}, {ID: "r", Kind: "receive", SKU: "canceled", Quantity: 7}, {ID: "r2", Kind: "receive", SKU: "tea", Quantity: 8}}
	want := []Balance{{"canceled", 0}, {"tea", 2}, {"zero", 0}}
	before := append([]Event(nil), events...)
	rng := rand.New(rand.NewSource(8))
	for i := 0; i < 50; i++ {
		rng.Shuffle(len(events), func(i, j int) { events[i], events[j] = events[j], events[i] })
		got, err := Reconcile(open, events)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Fatalf("%v %v", got, err)
		}
	}
	if open["tea"] != 4 || len(open) != 2 {
		t.Fatal("opening mutated")
	}
	_, _ = Reconcile(open, before)
	if !reflect.DeepEqual(before, []Event{{ID: "c", Kind: "cancel", Ref: "r"}, {ID: "s", Kind: "ship", SKU: "tea", Quantity: 10}, {ID: "r", Kind: "receive", SKU: "canceled", Quantity: 7}, {ID: "r2", Kind: "receive", SKU: "tea", Quantity: 8}}) {
		t.Fatal("events mutated")
	}
	if got, err := Reconcile(nil, nil); got != nil || err != nil {
		t.Fatal("empty")
	}
	invalid := [][]Event{
		{{ID: "x", Kind: "receive", SKU: "a", Quantity: 1}, {ID: "x", Kind: "ship", SKU: "a", Quantity: 1}},
		{{ID: "x", Kind: "cancel", Ref: "missing"}}, {{ID: "x", Kind: "cancel", Ref: "x"}},
		{{ID: "c", Kind: "cancel", Ref: "r"}, {ID: "d", Kind: "cancel", Ref: "r"}, {ID: "r", Kind: "receive", SKU: "a", Quantity: 1}},
		{{ID: "x", Kind: "ship", SKU: "a", Quantity: 1}}, {{Kind: "receive", SKU: "a", Quantity: 1}},
		{{ID: "x", Kind: "receive", Quantity: 1}}, {{ID: "x", Kind: "receive", SKU: "a", Quantity: 0}},
		{{ID: "x", Kind: "receive", SKU: "a", Quantity: -1}}, {{ID: "x", Kind: "other"}},
		{{ID: "x", Kind: "receive", SKU: "a", Quantity: 1, Ref: "x"}}, {{ID: "x", Kind: "cancel", SKU: "a", Ref: "x"}}, {{ID: "x", Kind: "cancel", Quantity: 1, Ref: "x"}},
	}
	for _, in := range invalid {
		got, err := Reconcile(nil, in)
		if got != nil || !errors.Is(err, ErrInvalid) {
			t.Fatalf("accepted %v: %v %v", in, got, err)
		}
	}
	for _, in := range []map[string]int64{{"": 1}, {"a": -1}} {
		got, err := Reconcile(in, nil)
		if got != nil || !errors.Is(err, ErrInvalid) {
			t.Fatal("invalid opening")
		}
	}
}
