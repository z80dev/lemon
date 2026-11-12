package ledger

type Account struct {
	ID       string `json:"id"`
	Currency string `json:"currency"`
	Balance  int64  `json:"balance"`
	Closed   bool   `json:"closed"`
}
type Record struct {
	Sequence uint64 `json:"sequence"`
	Kind     string `json:"kind"`
	Tx       string `json:"tx"`
	Account  string `json:"account,omitempty"`
	Currency string `json:"currency,omitempty"`
	Amount   int64  `json:"amount,omitempty"`
}
type Receipt struct {
	Tx       string `json:"tx"`
	Digest   string `json:"digest"`
	Sequence uint64 `json:"sequence"`
}
type Snapshot struct {
	Sequence uint64    `json:"sequence"`
	Accounts []Account `json:"accounts"`
	Receipts []Receipt `json:"receipts"`
	Digest   string    `json:"digest"`
}
type Result struct {
	State      Snapshot `json:"state"`
	ValidBytes int      `json:"valid_bytes"`
	Committed  []string `json:"committed"`
	Replayed   []string `json:"replayed"`
	Discarded  []string `json:"discarded"`
}
type CurrencyTotal struct {
	Currency string `json:"currency"`
	Total    int64  `json:"total"`
}
type Report struct {
	Sequence     uint64          `json:"sequence"`
	Accounts     int             `json:"accounts"`
	OpenAccounts int             `json:"open_accounts"`
	Committed    int             `json:"committed"`
	Replayed     int             `json:"replayed"`
	Discarded    int             `json:"discarded"`
	Totals       []CurrencyTotal `json:"totals"`
}
type RecoveryRequest struct {
	Expected uint64 `json:"expected"`
	Journal  []byte `json:"journal"`
}
