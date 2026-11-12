package ledger

import "sort"

func canonical(s Snapshot) Snapshot {
	s = cloneSnapshot(s)
	sort.Slice(s.Accounts, func(i, j int) bool { return s.Accounts[i].ID < s.Accounts[j].ID })
	sort.Slice(s.Receipts, func(i, j int) bool { return s.Receipts[i].Tx < s.Receipts[j].Tx })
	return s
}
