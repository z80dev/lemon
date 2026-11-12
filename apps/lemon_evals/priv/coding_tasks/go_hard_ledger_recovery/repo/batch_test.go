package ledger_test

import (
	l "arena/ledger"
	"testing"
)

func TestEncodeBatch(t *testing.T) {
	data, e := l.EncodeRecords([]l.Record{{Sequence: 1, Kind: "begin", Tx: "a"}, {Sequence: 2, Kind: "commit", Tx: "a"}})
	r, n, err := l.Scan(data)
	if e != nil || err != nil || len(r) != 2 || n != len(data) {
		t.Fatal(e, err)
	}
}
