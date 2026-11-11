package journal

import (
	"bytes"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"math"
	"os"
	"path/filepath"
	"testing"
)

func frame(t *testing.T, s uint64, p string) []byte {
	t.Helper()
	b, e := Encode(Record{s, []byte(p)})
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func TestJournalContract(t *testing.T) {
	a, b := frame(t, 4, "first"), frame(t, 9, "second")
	full := append(append([]byte{}, a...), b...)
	for n := 0; n < len(b); n++ {
		records, valid, err := Scan(full[:len(a)+n])
		if err != nil || valid != len(a) || len(records) != 1 {
			t.Fatalf("torn at %d: %v %d %v", n, records, valid, err)
		}
	}
	records, valid, err := Scan(full)
	if err != nil || valid != len(full) || len(records) != 2 || records[1].Sequence != 9 {
		t.Fatal("full scan")
	}
	records[0].Payload[0] = 'X'
	if full[12] != 'f' || string(records[1].Payload) != "second" {
		t.Fatal("payload alias")
	}
	full[12] = 'Y'
	if records[0].Payload[0] != 'X' {
		t.Fatal("input alias")
	}
	if r, n, e := Scan(nil); r != nil || n != 0 || e != nil {
		t.Fatal("empty")
	}
	bads := [][]byte{}
	checksum := frame(t, 5, "broken")
	checksum[12] ^= 1
	bads = append(bads, checksum)
	for _, seq := range []uint64{0, 3, 4} {
		bad := frame(t, 5, "s")
		binary.BigEndian.PutUint64(bad[4:12], seq)
		binary.BigEndian.PutUint32(bad[len(bad)-4:], crc32.ChecksumIEEE(bad[4:len(bad)-4]))
		bads = append(bads, bad)
	}
	oversized := make([]byte, 4)
	binary.BigEndian.PutUint32(oversized, MaxPayload+1)
	bads = append(bads, oversized)
	for _, bad := range bads {
		data := append(append([]byte{}, a...), bad...)
		got, n, err := Scan(data)
		var ce *CorruptionError
		if len(got) != 1 || n != len(a) || !errors.As(err, &ce) || ce.Offset != len(a) || ce.Reason == "" {
			t.Fatalf("corrupt: %v %d %v", got, n, err)
		}
	}
	for _, r := range []Record{{0, nil}, {1, make([]byte, MaxPayload+1)}} {
		if _, err := Encode(r); !errors.Is(err, ErrInvalid) {
			t.Fatal("bad encode")
		}
	}
	if b, e := Encode(Record{1, make([]byte, MaxPayload)}); e != nil || len(b) != MaxPayload+16 {
		t.Fatal("max payload")
	}
}
func TestAppendRecovery(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.bin")
	a := frame(t, 17, "committed")
	tail := frame(t, 20, "partial")[:13]
	initial := append(append([]byte{}, a...), tail...)
	if err := os.WriteFile(path, initial, 0600); err != nil {
		t.Fatal(err)
	}
	if err := AppendFile(path, [][]byte{[]byte("next"), nil}); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(path)
	records, n, err := Scan(data)
	if err != nil || n != len(data) || len(records) != 3 || records[1].Sequence != 18 || records[2].Sequence != 19 || string(records[1].Payload) != "next" {
		t.Fatalf("append %v %v", records, err)
	}
	os.WriteFile(path, initial, 0600)
	if err := AppendFile(path, nil); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(path)
	if !bytes.Equal(data, a) {
		t.Fatal("empty batch did not repair")
	}
	for _, original := range [][]byte{initial, frame(t, math.MaxUint64, "last")} {
		os.WriteFile(path, original, 0600)
		payloads := [][]byte{[]byte("valid"), make([]byte, MaxPayload+1)}
		if len(original) == len(frame(t, math.MaxUint64, "last")) {
			payloads = [][]byte{[]byte("x")}
		}
		if err := AppendFile(path, payloads); !errors.Is(err, ErrInvalid) {
			t.Fatalf("want invalid: %v", err)
		}
		data, _ = os.ReadFile(path)
		if !bytes.Equal(data, original) {
			t.Fatal("validation changed existing file")
		}
	}
	corrupt := frame(t, 2, "bad")
	corrupt[12] ^= 1
	os.WriteFile(path, corrupt, 0600)
	var ce *CorruptionError
	if err := AppendFile(path, nil); !errors.As(err, &ce) {
		t.Fatal("corruption lost")
	}
	data, _ = os.ReadFile(path)
	if !bytes.Equal(data, corrupt) {
		t.Fatal("corrupt file modified")
	}
	fresh := filepath.Join(t.TempDir(), "new")
	if err := AppendFile(fresh, [][]byte{[]byte("one")}); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(fresh)
	rs, _, _ := Scan(data)
	if len(rs) != 1 || rs[0].Sequence != 1 {
		t.Fatal("new journal")
	}
}
