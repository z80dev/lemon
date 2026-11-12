package replay

import "testing"

func TestHistoryThenLive(t *testing.T) {
	b, _ := New(4)
	defer b.Close()
	b.Publish("t", []byte("old"))
	s, err := b.Subscribe("t", 0, 4)
	if err != nil {
		t.Fatal(err)
	}
	b.Publish("t", []byte("new"))
	if (<-s.C).Sequence != 1 || (<-s.C).Sequence != 2 {
		t.Fatal("out of order")
	}
}
