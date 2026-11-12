package ledger_test

import (
	l "arena/ledger"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestSettlementCorpus(t *testing.T) {
	paths, e := filepath.Glob("testdata/accounts/*.json")
	if e != nil || len(paths) != 24 {
		t.Fatal(e)
	}
	accounts := []l.Account{}
	for _, path := range paths {
		b, e := os.ReadFile(path)
		if e != nil {
			t.Fatal(e)
		}
		var a l.Account
		if e = json.Unmarshal(b, &a); e != nil {
			t.Fatal(e)
		}
		accounts = append(accounts, a)
	}
	state, e := l.NewSnapshot(accounts)
	if e != nil {
		t.Fatal(e)
	}
	paths, _ = filepath.Glob("testdata/journals/*.json")
	if len(paths) != 24 {
		t.Fatal("missing settlements")
	}
	for _, path := range paths {
		b, e := os.ReadFile(path)
		if e != nil {
			t.Fatal(e)
		}
		var records []l.Record
		if e = json.Unmarshal(b, &records); e != nil {
			t.Fatal(e)
		}
		data, e := l.EncodeRecords(records)
		if e != nil {
			t.Fatal(e)
		}
		result, e := l.Recover(state, data)
		if e != nil || len(result.Committed) != 1 {
			t.Fatal(path, result, e)
		}
		state = result.State
	}
	if state.Sequence != 96 || len(state.Receipts) != 24 {
		t.Fatal(state)
	}
}
