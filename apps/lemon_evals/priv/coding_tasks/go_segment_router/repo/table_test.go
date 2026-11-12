package routes

import "testing"

func TestLongest(t *testing.T) {
	table, err := New([]Rule{{"/", "default", 0}, {"/team", "team", 1}, {"/team/private", "private", 0}})
	if err != nil {
		t.Fatal(err)
	}
	got, ok := table.Lookup("/team/private/report")
	if !ok || got != "private" {
		t.Fatalf("%q %v", got, ok)
	}
}
