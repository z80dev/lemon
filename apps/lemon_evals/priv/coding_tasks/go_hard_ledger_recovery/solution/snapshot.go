package ledger

import (
	"encoding/hex"
	"strings"
)

func NewSnapshot(accounts []Account) (Snapshot, error) {
	s := canonical(Snapshot{Accounts: accounts})
	s.Digest = snapshotDigest(s)
	return ValidateSnapshot(s)
}
func validDigest(s string) bool {
	if len(s) != 64 || strings.ToLower(s) != s {
		return false
	}
	_, err := hex.DecodeString(s)
	return err == nil
}
func ValidateSnapshot(s Snapshot) (Snapshot, error) {
	s = canonical(s)
	seen := map[string]bool{}
	for _, a := range s.Accounts {
		if !nameOK(a.ID) || !currencyOK(a.Currency) || a.Balance < 0 || (a.Closed && a.Balance != 0) || seen[a.ID] {
			return Snapshot{}, ErrInvalid
		}
		seen[a.ID] = true
	}
	seen = map[string]bool{}
	sequences := map[uint64]bool{}
	for _, r := range s.Receipts {
		if !nameOK(r.Tx) || !validDigest(r.Digest) || r.Sequence == 0 || r.Sequence > s.Sequence || seen[r.Tx] || sequences[r.Sequence] {
			return Snapshot{}, ErrInvalid
		}
		seen[r.Tx] = true
		sequences[r.Sequence] = true
	}
	if s.Digest != snapshotDigest(s) {
		return Snapshot{}, ErrInvalid
	}
	return s, nil
}
