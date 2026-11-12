package ledger_test

import (
	l "arena/ledger"
	"arena/ledger/adapters/files"
	"arena/ledger/adapters/httpapi"
	"arena/ledger/adapters/jsonapi"
	"arena/ledger/app"
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc32"
	"io"
	"math"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
)

func arenaHiddenLRSnapshot(t *testing.T, accounts ...l.Account) l.Snapshot {
	t.Helper()
	s, e := l.NewSnapshot(accounts)
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func arenaHiddenLRInitial(t *testing.T) l.Snapshot {
	return arenaHiddenLRSnapshot(t, l.Account{ID: "cash", Currency: "USD", Balance: 100}, l.Account{ID: "reserve", Currency: "USD"})
}
func arenaHiddenLRRecords(sequence uint64, tx string, amount int64) []l.Record {
	return []l.Record{{Sequence: sequence, Kind: "begin", Tx: tx}, {Sequence: sequence + 1, Kind: "post", Tx: tx, Account: "cash", Amount: -amount}, {Sequence: sequence + 2, Kind: "post", Tx: tx, Account: "reserve", Amount: amount}, {Sequence: sequence + 3, Kind: "commit", Tx: tx}}
}
func arenaHiddenLRBytes(t *testing.T, records []l.Record) []byte {
	t.Helper()
	b, e := l.EncodeRecords(records)
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func arenaHiddenLRBalance(s l.Snapshot, id string) int64 {
	for _, a := range s.Accounts {
		if a.ID == id {
			return a.Balance
		}
	}
	return -1
}
func arenaHiddenLRSign(s l.Snapshot) l.Snapshot {
	s.Accounts = append([]l.Account{}, s.Accounts...)
	s.Receipts = append([]l.Receipt{}, s.Receipts...)
	sort.Slice(s.Accounts, func(i, j int) bool { return s.Accounts[i].ID < s.Accounts[j].ID })
	sort.Slice(s.Receipts, func(i, j int) bool { return s.Receipts[i].Tx < s.Receipts[j].Tx })
	s.Digest = ""
	b, _ := json.Marshal(s)
	sum := sha256.Sum256(b)
	s.Digest = hex.EncodeToString(sum[:])
	return s
}
func arenaHiddenLRFrame(payload []byte) []byte {
	b := make([]byte, len(payload)+8)
	binary.BigEndian.PutUint32(b, uint32(len(payload)))
	copy(b[4:], payload)
	binary.BigEndian.PutUint32(b[len(b)-4:], crc32.ChecksumIEEE(payload))
	return b
}
func arenaHiddenLRFailure(t *testing.T, s l.Snapshot, records []l.Record) {
	t.Helper()
	before := arenaHiddenLRSign(s)
	out, e := l.Replay(s, records)
	if !errors.Is(e, l.ErrCorrupt) || !reflect.DeepEqual(out, l.Result{}) || !reflect.DeepEqual(s, before) {
		t.Fatalf("invalid transaction accepted or mutated: %#v %v", out, e)
	}
}
func TestArenaHiddenLedgerFraming(t *testing.T) {
	r := l.Record{Sequence: 17, Kind: "begin", Tx: "x"}
	b, e := l.Encode(r)
	if e != nil {
		t.Fatal(e)
	}
	payload, _ := json.Marshal(r)
	want := arenaHiddenLRFrame(payload)
	if !bytes.Equal(b, want) {
		t.Fatal("wire format")
	}
	b[4] = '!'
	fresh, _ := l.Encode(r)
	if !bytes.Equal(fresh, want) {
		t.Fatal("encode alias")
	}
	if got, e := l.Encode(l.Record{}); !errors.Is(e, l.ErrInvalid) || got != nil {
		t.Fatal(got, e)
	}
	if got, e := l.Encode(l.Record{Sequence: 1, Tx: strings.Repeat("x", l.MaxPayload)}); !errors.Is(e, l.ErrInvalid) || got != nil {
		t.Fatal(len(got), e)
	}
	prefix := arenaHiddenLRBytes(t, []l.Record{{Sequence: 7, Kind: "begin", Tx: "x"}})
	last, _ := l.Encode(l.Record{Sequence: 8, Kind: "commit", Tx: "x"})
	for cut := 0; cut < len(last); cut++ {
		data := append(append([]byte{}, prefix...), last[:cut]...)
		records, n, e := l.Scan(data)
		if e != nil || len(records) != 1 || n != len(prefix) {
			t.Fatalf("cut=%d n=%d e=%v", cut, n, e)
		}
	}
	badPayloads := [][]byte{[]byte(`{"sequence":8,"kind":"commit","tx":"x","unknown":1}`), []byte(`{"sequence":8} {}`), []byte(`{"sequence":0}`), []byte(`{"sequence":9}`), []byte(`{`)}
	for _, payload := range badPayloads {
		data := append(append([]byte{}, prefix...), arenaHiddenLRFrame(payload)...)
		records, n, e := l.Scan(data)
		if !errors.Is(e, l.ErrCorrupt) || len(records) != 1 || n != len(prefix) {
			t.Fatal(string(payload), records, n, e)
		}
	}
	corrupt := append([]byte{}, last...)
	corrupt[len(corrupt)-1] ^= 1
	records, n, e := l.Scan(append(append([]byte{}, prefix...), corrupt...))
	if !errors.Is(e, l.ErrCorrupt) || len(records) != 1 || n != len(prefix) {
		t.Fatal(records, n, e)
	}
	for _, size := range []uint32{0, l.MaxPayload + 1, math.MaxUint32} {
		header := make([]byte, 4)
		binary.BigEndian.PutUint32(header, size)
		records, n, e := l.Scan(header)
		if !errors.Is(e, l.ErrCorrupt) || n != 0 || records == nil || len(records) != 0 {
			t.Fatal(size, records, n, e)
		}
	}
	for _, bad := range [][]l.Record{{{Sequence: 0}}, {{Sequence: 1}, {Sequence: 3}}, {{Sequence: math.MaxUint64}, {Sequence: 1}}} {
		if b, e := l.EncodeRecords(bad); !errors.Is(e, l.ErrInvalid) || b != nil {
			t.Fatal(b, e)
		}
	}
	empty, e := l.EncodeRecords(nil)
	if e != nil || empty == nil || len(empty) != 0 {
		t.Fatal(empty, e)
	}
	records, n, e = l.Scan(nil)
	if e != nil || records == nil || len(records) != 0 || n != 0 {
		t.Fatal(records, n, e)
	}
	// Scan does not reject semantically unknown kinds; Replay does.
	opaque, _ := l.Encode(l.Record{Sequence: 1, Kind: "future", Tx: "x"})
	if r, _, e := l.Scan(opaque); e != nil || len(r) != 1 {
		t.Fatal(r, e)
	}
}
func TestArenaHiddenLedgerTornRecovery(t *testing.T) {
	s := arenaHiddenLRInitial(t)
	records := arenaHiddenLRRecords(1, "settle", 20)
	frames := make([][]byte, len(records))
	ends := []int{}
	data := []byte{}
	for i, r := range records {
		frames[i], _ = l.Encode(r)
		data = append(data, frames[i]...)
		ends = append(ends, len(data))
	}
	for cut := 0; cut <= len(data); cut++ {
		out, e := l.Recover(s, data[:cut])
		if e != nil {
			t.Fatal(cut, e)
		}
		complete := 0
		offset := 0
		for _, end := range ends {
			if end <= cut {
				complete++
				offset = end
			}
		}
		if out.ValidBytes != offset || out.State.Sequence != uint64(complete) {
			t.Fatal(cut, out)
		}
		want := int64(100)
		if complete == 4 {
			want = 80
		}
		if arenaHiddenLRBalance(out.State, "cash") != want || out.Committed == nil || out.Replayed == nil || out.Discarded == nil {
			t.Fatal(cut, out)
		}
		if complete > 0 && complete < 4 {
			if !reflect.DeepEqual(out.Discarded, []string{"settle"}) {
				t.Fatal(cut, out)
			}
		} else if len(out.Discarded) != 0 {
			t.Fatal(cut, out)
		}
		if out.State.Digest != arenaHiddenLRSign(out.State).Digest {
			t.Fatal("digest")
		}
	}
	if arenaHiddenLRBalance(s, "cash") != 100 || s.Sequence != 0 {
		t.Fatal("input changed")
	}
}
func TestArenaHiddenLedgerCommitLifecycle(t *testing.T) {
	s := arenaHiddenLRInitial(t)
	records := []l.Record{{Sequence: 1, Kind: "begin", Tx: "move"}, {Sequence: 2, Kind: "open", Tx: "move", Account: "new", Currency: "USD"}, {Sequence: 3, Kind: "post", Tx: "move", Account: "cash", Amount: -100}, {Sequence: 4, Kind: "post", Tx: "move", Account: "new", Amount: 100}, {Sequence: 5, Kind: "close", Tx: "move", Account: "cash"}, {Sequence: 6, Kind: "commit", Tx: "move"}}
	out, e := l.Replay(s, records)
	if e != nil || out.ValidBytes != 0 || out.State.Sequence != 6 || len(out.State.Receipts) != 1 || !out.State.Accounts[0].Closed || arenaHiddenLRBalance(out.State, "new") != 100 {
		t.Fatal(out, e)
	}
	repeated := append([]l.Record{}, records...)
	for i := range repeated {
		repeated[i].Sequence += 6
	}
	again, e := l.Replay(out.State, repeated)
	if e != nil || !reflect.DeepEqual(again.Replayed, []string{"move"}) || len(again.Committed) != 0 || again.State.Receipts[0].Sequence != 6 || arenaHiddenLRBalance(again.State, "new") != 100 {
		t.Fatal(again, e)
	}
	ops := append([]l.Record{}, records[1:5]...)
	for i := range ops {
		ops[i].Sequence = 0
		ops[i].Tx = ""
	}
	b, _ := json.Marshal(ops)
	sum := sha256.Sum256(b)
	if out.State.Receipts[0].Digest != hex.EncodeToString(sum[:]) {
		t.Fatal(out.State.Receipts)
	}
	changed := append([]l.Record{}, repeated...)
	changed[2].Amount = -99
	changed[3].Amount = 99
	arenaHiddenLRFailure(t, out.State, changed)
	// Debit may be temporarily negative when a later credit restores it.
	records = []l.Record{{Sequence: 1, Kind: "begin", Tx: "roundtrip"}, {Sequence: 2, Kind: "post", Tx: "roundtrip", Account: "reserve", Amount: -10}, {Sequence: 3, Kind: "post", Tx: "roundtrip", Account: "cash", Amount: 10}, {Sequence: 4, Kind: "post", Tx: "roundtrip", Account: "cash", Amount: -10}, {Sequence: 5, Kind: "post", Tx: "roundtrip", Account: "reserve", Amount: 10}, {Sequence: 6, Kind: "commit", Tx: "roundtrip"}}
	out, e = l.Replay(s, records)
	if e != nil || arenaHiddenLRBalance(out.State, "reserve") != 0 {
		t.Fatal(out, e)
	}
}
func TestArenaHiddenLedgerInterleavingAndAbandon(t *testing.T) {
	s := arenaHiddenLRInitial(t)
	records := []l.Record{
		{Sequence: 1, Kind: "begin", Tx: "z_pending"}, {Sequence: 2, Kind: "post", Tx: "z_pending", Account: "unknown", Amount: 1},
		{Sequence: 3, Kind: "begin", Tx: "a_pending"}, {Sequence: 4, Kind: "begin", Tx: "abortable"}, {Sequence: 5, Kind: "open", Tx: "abortable", Account: "cash", Currency: "USD"}, {Sequence: 6, Kind: "abort", Tx: "abortable"},
		{Sequence: 7, Kind: "begin", Tx: "abortable"}, {Sequence: 8, Kind: "commit", Tx: "abortable"},
	}
	out, e := l.Replay(s, records)
	if e != nil || out.State.Sequence != 8 || !reflect.DeepEqual(out.Discarded, []string{"a_pending", "z_pending"}) || !reflect.DeepEqual(out.Committed, []string{"abortable"}) || len(out.State.Accounts) != 2 {
		t.Fatal(out, e)
	}
	next := arenaHiddenLRRecords(9, "later", 5)
	out, e = l.Replay(out.State, next)
	if e != nil || arenaHiddenLRBalance(out.State, "cash") != 95 {
		t.Fatal(out, e)
	}
	a := arenaHiddenLRRecords(1, "first", 70)
	b := arenaHiddenLRRecords(4, "second", 50)
	interleaved := []l.Record{a[0], a[1], {Sequence: 3, Kind: "begin", Tx: "second"}, b[1], b[2], b[3], {Sequence: 8, Kind: "post", Tx: "first", Account: "reserve", Amount: 70}, {Sequence: 9, Kind: "commit", Tx: "first"}}
	// Normalize the deliberately interleaved records to contiguous global sequence.
	for i := range interleaved {
		interleaved[i].Sequence = uint64(i + 1)
	}
	arenaHiddenLRFailure(t, s, interleaved)
	// A valid committed prefix must not escape if a later transaction is invalid.
	prefix := arenaHiddenLRRecords(1, "good", 10)
	bad := arenaHiddenLRRecords(5, "bad", 200)
	engine, _ := l.NewEngine(s)
	out, e = engine.Recover(0, arenaHiddenLRBytes(t, append(prefix, bad...)))
	if !errors.Is(e, l.ErrCorrupt) || !reflect.DeepEqual(out, l.Result{}) || !reflect.DeepEqual(engine.Snapshot(), s) {
		t.Fatal(out, e, engine.Snapshot())
	}
}
func TestArenaHiddenLedgerShapeAndSemantics(t *testing.T) {
	s := arenaHiddenLRInitial(t)
	for _, r := range []l.Record{
		{Kind: "mystery", Tx: "x"}, {Kind: "begin", Tx: "Bad"}, {Kind: "begin", Tx: "x", Account: "cash"}, {Kind: "begin", Tx: "x", Currency: "USD"}, {Kind: "begin", Tx: "x", Amount: 1},
		{Kind: "post", Tx: "x", Account: "cash", Amount: 1}, {Kind: "commit", Tx: "x"}, {Kind: "abort", Tx: "x"},
	} {
		r.Sequence = 1
		arenaHiddenLRFailure(t, s, []l.Record{r})
	}
	for _, r := range []l.Record{
		{Kind: "begin", Tx: "x"}, {Kind: "post", Tx: "x", Account: "cash"}, {Kind: "post", Tx: "x", Account: "cash", Currency: "USD", Amount: 1}, {Kind: "post", Tx: "x", Account: "Bad", Amount: 1},
		{Kind: "open", Tx: "x", Account: "new", Currency: "usd"}, {Kind: "open", Tx: "x", Account: "new", Currency: "USD", Amount: 1},
		{Kind: "close", Tx: "x", Account: "cash", Amount: 1}, {Kind: "close", Tx: "x", Account: "cash", Currency: "USD"},
		{Kind: "commit", Tx: "x", Amount: 1}, {Kind: "abort", Tx: "x", Account: "cash"},
	} {
		r.Sequence = 2
		arenaHiddenLRFailure(t, s, []l.Record{{Sequence: 1, Kind: "begin", Tx: "x"}, r})
	}
	for _, ops := range [][]l.Record{
		{{Kind: "post", Account: "cash", Amount: -1}},
		{{Kind: "post", Account: "missing", Amount: 1}},
		{{Kind: "open", Account: "cash", Currency: "USD"}},
		{{Kind: "close", Account: "cash"}},
		{{Kind: "post", Account: "cash", Amount: -101}, {Kind: "post", Account: "reserve", Amount: 101}},
		{{Kind: "close", Account: "reserve"}, {Kind: "post", Account: "reserve", Amount: 1}, {Kind: "post", Account: "cash", Amount: -1}},
		{{Kind: "close", Account: "reserve"}, {Kind: "open", Account: "reserve", Currency: "USD"}},
		{{Kind: "close", Account: "reserve"}, {Kind: "close", Account: "reserve"}},
	} {
		records := []l.Record{{Sequence: 1, Kind: "begin", Tx: "x"}}
		for _, op := range ops {
			op.Tx = "x"
			op.Sequence = uint64(len(records) + 1)
			records = append(records, op)
		}
		records = append(records, l.Record{Sequence: uint64(len(records) + 1), Kind: "commit", Tx: "x"})
		arenaHiddenLRFailure(t, s, records)
	}
	arenaHiddenLRFailure(t, s, []l.Record{{Sequence: 2, Kind: "begin", Tx: "x"}})
	arenaHiddenLRFailure(t, s, []l.Record{{Sequence: 1, Kind: "begin", Tx: "x"}, {Sequence: 3, Kind: "abort", Tx: "x"}})
}
func TestArenaHiddenLedgerCurrenciesOverflow(t *testing.T) {
	s := arenaHiddenLRSnapshot(t, l.Account{ID: "cash", Currency: "USD", Balance: 100}, l.Account{ID: "reserve", Currency: "EUR"})
	arenaHiddenLRFailure(t, s, arenaHiddenLRRecords(1, "cross_currency", 10))
	s = arenaHiddenLRSnapshot(t, l.Account{ID: "cash", Currency: "USD", Balance: math.MaxInt64}, l.Account{ID: "reserve", Currency: "USD", Balance: 1})
	arenaHiddenLRFailure(t, s, arenaHiddenLRRecords(1, "overflow", -1))
	s = arenaHiddenLRSnapshot(t, l.Account{ID: "a", Currency: "USD"}, l.Account{ID: "b", Currency: "USD"}, l.Account{ID: "c", Currency: "USD", Balance: math.MaxInt64}, l.Account{ID: "d", Currency: "USD", Balance: 1})
	records := []l.Record{{Sequence: 1, Kind: "begin", Tx: "overflow"}, {Sequence: 2, Kind: "post", Tx: "overflow", Account: "a", Amount: math.MaxInt64}, {Sequence: 3, Kind: "post", Tx: "overflow", Account: "b", Amount: 1}, {Sequence: 4, Kind: "post", Tx: "overflow", Account: "c", Amount: -math.MaxInt64}, {Sequence: 5, Kind: "post", Tx: "overflow", Account: "d", Amount: -1}, {Sequence: 6, Kind: "commit", Tx: "overflow"}}
	arenaHiddenLRFailure(t, s, records)
	// Balanced transactions may span currencies, independently balancing each.
	s = arenaHiddenLRSnapshot(t, l.Account{ID: "a", Currency: "USD", Balance: 20}, l.Account{ID: "b", Currency: "USD"}, l.Account{ID: "c", Currency: "EUR", Balance: 30}, l.Account{ID: "d", Currency: "EUR"})
	records[1].Amount = -10
	records[2].Amount = 10
	records[3].Amount = -15
	records[4].Amount = 15
	out, e := l.Replay(s, records)
	if e != nil || arenaHiddenLRBalance(out.State, "b") != 10 || arenaHiddenLRBalance(out.State, "d") != 15 {
		t.Fatal(out, e)
	}
	tooBig := arenaHiddenLRSnapshot(t, l.Account{ID: "a", Currency: "USD", Balance: math.MaxInt64}, l.Account{ID: "b", Currency: "USD", Balance: 1})
	if r, e := l.Summarize(l.Result{State: tooBig}); !errors.Is(e, l.ErrInvalid) || !reflect.DeepEqual(r, l.Report{}) {
		t.Fatal(r, e)
	}
	var b bytes.Buffer
	if e := l.WriteReport(&b, l.Result{State: tooBig}); !errors.Is(e, l.ErrInvalid) || b.Len() != 0 {
		t.Fatal(e, b.String())
	}
}
func TestArenaHiddenLedgerCheckpointValidation(t *testing.T) {
	for _, accounts := range [][]l.Account{
		{{ID: "Bad", Currency: "USD"}}, {{ID: "a", Currency: "usd"}}, {{ID: "a", Currency: "USD", Balance: -1}}, {{ID: "a", Currency: "USD", Balance: 1, Closed: true}}, {{ID: "a", Currency: "USD"}, {ID: "a", Currency: "EUR"}},
	} {
		s, e := l.NewSnapshot(accounts)
		if !errors.Is(e, l.ErrInvalid) || !reflect.DeepEqual(s, l.Snapshot{}) {
			t.Fatal(s, e)
		}
	}
	s := arenaHiddenLRInitial(t)
	if !reflect.DeepEqual(s, arenaHiddenLRSign(s)) {
		t.Fatal("canonical digest")
	}
	s.Accounts[0], s.Accounts[1] = s.Accounts[1], s.Accounts[0]
	canonical, e := l.ValidateSnapshot(s)
	if e != nil || canonical.Accounts[0].ID != "cash" {
		t.Fatal(canonical, e)
	}
	s.Accounts[0].Balance++
	if _, e = l.ValidateSnapshot(s); !errors.Is(e, l.ErrInvalid) {
		t.Fatal("tamper", e)
	}
	for _, receipt := range []l.Receipt{{Tx: "Bad", Digest: strings.Repeat("a", 64), Sequence: 1}, {Tx: "x", Digest: strings.Repeat("A", 64), Sequence: 1}, {Tx: "x", Digest: strings.Repeat("g", 64), Sequence: 1}, {Tx: "x", Digest: strings.Repeat("a", 64), Sequence: 0}, {Tx: "x", Digest: strings.Repeat("a", 64), Sequence: 3}} {
		bad := arenaHiddenLRSign(l.Snapshot{Sequence: 2, Receipts: []l.Receipt{receipt}})
		if _, e = l.ValidateSnapshot(bad); !errors.Is(e, l.ErrInvalid) {
			t.Fatal(receipt, e)
		}
	}
	valid := l.Receipt{Tx: "x", Digest: strings.Repeat("a", 64), Sequence: 1}
	for _, receipts := range [][]l.Receipt{{valid, valid}, {valid, {Tx: "y", Digest: valid.Digest, Sequence: 1}}} {
		bad := arenaHiddenLRSign(l.Snapshot{Sequence: 2, Receipts: receipts})
		if _, e = l.ValidateSnapshot(bad); !errors.Is(e, l.ErrInvalid) {
			t.Fatal(receipts, e)
		}
	}
	invalid := l.Snapshot{}
	if out, e := l.Recover(invalid, []byte{0, 0, 0, 0}); !errors.Is(e, l.ErrInvalid) || !reflect.DeepEqual(out, l.Result{}) {
		t.Fatal(out, e)
	}
	if _, e = l.NewEngine(invalid); !errors.Is(e, l.ErrInvalid) {
		t.Fatal(e)
	}
	overflow := arenaHiddenLRSign(l.Snapshot{Sequence: math.MaxUint64})
	arenaHiddenLRFailure(t, overflow, []l.Record{{Sequence: 1, Kind: "begin", Tx: "x"}})
}
func TestArenaHiddenLedgerRestartAndOwnership(t *testing.T) {
	initial := arenaHiddenLRInitial(t)
	engine, _ := l.NewEngine(initial)
	initial.Accounts[0].Balance = 0
	out, e := engine.Recover(0, arenaHiddenLRBytes(t, arenaHiddenLRRecords(1, "one", 20)))
	if e != nil {
		t.Fatal(e)
	}
	out.State.Accounts[0].Balance = 999
	out.State.Receipts[0].Digest = "wrong"
	owned := engine.Snapshot()
	if arenaHiddenLRBalance(owned, "cash") != 80 {
		t.Fatal(owned)
	}
	owned.Accounts[0].Balance = 1
	checkpoint := engine.Snapshot()
	restored, e := l.NewEngine(checkpoint)
	if e != nil {
		t.Fatal(e)
	}
	repeat := arenaHiddenLRRecords(5, "one", 20)
	out, e = restored.Recover(4, arenaHiddenLRBytes(t, repeat))
	if e != nil || arenaHiddenLRBalance(out.State, "cash") != 80 || !reflect.DeepEqual(out.Replayed, []string{"one"}) {
		t.Fatal(out, e)
	}
	before := restored.Snapshot()
	if out, e = restored.Recover(3, []byte{0, 0, 0, 0}); !errors.Is(e, l.ErrConflict) || !reflect.DeepEqual(out, l.Result{}) || !reflect.DeepEqual(before, restored.Snapshot()) {
		t.Fatal(out, e)
	}
	bad := arenaHiddenLRBytes(t, arenaHiddenLRRecords(9, "two", 5))
	bad[len(bad)-1] ^= 1
	if out, e = restored.Recover(8, bad); !errors.Is(e, l.ErrCorrupt) || !reflect.DeepEqual(out, l.Result{}) || !reflect.DeepEqual(before, restored.Snapshot()) {
		t.Fatal(out, e)
	}
	// A discarded transaction advances the checkpoint but cannot be committed in a later call.
	pending := []l.Record{{Sequence: 9, Kind: "begin", Tx: "pending"}}
	out, e = restored.Recover(8, arenaHiddenLRBytes(t, pending))
	if e != nil || out.State.Sequence != 9 {
		t.Fatal(out, e)
	}
	if _, e = restored.Recover(9, arenaHiddenLRBytes(t, []l.Record{{Sequence: 10, Kind: "commit", Tx: "pending"}})); !errors.Is(e, l.ErrCorrupt) {
		t.Fatal(e)
	}
}
func TestArenaHiddenLedgerConcurrent(t *testing.T) {
	engine, _ := l.NewEngine(arenaHiddenLRInitial(t))
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				s := engine.Snapshot()
				if _, err := l.ValidateSnapshot(s); err != nil {
					t.Error(err)
				}
				s.Accounts[0].Balance = 123
			}
		}()
	}
	for i := 0; i < 40; i++ {
		sequence := uint64(i * 2)
		data := arenaHiddenLRBytes(t, []l.Record{{Sequence: sequence + 1, Kind: "begin", Tx: "x"}, {Sequence: sequence + 2, Kind: "abort", Tx: "x"}})
		if _, e := engine.Recover(sequence, data); e != nil {
			t.Fatal(e)
		}
	}
	wg.Wait()
}
func TestArenaHiddenLedgerReport(t *testing.T) {
	s := arenaHiddenLRSnapshot(t, l.Account{ID: "a", Currency: "USD", Balance: 10}, l.Account{ID: "b", Currency: "EUR", Closed: true}, l.Account{ID: "c", Currency: "USD", Balance: 20})
	result := l.Result{State: s, Committed: []string{"a", "b"}, Replayed: []string{"a"}, Discarded: []string{"z"}}
	report, e := l.Summarize(result)
	want := l.Report{Accounts: 3, OpenAccounts: 2, Committed: 2, Replayed: 1, Discarded: 1, Totals: []l.CurrencyTotal{{Currency: "EUR"}, {Currency: "USD", Total: 30}}}
	if e != nil || !reflect.DeepEqual(report, want) {
		t.Fatal(report, e)
	}
	var b bytes.Buffer
	if e = l.WriteReport(&b, result); e != nil || b.String() != "sequence 0\naccounts 3 open 2\ntransactions committed 2 replayed 1 discarded 1\nEUR 0\nUSD 30\n" {
		t.Fatal(b.String(), e)
	}
	if e = l.WriteReport(arenaHiddenLRWriter{}, result); !errors.Is(e, io.ErrClosedPipe) {
		t.Fatal(e)
	}
}

