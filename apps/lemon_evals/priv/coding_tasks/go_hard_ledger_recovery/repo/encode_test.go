package ledger_test

import (
	l "arena/ledger"
	"reflect"
	"testing"
)

func TestFrameRoundTrip(t *testing.T) {
	r := l.Record{Sequence: 1, Kind: "begin", Tx: "a"}
	data, e := l.Encode(r)
	if e != nil {
		t.Fatal(e)
	}
	records, n, e := l.Scan(data)
	if e != nil || n != len(data) || !reflect.DeepEqual(records, []l.Record{r}) {
		t.Fatal(records, n, e)
	}
}
