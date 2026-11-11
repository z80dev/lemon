package replay

import "testing"

func TestLiveDelivery(t *testing.T) {
	b, _ := New(4)
	defer b.Close()
	sub, err := b.Subscribe("audit", 0, 2)
	if err != nil {
		t.Fatal(err)
	}
	seq, err := b.Publish("audit", []byte("created"))
	if err != nil || seq != 1 {
		t.Fatal(seq, err)
	}
	m := <-sub.C
	if m.Sequence != 1 || string(m.Payload) != "created" {
		t.Fatal(m)
	}
	sub.Cancel()
}