type arenaHiddenLRWriter struct{}

func (arenaHiddenLRWriter) Write([]byte) (int, error) { return 0, io.ErrClosedPipe }

type arenaHiddenLRReader struct{}

func (arenaHiddenLRReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
func TestArenaHiddenLedgerStrictJSON(t *testing.T) {
	for _, s := range []string{`{"expected":0,"journal":"","unknown":1}`, `{} {}`, `{} garbage`, `{"journal":"not base64!"}`} {
		if _, e := jsonapi.ReadRecovery(strings.NewReader(s)); e == nil {
			t.Fatal(s)
		}
	}
	if _, e := jsonapi.ReadRecovery(strings.NewReader("{} \n\t")); e != nil {
		t.Fatal(e)
	}
	for _, s := range []string{`[{"sequence":1,"unknown":1}]`, `[] []`, `[] rubbish`} {
		if _, e := jsonapi.ReadRecords(strings.NewReader(s)); e == nil {
			t.Fatal(s)
		}
	}
	state := arenaHiddenLRInitial(t)
	b, _ := json.Marshal(state)
	unknown := strings.Replace(string(b), `"id":"cash"`, `"id":"cash","unknown":1`, 1)
	if _, e := jsonapi.ReadSnapshot(strings.NewReader(unknown)); e == nil {
		t.Fatal("nested unknown")
	}
	if _, e := jsonapi.ReadSnapshot(strings.NewReader(string(b) + ` {}`)); e == nil {
		t.Fatal("trailing")
	}
	if _, e := jsonapi.ReadRecovery(arenaHiddenLRReader{}); !errors.Is(e, io.ErrUnexpectedEOF) {
		t.Fatal(e)
	}
	if _, e := jsonapi.ReadRecords(arenaHiddenLRReader{}); !errors.Is(e, io.ErrUnexpectedEOF) {
		t.Fatal(e)
	}
	if _, e := jsonapi.ReadSnapshot(arenaHiddenLRReader{}); !errors.Is(e, io.ErrUnexpectedEOF) {
		t.Fatal(e)
	}
	if e := jsonapi.WriteSnapshot(arenaHiddenLRWriter{}, state); !errors.Is(e, io.ErrClosedPipe) {
		t.Fatal(e)
	}
	if e := jsonapi.WriteResult(arenaHiddenLRWriter{}, l.Result{}); !errors.Is(e, io.ErrClosedPipe) {
		t.Fatal(e)
	}
	if e := jsonapi.WriteSummary(arenaHiddenLRWriter{}, l.Report{}); !errors.Is(e, io.ErrClosedPipe) {
		t.Fatal(e)
	}
}
func TestArenaHiddenLedgerFilesAndCLI(t *testing.T) {
	s := arenaHiddenLRInitial(t)
	records := arenaHiddenLRRecords(1, "sale", 25)
	data := arenaHiddenLRBytes(t, records)
	want, e := l.Recover(s, data)
	if e != nil {
		t.Fatal(e)
	}
	dir := t.TempDir()
	snapshotPath := filepath.Join(dir, "snapshot.json")
	journalPath := filepath.Join(dir, "journal.bin")
	checkpoint, _ := json.Marshal(s)
	os.WriteFile(snapshotPath, checkpoint, 0600)
	os.WriteFile(journalPath, data, 0600)
	got, e := files.Recover(snapshotPath, journalPath)
	if e != nil || !reflect.DeepEqual(got, want) {
		t.Fatal(got, e)
	}
	if _, e = files.ReadSnapshot(filepath.Join(dir, "missing")); e == nil {
		t.Fatal("missing snapshot")
	}
	if _, e = files.Recover(snapshotPath, filepath.Join(dir, "missing")); e == nil {
		t.Fatal("missing journal")
	}
	var out, stderr bytes.Buffer
	array, _ := json.Marshal(records)
	if code := app.Run([]string{"encode"}, bytes.NewReader(array), &out, &stderr); code != 0 || !bytes.Equal(out.Bytes(), data) {
		t.Fatal(code, stderr.String())
	}
	out.Reset()
	if code := app.Run([]string{"checkpoint"}, bytes.NewReader(checkpoint), &out, &stderr); code != 0 {
		t.Fatal(code, stderr.String())
	}
	var canonical l.Snapshot
	if e = json.Unmarshal(out.Bytes(), &canonical); e != nil || !reflect.DeepEqual(canonical, s) {
		t.Fatal(canonical, e)
	}
	out.Reset()
	if code := app.Run([]string{"recover", snapshotPath, journalPath}, strings.NewReader(""), &out, &stderr); code != 0 {
		t.Fatal(code, stderr.String())
	}
	if e = json.Unmarshal(out.Bytes(), &got); e != nil || !reflect.DeepEqual(got, want) {
		t.Fatal(got, e)
	}
	out.Reset()
	if code := app.Run([]string{"report", snapshotPath, journalPath}, strings.NewReader(""), &out, &stderr); code != 0 {
		t.Fatal(code, stderr.String())
	}
	var expected bytes.Buffer
	l.WriteReport(&expected, want)
	if out.String() != expected.String() {
		t.Fatal(out.String(), expected.String())
	}
	for _, input := range []string{`[] []`, `[{"sequence":0}]`, `[{"sequence":1},{"sequence":3}]`} {
		out.Reset()
		stderr.Reset()
		if code := app.Run([]string{"encode"}, strings.NewReader(input), &out, &stderr); code != 1 || out.Len() != 0 || stderr.Len() == 0 {
			t.Fatal(code, out.String(), stderr.String())
		}
	}
	out.Reset()
	stderr.Reset()
	if code := app.Run([]string{"checkpoint"}, strings.NewReader(`{}`), &out, &stderr); code != 1 || out.Len() != 0 || stderr.Len() == 0 {
		t.Fatal(code)
	}
	if code := app.Run([]string{"encode"}, bytes.NewReader(array), arenaHiddenLRWriter{}, &stderr); code != 1 {
		t.Fatal(code)
	}
	corrupted := append([]byte{}, data...)
	corrupted[len(corrupted)-1] ^= 1
	os.WriteFile(journalPath, corrupted, 0600)
	out.Reset()
	stderr.Reset()
	if code := app.Run([]string{"recover", snapshotPath, journalPath}, strings.NewReader(""), &out, &stderr); code != 1 || out.Len() != 0 || stderr.Len() == 0 {
		t.Fatal(code, out.String(), stderr.String())
	}
	unchanged, _ := os.ReadFile(snapshotPath)
	journal, _ := os.ReadFile(journalPath)
	if !bytes.Equal(unchanged, checkpoint) || !bytes.Equal(journal, corrupted) {
		t.Fatal("modified input files")
	}
}
func TestArenaHiddenLedgerHTTP(t *testing.T) {
	s := arenaHiddenLRInitial(t)
	engine, _ := l.NewEngine(s)
	handler := httpapi.Handler(engine)
	call := func(method, path string, body []byte, status int) *httptest.ResponseRecorder {
		t.Helper()
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, httptest.NewRequest(method, path, bytes.NewReader(body)))
		if w.Code != status {
			t.Fatalf("%s %s: %d %s", method, path, w.Code, w.Body.String())
		}
		if status != 404 && !strings.HasPrefix(w.Header().Get("Content-Type"), "application/json") {
			t.Fatal(w.Header())
		}
		if status >= 400 && status != 404 {
			var m map[string]string
			if e := json.Unmarshal(w.Body.Bytes(), &m); e != nil || m["error"] == "" {
				t.Fatal(w.Body.String(), e)
			}
		}
		return w
	}
	data := arenaHiddenLRBytes(t, arenaHiddenLRRecords(1, "sale", 10))
	request, _ := json.Marshal(l.RecoveryRequest{Expected: 0, Journal: data})
	w := call("POST", "/recover", request, 200)
	var got l.Result
	json.Unmarshal(w.Body.Bytes(), &got)
	want, _ := l.Recover(s, data)
	if !reflect.DeepEqual(got, want) {
		t.Fatal(got, want)
	}
	call("POST", "/recover", request, 409)
	call("POST", "/recover", []byte(`{} {}`), 400)
	call("POST", "/recover", []byte(`{"expected":4,"journal":"AAAAAA=="}`), 400)
	call("GET", "/recover", nil, 404)
	before := engine.Snapshot()
	badRequest, _ := json.Marshal(l.RecoveryRequest{Expected: 4, Journal: arenaHiddenLRBytes(t, arenaHiddenLRRecords(5, "bad", 1000))})
	call("POST", "/recover", badRequest, 400)
	if !reflect.DeepEqual(before, engine.Snapshot()) {
		t.Fatal("failed HTTP mutation")
	}
	w = call("GET", "/report", nil, 200)
	var report l.Report
	json.Unmarshal(w.Body.Bytes(), &report)
	if report.Sequence != 4 || report.Committed != 0 || report.Replayed != 0 || len(report.Totals) != 1 || report.Totals[0].Total != 100 {
		t.Fatal(report)
	}
	w = call("GET", "/snapshot", nil, 200)
	var snapshot l.Snapshot
	json.Unmarshal(w.Body.Bytes(), &snapshot)
	if !reflect.DeepEqual(snapshot, before) {
		t.Fatal(snapshot, before)
	}
}
func TestArenaHiddenLedgerLongRecovery(t *testing.T) {
	initial := arenaHiddenLRInitial(t)
	records := []l.Record{}
	expected := int64(100)
	for i := 0; i < 200; i++ {
		amount := int64(1)
		if i%2 == 1 {
			amount = -1
		}
		expected -= amount
		tx := fmt.Sprintf("batch_%03d", i)
		records = append(records, arenaHiddenLRRecords(uint64(len(records)+1), tx, amount)...)
	}
	out, e := l.Recover(initial, arenaHiddenLRBytes(t, records))
	if e != nil || out.State.Sequence != 800 || len(out.State.Receipts) != 200 || len(out.Committed) != 200 || arenaHiddenLRBalance(out.State, "cash") != expected {
		t.Fatal(out, e)
	}
	// Every receipt survives checkpoint serialization and repeated transaction bodies after restart.
	var b bytes.Buffer
	jsonapi.WriteSnapshot(&b, out.State)
	checkpoint, e := jsonapi.ReadSnapshot(&b)
	if e != nil {
		t.Fatal(e)
	}
	repeats := []l.Record{}
	for i := 199; i >= 0; i-- {
		amount := int64(1)
		if i%2 == 1 {
			amount = -1
		}
		tx := fmt.Sprintf("batch_%03d", i)
		repeats = append(repeats, arenaHiddenLRRecords(uint64(801+len(repeats)), tx, amount)...)
	}
	replayed, e := l.Recover(checkpoint, arenaHiddenLRBytes(t, repeats))
	if e != nil || len(replayed.Replayed) != 200 || len(replayed.Committed) != 0 || arenaHiddenLRBalance(replayed.State, "cash") != expected || !reflect.DeepEqual(replayed.State.Receipts, checkpoint.Receipts) {
		t.Fatal(replayed, e)
	}
}
