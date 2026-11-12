package ledger

func NewSnapshot(accounts []Account) (Snapshot, error) {
	s := canonical(Snapshot{Accounts: accounts})
	s.Digest = snapshotDigest(s)
	return ValidateSnapshot(s)
}
func ValidateSnapshot(s Snapshot) (Snapshot, error) {
	s = canonical(s)
	for _, a := range s.Accounts {
		if !nameOK(a.ID) || !currencyOK(a.Currency) || a.Balance < 0 {
			return Snapshot{}, ErrInvalid
		}
	}
	if s.Digest != snapshotDigest(s) {
		return Snapshot{}, ErrInvalid
	}
	return s, nil
}
