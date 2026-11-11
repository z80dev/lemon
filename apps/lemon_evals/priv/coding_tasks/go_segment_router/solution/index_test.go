package routes

import "testing"

func TestCanonicalDuplicates(t *testing.T) {
	tab, err := New([]Rule{{"/a//b", "first", 2}, {"/a/b/", "second", 2}})
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := tab.Lookup("/a/./b/x"); !ok || got != "first" {
		t.Fatal(got, ok)
	}
}
