package ledger

func validateRecord(r Record) error {
	if r.Sequence == 0 || !nameOK(r.Tx) {
		return ErrCorrupt
	}
	switch r.Kind {
	case "begin", "commit", "abort":
		if r.Account != "" || r.Currency != "" || r.Amount != 0 {
			return ErrCorrupt
		}
	case "open":
		if !nameOK(r.Account) || !currencyOK(r.Currency) || r.Amount != 0 {
			return ErrCorrupt
		}
	case "post":
		if !nameOK(r.Account) || r.Currency != "" || r.Amount == 0 {
			return ErrCorrupt
		}
	case "close":
		if !nameOK(r.Account) || r.Currency != "" || r.Amount != 0 {
			return ErrCorrupt
		}
	default:
		return ErrCorrupt
	}
	return nil
}
