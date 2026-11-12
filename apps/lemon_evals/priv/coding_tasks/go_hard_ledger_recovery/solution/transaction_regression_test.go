package ledger_test

import (
	l "arena/ledger"
	"errors"
	"reflect"
	"testing"
)

func TestAtomicReplayRegression(t *testing.T) {
	initial, err := l.NewSnapshot([]l.Account{{ID: "cash", Currency: "USD", Balance: 50}, {ID: "reserve", Currency: "USD"}})
	if err != nil {
		t.Fatal(err)
	}
	records := []l.Record{
		{Sequence: 1, Kind: "begin", Tx: "settlement"},
		{Sequence: 2, Kind: "post", Tx: "settlement", Account: "cash", Amount: -20},
		{Sequence: 3, Kind: "post", Tx: "settlement", Account: "reserve", Amount: 20},
		{Sequence: 4, Kind: "commit", Tx: "settlement"},
	}
	data, err := l.EncodeRecords(records)
	if err != nil {
		t.Fatal(err)
	}
	result, err := l.Recover(initial, data)
	if err != nil || result.State.Accounts[0].Balance != 30 {
		t.Fatal(result, err)
	}
	for i := range records {
		records[i].Sequence += 4
	}
	replay, err := l.Replay(result.State, records)
	if err != nil || !reflect.DeepEqual(replay.Replayed, []string{"settlement"}) || replay.State.Receipts[0].Sequence != 4 || replay.State.Accounts[0].Balance != 30 {
		t.Fatal(replay, err)
	}
	engine, err := l.NewEngine(result.State)
	if err != nil {
		t.Fatal(err)
	}
	records[1].Amount = -19
	records[2].Amount = 19
	data, err = l.EncodeRecords(records)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = engine.Recover(4, data); !errors.Is(err, l.ErrCorrupt) {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(engine.Snapshot(), result.State) {
		t.Fatal("failed idempotency check changed checkpoint")
	}
}
