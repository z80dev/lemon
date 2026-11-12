package ledger

import "sort"

func Summarize(result Result) (Report, error) {
	s, err := ValidateSnapshot(result.State)
	if err != nil {
		return Report{}, err
	}
	out := Report{Sequence: s.Sequence, Accounts: len(s.Accounts), Committed: len(result.Committed), Replayed: len(result.Replayed), Discarded: len(result.Discarded), Totals: []CurrencyTotal{}}
	totals := map[string]int64{}
	for _, a := range s.Accounts {
		if !a.Closed {
			out.OpenAccounts++
		}
		totals[a.Currency] += a.Balance
	}
	for currency, total := range totals {
		out.Totals = append(out.Totals, CurrencyTotal{Currency: currency, Total: total})
	}
	sort.Slice(out.Totals, func(i, j int) bool { return out.Totals[i].Currency < out.Totals[j].Currency })
	return out, nil
}
