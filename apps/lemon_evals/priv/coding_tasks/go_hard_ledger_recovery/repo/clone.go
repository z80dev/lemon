package ledger

func cloneSnapshot(s Snapshot) Snapshot {
	s.Accounts = append([]Account{}, s.Accounts...)
	s.Receipts = append([]Receipt{}, s.Receipts...)
	return s
}
