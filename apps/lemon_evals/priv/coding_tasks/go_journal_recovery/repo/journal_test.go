package journal

import (
	"bytes"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	frame, err := Encode(Record{7, []byte("hello")})
	if err != nil {
		t.Fatal(err)
	}
	got, n, err := Scan(frame)
	if err != nil || n != len(frame) || len(got) != 1 || got[0].Sequence != 7 || !bytes.Equal(got[0].Payload, []byte("hello")) {
		t.Fatalf("%v %d %v", got, n, err)
	}
}
