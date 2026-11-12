package ledger

func applyOperations(accounts map[string]Account, ops []Record) (map[string]Account, error) {
	next := make(map[string]Account, len(accounts))
	for id, a := range accounts {
		next[id] = a
	}
	totals := map[string]int64{}
	for _, r := range ops {
		switch r.Kind {
		case "open":
			if _, exists := next[r.Account]; exists {
				return nil, ErrCorrupt
			}
			next[r.Account] = Account{ID: r.Account, Currency: r.Currency}
		case "post":
			a, exists := next[r.Account]
			if !exists || a.Closed {
				return nil, ErrCorrupt
			}
			balance, err := add(a.Balance, r.Amount)
			if err != nil {
				return nil, ErrCorrupt
			}
			total, err := add(totals[a.Currency], r.Amount)
			if err != nil {
				return nil, ErrCorrupt
			}
			a.Balance = balance
			next[r.Account] = a
			totals[a.Currency] = total
		case "close":
			a, exists := next[r.Account]
			if !exists || a.Closed || a.Balance != 0 {
				return nil, ErrCorrupt
			}
			a.Closed = true
			next[r.Account] = a
		}
	}
	for _, total := range totals {
		if total != 0 {
			return nil, ErrCorrupt
		}
	}
	for _, a := range next {
		if a.Balance < 0 {
			return nil, ErrCorrupt
		}
	}
	return next, nil
}
