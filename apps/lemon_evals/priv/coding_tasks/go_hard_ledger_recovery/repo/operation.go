package ledger

func applyOperations(accounts map[string]Account, ops []Record) (map[string]Account, error) {
	next := map[string]Account{}
	for id, a := range accounts {
		next[id] = a
	}
	for _, r := range ops {
		switch r.Kind {
		case "open":
			next[r.Account] = Account{ID: r.Account, Currency: r.Currency}
		case "post":
			a, ok := next[r.Account]
			if !ok {
				return nil, ErrCorrupt
			}
			a.Balance += r.Amount
			next[r.Account] = a
		case "close":
			a, ok := next[r.Account]
			if !ok {
				return nil, ErrCorrupt
			}
			a.Closed = true
			next[r.Account] = a
		}
	}
	return next, nil
}
