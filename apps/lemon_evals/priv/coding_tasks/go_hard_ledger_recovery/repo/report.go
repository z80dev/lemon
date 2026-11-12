package ledger

import (
	"fmt"
	"io"
)

func WriteReport(w io.Writer, result Result) error {
	r, err := Summarize(result)
	if err != nil {
		return err
	}
	lines := []string{fmt.Sprintf("sequence %d\n", r.Sequence), fmt.Sprintf("accounts %d open %d\n", r.Accounts, r.OpenAccounts), fmt.Sprintf("transactions committed %d replayed %d discarded %d\n", r.Committed, r.Replayed, r.Discarded)}
	for _, line := range lines {
		if _, err = io.WriteString(w, line); err != nil {
			return err
		}
	}
	for _, total := range r.Totals {
		if _, err = fmt.Fprintf(w, "%s %d\n", total.Currency, total.Total); err != nil {
			return err
		}
	}
	return nil
}
