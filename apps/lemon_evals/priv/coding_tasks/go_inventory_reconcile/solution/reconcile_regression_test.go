package inventory

import "testing"

func TestCancelBeforeMovement(t *testing.T) {
	got, err := Reconcile(nil, []Event{{ID: "c", Kind: "cancel", Ref: "r"}, {ID: "r", Kind: "receive", SKU: "tea", Quantity: 8}})
	if err != nil || len(got) != 1 || got[0] != (Balance{"tea", 0}) {
		t.Fatal(got, err)
	}
}
