package journal

import "testing"

func TestTornSuffix(t *testing.T) {
	frame, _ := Encode(Record{2, []byte("hello")})
	got, n, err := Scan(frame[:len(frame)-1])
	if err != nil || len(got) != 0 || n != 0 {
		t.Fatal(got, n, err)
	}
}
