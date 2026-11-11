package inventory

import "sort"

func Reconcile(opening map[string]int64, events []Event) ([]Balance, error) {
	totals := map[string]int64{}
	for k, v := range opening {
		totals[k] = v
	}
	for _, e := range events {
		switch e.Kind {
		case "receive":
			totals[e.SKU] += e.Quantity
		case "ship":
			totals[e.SKU] -= e.Quantity
		}
	}
	var out []Balance
	for k, v := range totals {
		out = append(out, Balance{k, v})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].SKU < out[j].SKU })
	return out, nil
}
