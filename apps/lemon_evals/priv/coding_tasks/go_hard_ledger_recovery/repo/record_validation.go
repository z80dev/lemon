package ledger

func validateRecord(r Record) error {
	if r.Sequence == 0 || !nameOK(r.Tx) {
		return ErrCorrupt
	}
	switch r.Kind {
	case "begin", "open", "post", "close", "commit", "abort":
		return nil
	}
	return ErrCorrupt
}
