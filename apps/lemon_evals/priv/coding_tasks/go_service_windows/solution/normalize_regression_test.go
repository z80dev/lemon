package windows

import "testing"

func TestTouchingAndNested(t *testing.T) {
	got, err := Normalize([]Window{{5, 9}, {1, 5}, {2, 3}})
	if err != nil || len(got) != 1 || got[0] != (Window{1, 9}) {
		t.Fatal(got, err)
	}
}
