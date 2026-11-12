package ledger

type working struct {
	accounts map[string]Account
	receipts map[string]Receipt
	pending  map[string][]Record
}

func newWorking(s Snapshot) *working {
	w := &working{accounts: map[string]Account{}, receipts: map[string]Receipt{}, pending: map[string][]Record{}}
	for _, a := range s.Accounts {
		w.accounts[a.ID] = a
	}
	for _, r := range s.Receipts {
		w.receipts[r.Tx] = r
	}
	return w
}
func (w *working) snapshot(sequence uint64) Snapshot {
	s := Snapshot{Sequence: sequence, Accounts: []Account{}, Receipts: []Receipt{}}
	for _, a := range w.accounts {
		s.Accounts = append(s.Accounts, a)
	}
	for _, r := range w.receipts {
		s.Receipts = append(s.Receipts, r)
	}
	s = canonical(s)
	s.Digest = snapshotDigest(s)
	return s
}
