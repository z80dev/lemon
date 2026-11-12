package ledger_test

import (
	l "arena/ledger"
	"arena/ledger/adapters/jsonapi"
	"bytes"
	"testing"
)

func TestCheckpointJSON(t *testing.T) {
	s, _ := l.NewSnapshot(nil)
	var b bytes.Buffer
	if e := jsonapi.WriteSnapshot(&b, s); e != nil {
		t.Fatal(e)
	}
	read, e := jsonapi.ReadSnapshot(&b)
	if e != nil || read.Digest != s.Digest {
		t.Fatal(e)
	}
}
