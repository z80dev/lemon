package windows

import "testing"

func TestOverlapping(t *testing.T) {
	got, err := Normalize([]Window{{1, 4}, {3, 8}})
	if err != nil || len(got) != 1 || got[0] != (Window{1, 8}) {
		t.Fatalf("got %v %v", got, err)
	}
}
