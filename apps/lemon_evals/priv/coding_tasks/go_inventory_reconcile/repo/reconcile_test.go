package inventory

import "testing"

func TestDelivery(t *testing.T) {
	got, err := Reconcile(map[string]int64{"tea": 2}, []Event{{ID: "e1", Kind: "receive", SKU: "tea", Quantity: 3}})
	if err != nil || len(got) != 1 || got[0] != (Balance{"tea", 5}) {
		t.Fatalf("%v %v", got, err)
	}
}
